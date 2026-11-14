require 'spec_helper'
require 'rails_console_ai/safety_guards'

RSpec.describe RailsConsoleAi::SqlWrites do
  def writes(sql, mysql: false)
    described_class.find(sql, mysql: mysql).map { |w| [w.keyword, w.table] }
  end

  describe 'plain statements' do
    {
      "INSERT INTO users (name) VALUES ('a')"            => [['INSERT', 'users']],
      'UPDATE users SET x = 1'                           => [['UPDATE', 'users']],
      'UPDATE users AS u SET x = 1'                      => [['UPDATE', 'users']],
      'DELETE FROM users WHERE id = 1'                   => [['DELETE', 'users']],
      'REPLACE INTO users VALUES (1)'                    => [['REPLACE', 'users']],
      'TRUNCATE TABLE users'                             => [['TRUNCATE', 'users']],
      'TRUNCATE users'                                   => [['TRUNCATE', 'users']],
      'DROP TABLE IF EXISTS users'                       => [['DROP', 'users']],
      'CREATE TEMPORARY TABLE tmp AS SELECT * FROM users' => [['CREATE', 'tmp']],
      'ALTER TABLE users ADD COLUMN x integer'           => [['ALTER', 'users']],
      'update users set x = 1'                           => [['UPDATE', 'users']]
    }.each do |sql, expected|
      it "finds the write in: #{sql}" do
        expect(writes(sql)).to eq(expected)
      end
    end

    it 'reads the table through quoting and schema qualification' do
      expect(writes('UPDATE "users" SET "x" = 1 WHERE "users"."id" = 3')).to eq([['UPDATE', 'users']])
      expect(writes('UPDATE `users` SET `x` = 1', mysql: true)).to eq([['UPDATE', 'users']])
      expect(writes('INSERT INTO "public"."users" (x) VALUES (1)')).to eq([['INSERT', 'users']])
    end

    it 'reports the schema-qualified name alongside the bare table' do
      write = described_class.find('UPDATE public.users SET x = 1').first
      expect([write.table, write.qualified_table]).to eq(['users', 'public.users'])
    end
  end

  describe 'statements that used to slip past a start-of-string check' do
    it 'finds a write behind a leading comment' do
      expect(writes('/* app:web */ UPDATE users SET x = 1')).to eq([['UPDATE', 'users']])
      expect(writes("-- note\nUPDATE users SET x = 1")).to eq([['UPDATE', 'users']])
      expect(writes("# note\nUPDATE users SET x = 1", mysql: true)).to eq([['UPDATE', 'users']])
    end

    it 'finds a write inside a CTE' do
      expect(writes('WITH d AS (DELETE FROM users RETURNING id) SELECT count(*) FROM d'))
        .to eq([['DELETE', 'users']])
    end

    it 'finds a write that follows a CTE, and names the table written, not the one read' do
      expect(writes('WITH a AS (SELECT * FROM sessions) DELETE FROM users USING a WHERE users.id = a.user_id'))
        .to eq([['DELETE', 'users']])
    end

    it 'finds every write in a statement' do
      expect(writes('WITH d AS (DELETE FROM a RETURNING *) INSERT INTO b SELECT * FROM d'))
        .to eq([['DELETE', 'a'], ['INSERT', 'b']])
      expect(writes('CREATE TABLE x AS WITH d AS (DELETE FROM a RETURNING *) SELECT * FROM d'))
        .to eq([['DELETE', 'a'], ['CREATE', 'x']])
    end

    it 'finds a write in a later statement' do
      expect(writes('SELECT 1; DELETE FROM users')).to eq([['DELETE', 'users']])
    end

    it 'finds a write in parentheses' do
      expect(writes('  (  DELETE FROM users)')).to eq([['DELETE', 'users']])
    end

    it 'finds MERGE, and does not count its actions as writes of their own' do
      sql = 'MERGE INTO users u USING t ON u.id = t.id ' \
            'WHEN MATCHED THEN UPDATE SET x = 1 WHEN NOT MATCHED THEN INSERT (id) VALUES (t.id)'
      expect(writes(sql)).to eq([['MERGE', 'users']])
    end

    it 'does not count an upsert clause as a second write' do
      expect(writes('INSERT INTO users (a) VALUES (1) ON CONFLICT (a) DO UPDATE SET a = excluded.a'))
        .to eq([['INSERT', 'users']])
      expect(writes('INSERT INTO users (a) VALUES (1) ON DUPLICATE KEY UPDATE a = 2', mysql: true))
        .to eq([['INSERT', 'users']])
    end

    it 'does not count a foreign key rule as a write of its own' do
      expect(writes('ALTER TABLE users ADD FOREIGN KEY (a) REFERENCES b (id) ON DELETE CASCADE'))
        .to eq([['ALTER', 'users']])
    end

    it 'finds a write that EXPLAIN ANALYZE would run' do
      expect(writes('EXPLAIN ANALYZE UPDATE users SET x = 1')).to eq([['UPDATE', 'users']])
      expect(writes('EXPLAIN (ANALYZE, BUFFERS) DELETE FROM users')).to eq([['DELETE', 'users']])
    end

    it 'finds SELECT ... INTO' do
      expect(writes('SELECT * INTO backup_users FROM users')).to eq([['SELECT INTO', nil]])
      expect(writes("SELECT * FROM users INTO OUTFILE '/tmp/x'", mysql: true)).to eq([['SELECT INTO', nil]])
    end

    it 'finds a write inside a MySQL executable comment' do
      expect(writes('/*!50000 DELETE FROM users */', mysql: true)).to eq([['DELETE', 'users']])
    end
  end

  describe 'writes with no single target table' do
    {
      'GRANT ALL ON users TO someone'               => 'GRANT',
      'REVOKE ALL ON users FROM someone'            => 'REVOKE',
      'CALL purge_everything()'                     => 'CALL',
      "COPY users FROM '/tmp/users.csv'"            => 'COPY',
      'CREATE INDEX i ON users (x)'                 => 'CREATE',
      'DROP TABLE a, b'                             => 'DROP',
      'UPDATE a JOIN b ON a.id = b.id SET b.x = 1'  => 'UPDATE',
      'DELETE a FROM a JOIN b ON a.id = b.id'       => 'DELETE',
      'REPLACE users VALUES (1)'                    => 'REPLACE',
      'VACUUM FULL users'                           => 'VACUUM'
    }.each do |sql, keyword|
      it "blocks without offering a table to allow: #{sql}" do
        expect(writes(sql)).to eq([[keyword, nil]])
      end
    end
  end

  describe 'statements that only read' do
    [
      'SELECT * FROM users',
      "SELECT * FROM users WHERE name = 'please delete; update me'",
      'SELECT * FROM users /* controller:users,action:update */',
      'WITH x AS (SELECT * FROM users) SELECT * FROM x /* action:update */',
      'WITH x AS (SELECT * FROM users FOR UPDATE SKIP LOCKED) SELECT * FROM x',
      'SELECT * FROM users FOR NO KEY UPDATE',
      "WITH x AS (SELECT replace(name, 'a', 'b') AS merge, deleted_at, update_count FROM users) SELECT * FROM x",
      'SELECT "update", "delete" FROM "insert"',
      'SELECT t.update, t.delete FROM t',
      'EXPLAIN UPDATE users SET x = 1',
      'SHOW CREATE TABLE users',
      'BEGIN',
      'COMMIT',
      'SAVEPOINT active_record_1',
      'RELEASE SAVEPOINT active_record_1',
      'ROLLBACK TO SAVEPOINT active_record_1',
      "SET client_min_messages TO 'warning'",
      'PRAGMA foreign_keys = ON',
      'COPY (SELECT * FROM users) TO STDOUT',
      "SELECT 'unterminated",
      '',
      ';'
    ].each do |sql|
      it "finds nothing in: #{sql.inspect}" do
        expect(writes(sql)).to eq([])
      end
    end

    [
      'SELECT * FROM users WHERE name = "delete me; update x"',
      "SET @@SESSION.sql_mode = CONCAT(REPLACE(REPLACE(@@sql_mode, 'STRICT_TRANS_TABLES', ''), 'NO_ZERO_DATE', ''))",
      "WITH x AS (SELECT INSERT(name, 1, 0, 'a') FROM users) SELECT * FROM x",
      'SELECT id INTO @last FROM users LIMIT 1',
      'SELECT * FROM users # update later',
      'SHOW FULL FIELDS FROM `users`'
    ].each do |sql|
      it "finds nothing on MySQL in: #{sql}" do
        expect(writes(sql, mysql: true)).to eq([])
      end
    end
  end

  describe 'where the code of a statement starts and stops' do
    it 'does not let a doubled quote end a string early' do
      expect(writes("SELECT 'it''s; DELETE FROM a'; UPDATE users SET x = 1")).to eq([['UPDATE', 'users']])
    end

    it 'treats a backslash as an ordinary character outside MySQL' do
      # The string is 'a\' — the DELETE after it is code.
      expect(writes("SELECT 'a\\'; DELETE FROM users --'")).to eq([['DELETE', 'users']])
    end

    it 'treats a backslash as an escape on MySQL' do
      # The string runs to the second unescaped quote — the DELETE after that is code.
      expect(writes("SELECT 'a\\'; SELECT 2'; DELETE FROM users", mysql: true)).to eq([['DELETE', 'users']])
    end

    it 'skips a dollar-quoted string' do
      expect(writes('SELECT $$ ; DELETE FROM a $$; UPDATE users SET x = 1')).to eq([['UPDATE', 'users']])
      expect(writes('SELECT $q$ ; DELETE FROM a $q$')).to eq([])
    end

    it 'does not treat # as a comment outside MySQL, where it is an operator' do
      expect(writes("SELECT data #> '{a}' FROM t; DELETE FROM users")).to eq([['DELETE', 'users']])
    end

    it 'does not treat -- as a comment on MySQL unless whitespace follows' do
      expect(writes('SELECT 5--1; DELETE FROM users', mysql: true)).to eq([['DELETE', 'users']])
    end
  end
