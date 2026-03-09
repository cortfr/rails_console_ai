require 'spec_helper'
require 'rails_console_ai/executor'

RSpec.describe RailsConsoleAi::Executor do
  let(:test_binding) { binding }
  subject(:executor) { described_class.new(test_binding) }

  describe '#extract_code' do
    it 'extracts a single ruby code block' do
      response = <<~TEXT
        Here is some code:
        ```ruby
        User.count
        ```
        That will count users.
      TEXT

      expect(executor.extract_code(response)).to eq("User.count")
    end

    it 'extracts only the first ruby code block' do
      response = <<~TEXT
        First:
        ```ruby
        User.count
        ```
        Then:
        ```ruby
        Post.count
        ```
      TEXT

      code = executor.extract_code(response)
      expect(code).to eq('User.count')
    end

    it 'returns empty string when no code blocks found' do
      expect(executor.extract_code('No code here')).to eq('')
    end

    it 'ignores non-ruby code blocks' do
      response = <<~TEXT
        ```sql
        SELECT * FROM users;
        ```
        ```ruby
        User.all
        ```
      TEXT

      expect(executor.extract_code(response)).to eq("User.all")
    end
  end

  describe '#execute' do
    it 'evaluates code in the given binding' do
      result = executor.execute('1 + 1')
      expect(result).to eq(2)
    end

    it 'returns nil for empty code' do
      expect(executor.execute('')).to be_nil
      expect(executor.execute(nil)).to be_nil
    end

    it 'rescues syntax errors' do
      expect(executor.execute('def foo(')).to be_nil
    end

    it 'rescues runtime errors' do
      expect(executor.execute('raise "boom"')).to be_nil
    end

    it 'sets last_error on syntax error' do
      executor.execute('def foo(')
      expect(executor.last_error).to include('SyntaxError')
    end

    it 'sets last_error on runtime error' do
      executor.execute('raise "boom"')
      expect(executor.last_error).to include('RuntimeError')
      expect(executor.last_error).to include('boom')
    end

    it 'clears last_error on successful execution' do
      executor.execute('raise "boom"')
      expect(executor.last_error).not_to be_nil
      executor.execute('1 + 1')
      expect(executor.last_error).to be_nil
    end
  end

  describe '#execute with safety guards' do
    it 'wraps execution with configured safety guards' do
      call_log = []
      RailsConsoleAi.configuration.safety_guard(:test) do |&block|
        call_log << :guard_before
        result = block.call
        call_log << :guard_after
        result
      end

      result = executor.execute('1 + 1')
      expect(result).to eq(2)
      expect(call_log).to eq([:guard_before, :guard_after])
    end

    it 'skips guards when safety guards are disabled' do
      call_log = []
      RailsConsoleAi.configuration.safety_guard(:test) do |&block|
        call_log << :guard
        block.call
      end
      RailsConsoleAi.configuration.safety_guards.disable!

      result = executor.execute('1 + 1')
      expect(result).to eq(2)
      expect(call_log).to be_empty
    end

    it 'reports guard errors as execution errors' do
      RailsConsoleAi.configuration.safety_guard(:blocker) do |&block|
        raise RuntimeError, "write blocked!"
      end

      result = executor.execute('"hello"')
      expect(result).to be_nil
      expect(executor.last_error).to include("write blocked!")
    end

    it 'catches SafetyError with a helpful message' do
      RailsConsoleAi.configuration.safety_guard(:blocker) do |&block|
        raise RailsConsoleAi::SafetyError.new("Database write blocked", guard: :database_writes, blocked_key: "users")
      end

      result = executor.execute('"hello"')
      expect(result).to be_nil
      expect(executor.last_error).to include("SafetyError")
      expect(executor.last_error).to include("Database write blocked")
      expect(executor.last_safety_error).to eq(true)
      expect(executor.last_safety_exception).to be_a(RailsConsoleAi::SafetyError)
      expect(executor.last_safety_exception.guard).to eq(:database_writes)
      expect(executor.last_safety_exception.blocked_key).to eq("users")
    end

    it 'detects SafetyError wrapped by another exception' do
      RailsConsoleAi.configuration.safety_guard(:blocker) do |&block|
        begin
          raise RailsConsoleAi::SafetyError.new("Database write blocked", guard: :database_writes, blocked_key: "users")
        rescue RailsConsoleAi::SafetyError
          raise RuntimeError, "wrapped error"
        end
      end

      result = executor.execute('"hello"')
      expect(result).to be_nil
      expect(executor.last_safety_error).to eq(true)
      expect(executor.last_error).to include("SafetyError")
      expect(executor.last_error).to include("Database write blocked")
      expect(executor.last_safety_exception.guard).to eq(:database_writes)
      expect(executor.last_safety_exception.blocked_key).to eq("users")
    end

    it 'clears last_safety_exception on successful execution' do
      RailsConsoleAi.configuration.safety_guard(:blocker) do |&block|
        raise RailsConsoleAi::SafetyError.new("blocked", guard: :test, blocked_key: "x")
      end
      executor.execute('"hello"')
      expect(executor.last_safety_exception).not_to be_nil

      RailsConsoleAi.configuration.safety_guards.remove(:blocker)
      executor.execute('1 + 1')
      expect(executor.last_safety_exception).to be_nil
    end
  end

  describe '#store_output and #recall_output' do
    it 'stores and recalls output by id' do
      id = executor.store_output("some output data")
      expect(executor.recall_output(id)).to eq("some output data")
    end

    it 'assigns incrementing ids' do
      id1 = executor.store_output("first")
      id2 = executor.store_output("second")
      expect(id2).to eq(id1 + 1)
    end

    it 'returns nil for unknown id' do
      expect(executor.recall_output(999)).to be_nil
    end
  end

  describe '#expand_output' do
    it 'stores omitted output when display_result truncates' do
      # Execute something that produces a large result
      result = executor.execute('("x" * 5000)')
      expect(executor.expand_output(1)).to include("x" * 100)
    end

    it 'returns nil when no output was omitted' do
      executor.execute('1 + 1')
      expect(executor.expand_output(1)).to be_nil
    end
  end

  describe '#confirm_and_execute' do
    it 'executes on y' do
      allow($stdin).to receive(:gets).and_return("y\n")
      result = executor.confirm_and_execute('1 + 1')
      expect(result).to eq(2)
    end

    it 'does not execute on n' do
      allow($stdin).to receive(:gets).and_return("n\n")
      result = executor.confirm_and_execute('1 + 1')
      expect(result).to be_nil
    end

    it 'does not execute on empty input' do
      allow($stdin).to receive(:gets).and_return("\n")
      result = executor.confirm_and_execute('1 + 1')
      expect(result).to be_nil
    end

    it 'returns nil for empty code' do
      expect(executor.confirm_and_execute('')).to be_nil
    end

    it 'executes with guards disabled on danger' do
      call_log = []
      RailsConsoleAi.configuration.safety_guard(:test) do |&block|
        call_log << :guard
        block.call
      end

      allow($stdin).to receive(:gets).and_return("d\n")
      result = executor.confirm_and_execute('1 + 1')
      expect(result).to eq(2)
      expect(call_log).to be_empty
    end

    it 're-enables guards after danger execution' do
      RailsConsoleAi.configuration.safety_guard(:test) { |&b| b.call }
      allow($stdin).to receive(:gets).and_return("d\n")
      executor.confirm_and_execute('1 + 1')
      expect(RailsConsoleAi.configuration.safety_guards).to be_enabled
    end
  end

  describe '#offer_danger_retry' do
    it 'adds to allowlist when user chooses a' do
      # Simulate a safety error with metadata
      executor.instance_variable_set(:@last_safety_exception,
        RailsConsoleAi::SafetyError.new("blocked", guard: :http_mutations, blocked_key: "s3.amazonaws.com"))
      executor.instance_variable_set(:@last_safety_error, true)

      allow($stdin).to receive(:gets).and_return("a\n")
      executor.offer_danger_retry('1 + 1')

      expect(RailsConsoleAi.configuration.safety_guards.allowed?(:http_mutations, "s3.amazonaws.com")).to be true
    end

    it 'disables all guards when user chooses d' do
      call_log = []
      RailsConsoleAi.configuration.safety_guard(:test) do |&block|
        call_log << :guard
        block.call
      end

      executor.instance_variable_set(:@last_safety_exception,
        RailsConsoleAi::SafetyError.new("blocked", guard: :http_mutations, blocked_key: "evil.com"))
      executor.instance_variable_set(:@last_safety_error, true)

      allow($stdin).to receive(:gets).and_return("d\n")
      result = executor.offer_danger_retry('1 + 1')
      expect(result).to eq(2)
      expect(call_log).to be_empty
      expect(RailsConsoleAi.configuration.safety_guards).to be_enabled
    end

    it 'returns nil when user cancels' do
      executor.instance_variable_set(:@last_safety_exception,
        RailsConsoleAi::SafetyError.new("blocked", guard: :test, blocked_key: "x"))
      executor.instance_variable_set(:@last_safety_error, true)

      allow($stdin).to receive(:gets).and_return("n\n")
      result = executor.offer_danger_retry('1 + 1')
      expect(result).to be_nil
    end
  end
end
