require 'spec_helper'
require 'console_agent/safety_guards'

RSpec.describe ConsoleAgent::SafetyError do
  it 'stores guard and blocked_key metadata' do
    error = described_class.new("blocked", guard: :http_mutations, blocked_key: "example.com")
    expect(error.message).to eq("blocked")
    expect(error.guard).to eq(:http_mutations)
    expect(error.blocked_key).to eq("example.com")
  end

  it 'defaults guard and blocked_key to nil' do
    error = described_class.new("blocked")
    expect(error.guard).to be_nil
    expect(error.blocked_key).to be_nil
  end
end

RSpec.describe ConsoleAgent::SafetyGuards do
  subject(:guards) { described_class.new }

  describe '#add' do
    it 'registers a guard by name' do
      guards.add(:test_guard) { |&b| b.call }
      expect(guards.names).to eq([:test_guard])
    end

    it 'accepts string names and converts to symbols' do
      guards.add('test_guard') { |&b| b.call }
      expect(guards.names).to eq([:test_guard])
    end
  end

  describe '#remove' do
    it 'removes a registered guard' do
      guards.add(:test_guard) { |&b| b.call }
      guards.remove(:test_guard)
      expect(guards.names).to be_empty
    end
  end

  describe '#enabled? / #enable! / #disable!' do
    it 'is enabled by default' do
      expect(guards).to be_enabled
    end

    it 'can be disabled and re-enabled' do
      guards.disable!
      expect(guards).not_to be_enabled
      guards.enable!
      expect(guards).to be_enabled
    end
  end

  describe '#empty?' do
    it 'is true when no guards are registered' do
      expect(guards).to be_empty
    end

    it 'is false when guards are registered' do
      guards.add(:test) { |&b| b.call }
      expect(guards).not_to be_empty
    end
  end

  describe '#allow / #allowed? / #allowlist' do
    it 'allows a string key for a guard' do
      guards.allow(:http_mutations, "s3.amazonaws.com")
      expect(guards.allowed?(:http_mutations, "s3.amazonaws.com")).to be true
      expect(guards.allowed?(:http_mutations, "evil.com")).to be false
    end

    it 'allows a regexp key for a guard' do
      guards.allow(:http_mutations, /googleapis\.com/)
      expect(guards.allowed?(:http_mutations, "sheets.googleapis.com")).to be true
      expect(guards.allowed?(:http_mutations, "evil.com")).to be false
    end

    it 'does not duplicate entries' do
      guards.allow(:http_mutations, "s3.amazonaws.com")
      guards.allow(:http_mutations, "s3.amazonaws.com")
      expect(guards.allowlist[:http_mutations].length).to eq(1)
    end

    it 'returns false for unknown guard names' do
      expect(guards.allowed?(:unknown, "anything")).to be false
    end

    it 'returns the full allowlist hash' do
      guards.allow(:http_mutations, "s3.amazonaws.com")
      guards.allow(:database_writes, "sessions")
      expect(guards.allowlist.keys).to contain_exactly(:http_mutations, :database_writes)
    end
  end

  describe '#wrap' do
    it 'yields directly when no guards are registered' do
      result = guards.wrap { 42 }
      expect(result).to eq(42)
    end

    it 'yields directly when disabled' do
      call_log = []
      guards.add(:test) do |&block|
        call_log << :guard
        block.call
      end
      guards.disable!

      result = guards.wrap { 42 }
      expect(result).to eq(42)
      expect(call_log).to be_empty
    end

    it 'wraps execution with a single guard' do
      call_log = []
      guards.add(:test) do |&block|
        call_log << :before
        result = block.call
        call_log << :after
        result
      end

      result = guards.wrap do
        call_log << :execute
        42
      end

      expect(result).to eq(42)
      expect(call_log).to eq([:before, :execute, :after])
    end

    it 'composes multiple guards in order' do
      call_log = []
      guards.add(:first) do |&block|
        call_log << :first_before
        result = block.call
        call_log << :first_after
        result
      end
      guards.add(:second) do |&block|
        call_log << :second_before
        result = block.call
        call_log << :second_after
        result
      end

      guards.wrap { call_log << :execute }

      # reduce wraps from right to left: second wraps the block, then first wraps second
      expect(call_log).to eq([:second_before, :first_before, :execute, :first_after, :second_after])
    end

    it 'propagates exceptions from the guarded block' do
      guards.add(:test) { |&b| b.call }

      expect {
        guards.wrap { raise RuntimeError, "boom" }
      }.to raise_error(RuntimeError, "boom")
    end

    it 'a guard can prevent execution' do
      guards.add(:blocker) do |&block|
        raise "blocked!"
      end

      expect {
        guards.wrap { 42 }
      }.to raise_error(RuntimeError, "blocked!")
    end
  end
