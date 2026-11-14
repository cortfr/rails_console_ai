require 'spec_helper'
require 'active_record'
require 'rails_console_ai/safety_guards'

sqlite_available = begin
  require 'sqlite3'
  true
rescue LoadError
  false
end

RSpec.describe RailsConsoleAi::BuiltinGuards do
  describe '.low_level_write_blocker' do
    let(:adapter_class) do
      Class.new do
        def internal_exec_query(sql, *_args, **_kwargs)
          sql
        end
      end
    end
    let(:blocked_class) do
      klass = Class.new(adapter_class)
      klass.prepend(described_class.low_level_write_blocker(klass))
      klass.prepend(RailsConsoleAi::BuiltinGuards::WriteBlocker)
      klass
    end

    it 'checks SQL arriving at an entry point the adapter has' do
      RailsConsoleAi::GuardState[:block_writes] = true
      expect { blocked_class.new.internal_exec_query('INSERT INTO users (a) VALUES (1)') }
        .to raise_error(RailsConsoleAi::SafetyError, /Database write blocked/)
      expect(blocked_class.new.internal_exec_query('SELECT 1')).to eq('SELECT 1')
    end

    it 'does not add an entry point the adapter lacks' do
      expect(blocked_class.new.respond_to?(:raw_execute, true)).to be false
    end

    it 'keeps a private entry point private' do
      adapter_class.class_eval do
        private

        def raw_execute(sql, *_args, **_kwargs)
          sql
        end
      end

      instance = blocked_class.new
      expect(instance.respond_to?(:raw_execute)).to be false
      RailsConsoleAi::GuardState[:block_writes] = true
      expect { instance.send(:raw_execute, 'DELETE FROM users') }
        .to raise_error(RailsConsoleAi::SafetyError, /Database write blocked/)
    end
  end

  # Against a real adapter, because which internal method a query goes through
  # is exactly what changed between Rails versions.
  describe 'the write blocker on a real connection', if: sqlite_available do
    before(:all) do
      ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
      ActiveRecord::Base.connection.create_table(:guarded_widgets, force: true) { |t| t.string :name }
      described_class.ensure_write_blocker_installed!
    end

    after(:all) do
      ActiveRecord::Base.remove_connection
    end

    let(:model) do
      Class.new(ActiveRecord::Base) do
        self.table_name = 'guarded_widgets'

        def self.name
          'GuardedWidget'
        end
      end
    end
    let(:connection) { ActiveRecord::Base.connection }

    before do
      model.delete_all
      model.create!(name: 'seed')
    end

    def blocked
      raise_error { |error|
        chain = [error, error.cause].compact
        expect(chain.any? { |e| e.is_a?(RailsConsoleAi::SafetyError) }).to be(true), "expected a SafetyError, got #{error.class}: #{error.message}"
      }
    end

    context 'with writes blocked' do
      before { RailsConsoleAi::GuardState[:block_writes] = true }

      it 'still reads' do
        expect(model.count).to eq(1)
        expect(model.find_by_sql('SELECT * FROM guarded_widgets').size).to eq(1)
        expect(model.transaction { model.lock.first.name }).to eq('seed')
      end

      it 'blocks ordinary writes' do
        expect { model.create!(name: 'x') }.to blocked
        expect { model.update_all(name: 'x') }.to blocked
        expect { model.delete_all }.to blocked
      end

      it 'blocks bulk inserts and upserts' do
        expect { model.insert_all([{ name: 'x' }]) }.to blocked
        expect { model.upsert_all([{ id: model.first.id, name: 'x' }]) }.to blocked
      end

      it 'blocks a write passed to a select method' do
        expect { connection.select_all('DELETE FROM guarded_widgets RETURNING id').to_a }.to blocked
        expect { model.find_by_sql("UPDATE guarded_widgets SET name = 'x' RETURNING *").to_a }.to blocked
      end

      it 'leaves the data untouched' do
        [-> { model.insert_all([{ name: 'x' }]) }, -> { model.update_all(name: 'x') }].each do |write|
          begin
            write.call
          rescue StandardError
            nil
          end
        end
        RailsConsoleAi::GuardState[:block_writes] = nil

        expect(model.pluck(:name)).to eq(['seed'])
      end
    end

    it 'blocks reads through the model under the hard sandbox' do
      guards = RailsConsoleAi::SafetyGuards.new
      expect { guards.with_database_blocked { model.count } }.to blocked
      expect { guards.with_database_blocked { connection.select_all('SELECT 1').to_a } }.to blocked
    end
  end
end
