module RailsConsoleAi
  # Decides whether a SQL string changes anything, and which table each change
  # targets, for the :database_writes guard.
  #
  # The guard used to ask one question: does the string *start* with INSERT,
  # UPDATE, DELETE, DROP, CREATE, ALTER or TRUNCATE. That let through a write
  # behind a leading comment, a write inside or after a CTE
  # (`WITH d AS (DELETE ... RETURNING id) SELECT ...`), a second statement after
  # a `;`, and every write that starts with another word (REPLACE, MERGE, GRANT,
  # CALL, ...). It also took the allowlist's table from the first FROM/INTO in
  # the string, which for `WITH a AS (SELECT * FROM sessions) DELETE FROM users`
  # is the table being read, not the one being written.
  #
  # This is still pattern matching, not a parser. It blocks statements it
  # recognizes as writes and lets the rest through, and it cannot see a write
  # made by a function a SELECT calls (`SELECT setval(...)`) or one that goes
  # around the adapter (`raw_connection`). It is there to catch the writes the
  # model makes by accident, not to contain code that is trying to get past it.
  module SqlWrites
    # table / qualified_table are nil when the write cannot be pinned on exactly
    # one table — such a write can never be let through by the allowlist.
    Write = Struct.new(:keyword, :table, :qualified_table, :summary)

    # Statements that change data, schema or privileges, run arbitrary stored
    # code, or move data in bulk — everything that isn't plain DML, which is
    # looked for anywhere in a statement rather than only at its start.
    NON_DML = %w[
      DROP CREATE ALTER TRUNCATE RENAME GRANT REVOKE COMMENT
      CALL DO EXECUTE COPY LOAD IMPORT
      VACUUM REINDEX CLUSTER REFRESH ANALYZE OPTIMIZE REPAIR
    ].freeze

    # DML that can be written without the INTO the anywhere-scan requires.
    BARE_DML = %w[REPLACE MERGE UPSERT].freeze

    module_function

    # Every write the SQL would make; empty when it only reads. `mysql` selects
    # MySQL's lexical rules (see .skeleton).
    def find(sql, mysql: false)
      skeleton(sql.to_s, mysql).split(';').flat_map { |statement| statement_writes(statement) }
    end

    # --- lexing -----------------------------------------------------------

    STRING        = /'(?:[^']|'')*'/
    ESCAPE_STRING = /'(?:[^'\\]|\\.|'')*'/m
    BACKTICKED    = /`(?:[^`]|``)*`/
    DOUBLE_QUOTED = /"(?:[^"]|"")*"/
    BLOCK_COMMENT = %r{/\*.*?\*/}m

    # Where the dialects disagree, each rule set follows its own database, and
    # the default set is the one for everything that isn't MySQL:
    #   - backslash escapes a quote inside '...' on MySQL; elsewhere only in E'...'
    #   - "..." is a string on MySQL and an identifier elsewhere
    #   - `#` starts a comment on MySQL and is an operator on PostgreSQL
    #   - `--` needs trailing whitespace to be a comment on MySQL
    #   - $tag$...$tag$ is a string on PostgreSQL
    STANDARD_TOKENS = Regexp.union(
      /--[^\n]*/, BLOCK_COMMENT, /\b[eE]#{ESCAPE_STRING}/, STRING,
      /\$([A-Za-z_]\w*|)\$.*?\$\1\$/m, DOUBLE_QUOTED, BACKTICKED
    )
    MYSQL_TOKENS = Regexp.union(
      /--(?=\s|\z)[^\n]*/, /#[^\n]*/, BLOCK_COMMENT, ESCAPE_STRING,
      /"(?:[^"\\]|\\.|"")*"/m, BACKTICKED
    )

    # MySQL and MariaDB execute the contents of /*! ... */ and /*M! ... */.
    EXECUTABLE_COMMENT = %r{\A/\*M?!\d*(.*)\*/\z}m

    # The SQL with everything that isn't code taken out: comments become a
    # space, string literals become '', and quoted identifiers become "name"
    # (or "?" when the name isn't a plain word). What is left can be searched
    # for keywords and split on `;` without tripping over a comment that says
    # "update" or a string that contains a semicolon.
    def skeleton(sql, mysql)
      sql.gsub(mysql ? MYSQL_TOKENS : STANDARD_TOKENS) do |token|
        case token[0]
        when '`'
          identifier(token)
        when '"'
          mysql ? "''" : identifier(token)
        when '/'
          mysql && (inner = token[EXECUTABLE_COMMENT, 1]) ? " #{skeleton(inner, mysql)} " : ' '
        when '-', '#'
          ' '
        else
          "''"
        end
      end
    end

    def identifier(token)
      name = token[1..-2]
      name.match?(/\A[\w$]+\z/) ? %("#{name}") : '"?"'
    end

    # --- classifying one statement ----------------------------------------

    IDENT     = /(?:"[\w$?]++"|[\w$]++)/
    QUALIFIED = /(?>(?:#{IDENT}\.)*#{IDENT})/
    ONE_TABLE = /(#{QUALIFIED})(?!\s*,)/

    # INSERT, UPDATE and DELETE also appear inside clauses that don't start a
    # write of their own: row locks, upsert and MERGE actions, foreign key rules.
    CLAUSE_KEYWORDS = /\b(?:FOR(?:\s+NO\s+KEY)?|ON\s+DUPLICATE\s+KEY|DO|ON|THEN)\s+(?:INSERT|UPDATE|DELETE)\b/i

    # DML anywhere in a statement. INSERT( is MySQL's string function; MERGE and
    # REPLACE are only keywords here when INTO follows, because `merge` is a
    # legal column name and REPLACE( is a function everywhere.
    DML = /
      (?<!["\w$.])
      (?: INSERT (?!\s*\()
        | UPDATE
        | DELETE
        | MERGE   (?=\s+INTO\b)
        | REPLACE (?=\s+(?:(?:LOW_PRIORITY|DELAYED)\s+)*INTO\b)
      )
      (?!["\w$])
    /ix

    DML_TARGETS = {
      'INSERT'  => /\AINSERT\s+(?:(?:LOW_PRIORITY|DELAYED|HIGH_PRIORITY|IGNORE|OR\s+\w+)\s+)*(?:INTO\s+)?#{ONE_TABLE}/i,
      'REPLACE' => /\AREPLACE\s+(?:(?:LOW_PRIORITY|DELAYED)\s+)*INTO\s+#{ONE_TABLE}/i,
      # Only the single-table form. `UPDATE a JOIN b SET b.x = ...` writes a
      # table other than the first one named, so it gets no target at all.
      'UPDATE'  => /\AUPDATE\s+(?:(?:LOW_PRIORITY|IGNORE|ONLY|OR\s+\w+)\s+)*#{ONE_TABLE}(?=\s+(?:AS\s+)?(?:\w+\s+)?SET\b)/i,
      'DELETE'  => /\ADELETE\s+(?:(?:LOW_PRIORITY|QUICK|IGNORE)\s+)*FROM\s+(?:ONLY\s+)?#{ONE_TABLE}/i,
      'MERGE'   => /\AMERGE\s+INTO\s+(?:ONLY\s+)?#{ONE_TABLE}/i
    }.freeze

    DDL_TARGET = /
      \A(?: (?:CREATE|ALTER|DROP|RENAME) \s+
            (?:(?:GLOBAL|LOCAL|TEMPORARY|TEMP|UNLOGGED|FOREIGN|VIRTUAL|OR\s+REPLACE)\s+)*
            TABLE
          | TRUNCATE (?:\s+TABLE)?
        ) \s+
      (?:IF\s+(?:NOT\s+)?EXISTS\s+)?
      (?:ONLY\s+)?
      #{ONE_TABLE}
    /ix

    def statement_writes(statement)
      statement = statement.sub(/\A[\s(]+/, '')
      keyword = statement[/\A[A-Za-z]+/].to_s.upcase
      return [] if keyword.empty?
      # EXPLAIN only runs the statement it explains when asked to ANALYZE it.
      return [] if %w[EXPLAIN DESCRIBE DESC].include?(keyword) && !statement.match?(/\bANALYZE\b/i)

      writes = dml_writes(statement)

      if non_dml?(keyword, statement)
        writes << write(keyword, statement[DDL_TARGET, 1], statement)
      elsif writes.empty? && BARE_DML.include?(keyword)
        writes << write(keyword, nil, statement)
      elsif writes.empty? && statement.match?(/\bINTO\s+(?!@)/i)
        # SELECT ... INTO new_table (PostgreSQL) or INTO OUTFILE (MySQL).
        writes << write('SELECT INTO', nil, statement)
      end

      writes
    end

    def dml_writes(statement)
      scannable = statement.gsub(CLAUSE_KEYWORDS) { |clause| clause.gsub(/\s+/, '_') }
      writes = []
      scannable.scan(DML) do
        keyword = Regexp.last_match[0].upcase
        from_keyword = scannable[Regexp.last_match.begin(0)..-1]
        writes << write(keyword, from_keyword[DML_TARGETS.fetch(keyword), 1], from_keyword)
      end
      writes
    end

    def non_dml?(keyword, statement)
      return false unless NON_DML.include?(keyword)
      # COPY ... TO STDOUT is an export; any DML inside it is found by the scan.
      !(keyword == 'COPY' && statement.match?(/\bTO\s+STDOUT\b/i))
    end

    def write(keyword, qualified, text)
      qualified = nil if qualified && qualified.include?('?')
      qualified = qualified.delete('"') if qualified
      table = qualified && qualified.split('.').last
      Write.new(keyword, table, qualified, text.strip.split(/\s+/).first(3).join(' '))
    end
  end
end