end

RSpec.describe RailsConsoleAi::BuiltinGuards::WriteBlocker do
  let(:adapter_name) { 'PostgreSQL' }
  let(:connection) do
    name = adapter_name
    Class.new do
      prepend RailsConsoleAi::BuiltinGuards::WriteBlocker
      define_method(:adapter_name) { name }

      def execute(sql, *_args, **_kwargs)
        sql
      end
    end.new
  end
  let(:guards) { RailsConsoleAi.configuration.safety_guards }

  before { RailsConsoleAi::GuardState[:block_writes] = true }

  it 'blocks a write inside a CTE and names it in the error' do
    sql = 'WITH d AS (DELETE FROM users RETURNING id) SELECT count(*) FROM d'
    expect { connection.execute(sql) }.to raise_error(RailsConsoleAi::SafetyError) { |error|
      expect(error.message).to eq('Database write blocked: DELETE FROM users...')
      expect(error.blocked_key).to eq('users')
    }
  end

  it 'offers no table to allow when the write has no single target' do
    expect { connection.execute('GRANT ALL ON users TO someone') }
      .to raise_error(RailsConsoleAi::SafetyError) { |error| expect(error.blocked_key).to be_nil }
  end

  it 'allows a statement only when every table it writes is allowlisted' do
    sql = 'WITH d AS (DELETE FROM a RETURNING *) INSERT INTO b SELECT * FROM d'

    guards.allow(:database_writes, 'b')
    expect { connection.execute(sql) }.to raise_error(RailsConsoleAi::SafetyError) { |error|
      expect(error.blocked_key).to eq('a')
    }

    guards.allow(:database_writes, 'a')
    expect(connection.execute(sql)).to eq(sql)
  end

  it 'does not allow a write because a table it reads is allowlisted' do
    guards.allow(:database_writes, 'sessions')
    expect { connection.execute('WITH a AS (SELECT * FROM sessions) DELETE FROM users USING a') }
      .to raise_error(RailsConsoleAi::SafetyError, /DELETE FROM users/)
  end

  it 'accepts an allowlist entry for the schema-qualified name' do
    guards.allow(:database_writes, 'audit.events')
    expect(connection.execute('INSERT INTO audit.events (x) VALUES (1)')).to include('audit.events')
  end

  it 'lets reads through' do
    sql = "SELECT * FROM users WHERE note = 'delete me' /* action:update */"
    expect(connection.execute(sql)).to eq(sql)
  end

  context 'on a MySQL adapter' do
    let(:adapter_name) { 'Mysql2' }

    it 'uses MySQL lexical rules' do
      expect { connection.execute("# note\nUPDATE users SET x = 1") }
        .to raise_error(RailsConsoleAi::SafetyError, /UPDATE users SET/)
      expect(connection.execute('SELECT * FROM users WHERE name = "delete; update"')).to include('SELECT')
    end
  end
end