end

RSpec.describe ConsoleAgent::BuiltinGuards do
  describe '.database_writes' do
    it 'returns a callable guard' do
      guard = described_class.database_writes
      expect(guard).to respond_to(:call)
    end

    it 'sets and clears the thread-local flag' do
      guard = described_class.database_writes
      flag_during = nil

      # Stub the install to avoid needing a real AR connection
      allow(described_class).to receive(:ensure_write_blocker_installed!)

      guard.call do
        flag_during = Thread.current[:console_agent_block_writes]
      end

      expect(flag_during).to eq(true)
      expect(Thread.current[:console_agent_block_writes]).to eq(false)
    end

    it 'clears the flag even on exception' do
      guard = described_class.database_writes
      allow(described_class).to receive(:ensure_write_blocker_installed!)

      begin
        guard.call { raise "boom" }
      rescue
      end

      expect(Thread.current[:console_agent_block_writes]).to eq(false)
    end
  end

  describe '.mailers' do
    before do
      stub_const('ActionMailer::Base', Class.new { class << self; attr_accessor :perform_deliveries; end })
      ActionMailer::Base.perform_deliveries = true
    end

    it 'returns a callable guard' do
      expect(described_class.mailers).to respond_to(:call)
    end

    it 'disables delivery during execution and restores after' do
      guard = described_class.mailers
      during = nil

      guard.call do
        during = ActionMailer::Base.perform_deliveries
      end

      expect(during).to eq(false)
      expect(ActionMailer::Base.perform_deliveries).to eq(true)
    end

    it 'restores original value even on exception' do
      guard = described_class.mailers

      begin
        guard.call { raise "boom" }
      rescue
      end

      expect(ActionMailer::Base.perform_deliveries).to eq(true)
    end
  end

  describe ConsoleAgent::BuiltinGuards::WriteBlocker do
    let(:test_class) do
      Class.new do
        def execute(sql, *args, **kwargs)
          sql # base implementation just returns sql
        end

        def exec_delete(sql, *args, **kwargs)
          sql
        end

        def exec_update(sql, *args, **kwargs)
          sql
        end
      end
    end

    let(:blocked_class) do
      klass = Class.new(test_class)
      klass.prepend(ConsoleAgent::BuiltinGuards::WriteBlocker)
      klass
    end

    let(:adapter) { blocked_class.new }

    context 'when block_writes flag is set' do
      before { Thread.current[:console_agent_block_writes] = true }
      after  { Thread.current[:console_agent_block_writes] = false }

      it 'blocks INSERT statements' do
        expect { adapter.execute("INSERT INTO users (name) VALUES ('test')") }
          .to raise_error(ConsoleAgent::SafetyError, /Database write blocked/)
      end

      it 'blocks UPDATE statements' do
        expect { adapter.execute("UPDATE users SET name = 'test'") }
          .to raise_error(ConsoleAgent::SafetyError, /Database write blocked/)
      end

      it 'blocks DELETE statements' do
        expect { adapter.execute("DELETE FROM users WHERE id = 1") }
          .to raise_error(ConsoleAgent::SafetyError, /Database write blocked/)
      end

      it 'blocks DROP statements' do
        expect { adapter.execute("DROP TABLE users") }
          .to raise_error(ConsoleAgent::SafetyError, /Database write blocked/)
      end

      it 'blocks TRUNCATE statements' do
        expect { adapter.execute("TRUNCATE TABLE users") }
          .to raise_error(ConsoleAgent::SafetyError, /Database write blocked/)
      end

      it 'allows SELECT statements' do
        expect(adapter.execute("SELECT * FROM users")).to eq("SELECT * FROM users")
      end

      it 'allows SHOW statements' do
        expect(adapter.execute("SHOW TABLES")).to eq("SHOW TABLES")
      end

      it 'blocks exec_delete' do
        expect { adapter.exec_delete("DELETE FROM users WHERE id = 1") }
          .to raise_error(ConsoleAgent::SafetyError, /Database write blocked/)
      end

      it 'blocks exec_update' do
        expect { adapter.exec_update("UPDATE users SET name = 'test'") }
          .to raise_error(ConsoleAgent::SafetyError, /Database write blocked/)
      end

      it 'includes guard and blocked_key in SafetyError' do
        error = nil
        begin
          adapter.execute("INSERT INTO users (name) VALUES ('test')")
        rescue ConsoleAgent::SafetyError => e
          error = e
        end
        expect(error.guard).to eq(:database_writes)
        expect(error.blocked_key).to eq("users")
      end

      it 'allows writes to allowlisted tables' do
        ConsoleAgent.configuration.safety_guards.allow(:database_writes, 'users')
        expect(adapter.execute("INSERT INTO users (name) VALUES ('test')"))
          .to eq("INSERT INTO users (name) VALUES ('test')")
      end
    end

    context 'when block_writes flag is not set' do
      before { Thread.current[:console_agent_block_writes] = false }

      it 'allows all statements' do
        expect(adapter.execute("INSERT INTO users (name) VALUES ('test')"))
          .to eq("INSERT INTO users (name) VALUES ('test')")
        expect(adapter.execute("SELECT * FROM users"))
          .to eq("SELECT * FROM users")
      end
    end
  end

  describe '.http_mutations' do
    it 'returns a callable guard' do
      guard = described_class.http_mutations
      expect(guard).to respond_to(:call)
    end

    it 'sets and clears the thread-local flag' do
      guard = described_class.http_mutations
      flag_during = nil

      allow(described_class).to receive(:ensure_http_blocker_installed!)

      guard.call do
        flag_during = Thread.current[:console_agent_block_http]
      end

      expect(flag_during).to eq(true)
      expect(Thread.current[:console_agent_block_http]).to eq(false)
    end

    it 'clears the flag even on exception' do
      guard = described_class.http_mutations
      allow(described_class).to receive(:ensure_http_blocker_installed!)

      begin
        guard.call { raise "boom" }
      rescue
      end

      expect(Thread.current[:console_agent_block_http]).to eq(false)
    end
  end

  describe ConsoleAgent::BuiltinGuards::HttpBlocker do
    let(:test_class) do
      Class.new do
        attr_accessor :address

        def initialize
          @address = 'example.com'
        end

        def request(req, *args, &block)
          "#{req.method} #{req.path}"
        end
      end
    end

    let(:blocked_class) do
      klass = Class.new(test_class)
      klass.prepend(ConsoleAgent::BuiltinGuards::HttpBlocker)
      klass
    end

    let(:http) { blocked_class.new }

    # Minimal request stub matching Net::HTTP request interface
    let(:get_req) { Struct.new(:method, :path).new('GET', '/users') }
    let(:head_req) { Struct.new(:method, :path).new('HEAD', '/users') }
    let(:options_req) { Struct.new(:method, :path).new('OPTIONS', '/users') }
    let(:post_req) { Struct.new(:method, :path).new('POST', '/users') }
    let(:put_req) { Struct.new(:method, :path).new('PUT', '/users/1') }
    let(:patch_req) { Struct.new(:method, :path).new('PATCH', '/users/1') }
    let(:delete_req) { Struct.new(:method, :path).new('DELETE', '/users/1') }

    context 'when block_http flag is set' do
      before { Thread.current[:console_agent_block_http] = true }
      after  { Thread.current[:console_agent_block_http] = false }

      it 'allows GET requests' do
        expect(http.request(get_req)).to eq('GET /users')
      end

      it 'allows HEAD requests' do
        expect(http.request(head_req)).to eq('HEAD /users')
      end

      it 'allows OPTIONS requests' do
        expect(http.request(options_req)).to eq('OPTIONS /users')
      end

      it 'blocks POST requests' do
        expect { http.request(post_req) }
          .to raise_error(ConsoleAgent::SafetyError, /HTTP POST blocked/)
      end

      it 'blocks PUT requests' do
        expect { http.request(put_req) }
          .to raise_error(ConsoleAgent::SafetyError, /HTTP PUT blocked/)
      end

      it 'blocks PATCH requests' do
        expect { http.request(patch_req) }
          .to raise_error(ConsoleAgent::SafetyError, /HTTP PATCH blocked/)
      end

      it 'blocks DELETE requests' do
        expect { http.request(delete_req) }
          .to raise_error(ConsoleAgent::SafetyError, /HTTP DELETE blocked/)
      end

      it 'includes guard and blocked_key in SafetyError' do
        error = nil
        begin
          http.request(post_req)
        rescue ConsoleAgent::SafetyError => e
          error = e
        end
        expect(error.guard).to eq(:http_mutations)
        expect(error.blocked_key).to eq("example.com")
      end

      it 'allows requests to allowlisted hosts' do
        ConsoleAgent.configuration.safety_guards.allow(:http_mutations, "example.com")
        expect(http.request(post_req)).to eq("POST /users")
      end

      it 'allows requests matching allowlisted regexp' do
        ConsoleAgent.configuration.safety_guards.allow(:http_mutations, /example\.com/)
        expect(http.request(put_req)).to eq("PUT /users/1")
      end
    end

    context 'when block_http flag is not set' do
      before { Thread.current[:console_agent_block_http] = false }

      it 'allows all requests' do
        expect(http.request(post_req)).to eq('POST /users')
        expect(http.request(delete_req)).to eq('DELETE /users/1')
      end
    end
  end
end
