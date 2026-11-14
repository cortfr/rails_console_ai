require 'spec_helper'
require 'rails_console_ai/safety_guards'

RSpec.describe RailsConsoleAi::GuardState do
  let(:state) { described_class }

  # Fiber storage (Ruby 3.2+) is what carries a scope into a spawned thread.
  inheritable = described_class::INHERITABLE

  describe '.with' do
    it 'sets the values for the block and restores what was there before' do
      state[:block_writes] = :outer
      seen = nil
      state.with(block_writes: true) { seen = state[:block_writes] }

      expect(seen).to be true
      expect(state[:block_writes]).to eq(:outer)
    end

    it 'restores even when the block raises' do
      expect { state.with(block_writes: true) { raise 'boom' } }.to raise_error('boom')
      expect(state[:block_writes]).to be_nil
    end

    it 'nests, with the innermost scope winning' do
      seen = []
      state.with(block_writes: true) do
        state.with(bypass_guards: true) do
          seen << [state[:block_writes], state[:bypass_guards]]
        end
        seen << [state[:block_writes], state[:bypass_guards]]
      end

      expect(seen).to eq([[true, true], [true, nil]])
    end

    it 'is visible inside a Fiber' do
      seen = nil
      state.with(block_writes: true) { seen = Fiber.new { state[:block_writes] }.resume }
      expect(seen).to be true
    end

    it 'is visible inside an external Enumerator' do
      seen = nil
      state.with(block_writes: true) do
        seen = Enumerator.new { |y| y << state[:block_writes] }.next
      end
      expect(seen).to be true
    end

    it 'is visible to a fiber that was created before the block' do
      enum = Enumerator.new { |y| loop { y << state[:block_writes] } }
      expect(enum.next).to be_nil # the enumerator's fiber now exists

      seen = nil
      state.with(block_writes: true) { seen = enum.next }
      expect(seen).to be true
    end

    it 'is visible inside a spawned Thread, and a thread that one spawns', if: inheritable do
      seen = nil
      state.with(block_writes: true) do
        seen = Thread.new { [state[:block_writes], Thread.new { state[:block_writes] }.value] }.value
      end
      expect(seen).to eq([true, true])
    end

    it 'stops applying to a spawned thread once the block has exited', if: inheritable do
      release = Queue.new
      thread = nil
      state.with(block_writes: true) do
        thread = Thread.new do
          during = state[:block_writes]
          release.pop
          [during, state[:block_writes]]
        end
        sleep 0.01 until thread.status == 'sleep'
      end
      release << true

      expect(thread.value).to eq([true, nil])
    end

    it 'keeps an outer scope applying in a spawned thread after an inner one exits', if: inheritable do
      release = Queue.new
      result = nil
      state.with(block_writes: true) do
        thread = nil
        state.with(bypass_guards: true) do
          thread = Thread.new do
            release.pop
            [state[:block_writes], state[:bypass_guards]]
          end
          sleep 0.01 until thread.status == 'sleep'
        end
        release << true
        result = thread.value
      end

      expect(result).to eq([true, nil])
    end

    it 'does not leak a scope opened in one spawned thread into its sibling', if: inheritable do
      entered = Queue.new
      release = Queue.new
      sibling_saw = nil
      state.with(block_writes: true) do
        bypassing = Thread.new do
          state.with(bypass_guards: true) do
            entered << true
            release.pop
          end
        end
        entered.pop
        sibling_saw = Thread.new { state[:bypass_guards] }.value
        release << true
        bypassing.join
      end

      expect(sibling_saw).to be_nil
    end

    it 'does not apply to a thread that existed before the block' do
      ask = Queue.new
      answer = Queue.new
      thread = Thread.new do
        ask.pop
        answer << state[:block_writes]
      end
      state.with(block_writes: true) do
        ask << true
        expect(answer.pop).to be_nil
      end
      thread.join
    end
  end

  describe '.[]=' do
    it 'is visible to every fiber on the thread' do
      state[:guards_disabled] = true
      expect(Fiber.new { state[:guards_disabled] }.resume).to be true
    end

    it 'belongs to the calling thread only' do
      state[:guards_disabled] = true
      expect(Thread.new { state[:guards_disabled] }.value).to be_nil
    end
  end

  describe 'legacy Thread.current keys' do
    it 'mirrors scoped values for host code that reads them' do
      seen = nil
      state.with(session_active: true) { seen = Thread.current[:rails_console_ai_session_active] }

      expect(seen).to be true
      expect(Thread.current[:rails_console_ai_session_active]).to be_nil
    end

    it 'mirrors values set with []=' do
      state[:guards_disabled] = true
      expect(Thread.current[:rails_console_ai_guards_disabled]).to be true
    end

    it 'honours a value host code set directly' do
      Thread.current[:rails_console_ai_bypass_guards] = true
      expect(state[:bypass_guards]).to be true
    end
  end

  describe 'through the guards' do
    let(:connection_class) do
      Class.new do
        prepend RailsConsoleAi::BuiltinGuards::WriteBlocker

        def execute(sql, *_args, **_kwargs)
          sql
        end
      end
    end
    let(:connection) { connection_class.new }
    let(:guards) do
      RailsConsoleAi::SafetyGuards.new.tap do |g|
        g.add(:database_writes, &RailsConsoleAi::BuiltinGuards.database_writes)
      end
    end
    let(:write) { 'UPDATE users SET admin = 1' }

    # A thread whose exception the example expects, so Ruby needn't print it.
    def quiet_thread(&block)
      Thread.new do
        Thread.current.report_on_exception = false
        block.call
      end
    end

    before do
      allow(RailsConsoleAi::BuiltinGuards).to receive(:ensure_write_blocker_installed!)
      allow(RailsConsoleAi.configuration).to receive(:safety_guards).and_return(guards)
    end

    it 'blocks a write made from a Fiber' do
      expect { guards.wrap { Fiber.new { connection.execute(write) }.resume } }
        .to raise_error(RailsConsoleAi::SafetyError, /Database write blocked/)
    end

    it 'blocks a write made from an external Enumerator' do
      expect { guards.wrap { Enumerator.new { |y| y << connection.execute(write) }.next } }
        .to raise_error(RailsConsoleAi::SafetyError, /Database write blocked/)
    end

    it 'blocks a write made from a spawned Thread', if: inheritable do
      expect { guards.wrap { quiet_thread { connection.execute(write) }.value } }
        .to raise_error(RailsConsoleAi::SafetyError, /Database write blocked/)
    end

    it 'applies the session allowlist in a spawned Thread', if: inheritable do
      guards.allow(:database_writes, 'users')
      expect(guards.wrap { Thread.new { connection.execute(write) }.value }).to eq(write)
    end

    it 'applies without_guards to a Thread spawned inside it', if: inheritable do
      result = guards.wrap do
        guards.without_guards { Thread.new { connection.execute(write) }.value }
      end
      expect(result).to eq(write)
    end

    it 'reports a blocked write that a spawned thread rescued', if: inheritable do
      RailsConsoleAi::SafetyError.clear!
      guards.wrap do
        Thread.new do
          begin
            connection.execute(write)
          rescue RailsConsoleAi::SafetyError
            nil
          end
        end.join
      end

      expect(RailsConsoleAi::SafetyError.last_raised).to be_a(RailsConsoleAi::SafetyError)
    end

    it 'blocks all database access from a spawned Thread under with_database_blocked', if: inheritable do
      expect { guards.with_database_blocked { quiet_thread { connection.execute('SELECT 1') }.value } }
        .to raise_error(RailsConsoleAi::SafetyError, /Database access is disabled/)
    end
  end
end
