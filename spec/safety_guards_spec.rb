require 'spec_helper'
require 'rails_console_ai/safety_guards'

RSpec.describe RailsConsoleAi::SafetyError do
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

RSpec.describe RailsConsoleAi::SafetyGuards do
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

  describe '#without_guards' do
    let(:write_adapter) do
      klass = Class.new do
        def execute(sql, *args, **kwargs) = sql
      end
      klass.prepend(RailsConsoleAi::BuiltinGuards::WriteBlocker)
      klass.new
    end

    let(:http_adapter) do
      klass = Class.new do
        attr_accessor :address
        def initialize = (@address = 'example.com')
        def request(req, *args, &block) = "#{req.method} #{req.path}"
      end
      klass.prepend(RailsConsoleAi::BuiltinGuards::HttpBlocker)
      klass.new
    end

    let(:post_req) { Struct.new(:method, :path).new('POST', '/foo') }

    before do
      Thread.current[:rails_console_ai_block_writes] = true
      Thread.current[:rails_console_ai_block_http]   = true
    end

    after do
      Thread.current[:rails_console_ai_block_writes]   = false
      Thread.current[:rails_console_ai_block_http]     = false
      Thread.current[:rails_console_ai_bypass_guards]  = nil
    end

    it 'allows writes inside the block even when guards are enabled' do
      guards.without_guards do
        expect(write_adapter.execute("INSERT INTO users (name) VALUES ('test')"))
          .to eq("INSERT INTO users (name) VALUES ('test')")
      end
    end

    it 'allows HTTP mutations inside the block' do
      guards.without_guards do
        expect(http_adapter.request(post_req)).to eq('POST /foo')
      end
    end

    it 're-enables blocking after the block' do
      guards.without_guards { }
      expect(Thread.current[:rails_console_ai_bypass_guards]).to be_nil
      expect { write_adapter.execute("INSERT INTO users (name) VALUES ('test')") }
        .to raise_error(RailsConsoleAi::SafetyError)
    end

    it 're-enables blocking even if the block raises' do
      begin
        guards.without_guards { raise "boom" }
      rescue
      end
      expect(Thread.current[:rails_console_ai_bypass_guards]).to be_nil
      expect { write_adapter.execute("INSERT INTO users (name) VALUES ('test')") }
        .to raise_error(RailsConsoleAi::SafetyError)
    end

    it 'nesting: inner without_guards works, outer context restored after' do
      guards.without_guards do
        guards.without_guards do
          expect(Thread.current[:rails_console_ai_bypass_guards]).to be true
        end
        expect(Thread.current[:rails_console_ai_bypass_guards]).to be true
      end
      expect(Thread.current[:rails_console_ai_bypass_guards]).to be_nil
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

    it 'sets session_active flag during execution' do
      guards.add(:test) { |&b| b.call }
      flag_during = nil
      guards.wrap { flag_during = Thread.current[:rails_console_ai_session_active] }
      expect(flag_during).to be true
    end

    it 'clears session_active flag after execution' do
      guards.add(:test) { |&b| b.call }
      guards.wrap { }
      expect(Thread.current[:rails_console_ai_session_active]).to be_nil
    end

    it 'clears session_active flag after execution even on exception' do
      guards.add(:test) { |&b| b.call }
      begin
        guards.wrap { raise "boom" }
      rescue
      end
      expect(Thread.current[:rails_console_ai_session_active]).to be_nil
    end

    context 'install_skills_once!' do
      let(:target_class) do
        klass = Class.new do
          def guarded_method
            :original
          end
        end
        stub_const('FakeTargetClass', klass)
        klass
      end

      before do
        target_class # ensure constant is defined
        RailsConsoleAi.configuration.bypass_guards_for_methods = ['FakeTargetClass#guarded_method']
        guards.add(:test) { |&b| b.call }
      end

      after do
        RailsConsoleAi.configuration.bypass_guards_for_methods = []
        Thread.current[:rails_console_ai_bypass_methods] = nil
      end

      it 'skills are not installed before first wrap call' do
        expect(guards.instance_variable_get(:@skills_installed)).to be_nil
      end

      it 'skills are installed lazily on first wrap call' do
        expect(guards.instance_variable_get(:@skills_installed)).to be_nil
        guards.wrap { }
        expect(guards.instance_variable_get(:@skills_installed)).to be true
      end

      it 'install is idempotent - prepend happens once even when wrap is called multiple times' do
        ancestor_count_before = target_class.ancestors.length
        3.times { guards.wrap { } }
        ancestor_count_after = target_class.ancestors.length
        # Only one module should have been prepended despite three wrap calls
        expect(ancestor_count_after - ancestor_count_before).to eq(1)
      end

      it 'shim is a no-op when bypass_methods is nil (outside wrap)' do
        guards.wrap { } # install shims
        Thread.current[:rails_console_ai_bypass_methods] = nil
        instance = target_class.new
        expect(instance.guarded_method).to eq(:original)
      end

      it 'shim bypasses guards when method is in bypass_methods set' do
        instance = target_class.new
        result = nil
        guards.wrap do
          result = instance.guarded_method
        end
        expect(result).to eq(:original)
      end
    end

    context 'additional_bypass_methods' do
      let(:target_class) do
        klass = Class.new do
          def skill_method
            :original
          end
        end
        stub_const('FakeSkillClass', klass)
        klass
      end

      before do
        target_class
        RailsConsoleAi.configuration.bypass_guards_for_methods = []
        guards.add(:test) { |&b| b.call }
      end

      after do
        Thread.current[:rails_console_ai_bypass_methods] = nil
      end

      it 'merges additional bypass methods into the bypass set' do
        bypass_set = nil
        guards.wrap(additional_bypass_methods: Set.new(['FakeSkillClass#skill_method'])) do
          bypass_set = Thread.current[:rails_console_ai_bypass_methods]
        end
        expect(bypass_set).to include('FakeSkillClass#skill_method')
      end

      it 'works with nil additional_bypass_methods' do
        result = guards.wrap(additional_bypass_methods: nil) { 42 }
        expect(result).to eq(42)
      end

      it 'activates bypass for skill methods when in the additional set' do
        guards.install_bypass_method!('FakeSkillClass#skill_method')
        instance = target_class.new
        result = nil
        guards.wrap(additional_bypass_methods: Set.new(['FakeSkillClass#skill_method'])) do
          result = instance.skill_method
        end
        expect(result).to eq(:original)
      end
    end

    context 'install_bypass_method!' do
      let(:target_class) do
        klass = Class.new do
          def public_method
            :original
          end
        end
        stub_const('FakePublicClass', klass)
        klass
      end

      before { target_class }

      it 'is idempotent — does not prepend twice' do
        ancestor_count_before = target_class.ancestors.length
        guards.install_bypass_method!('FakePublicClass#public_method')
        guards.install_bypass_method!('FakePublicClass#public_method')
        ancestor_count_after = target_class.ancestors.length
        expect(ancestor_count_after - ancestor_count_before).to eq(1)
      end

      it 'gracefully handles unknown classes' do
        expect { guards.install_bypass_method!('NonexistentClass#foo') }.not_to raise_error
      end

      it 'gracefully handles specs with no method name' do
        expect { guards.install_bypass_method!('JustAClassName') }.not_to raise_error
      end
    end

    context 'install_bypass_method! with class methods (dot notation)' do
      let(:target_class) do
        klass = Class.new do
          def self.class_level_method
            :original
          end
        end
        stub_const('FakeClassMethodClass', klass)
        klass
      end

      before { target_class }

      after do
        Thread.current[:rails_console_ai_bypass_methods] = nil
      end

      it 'installs bypass on the singleton class for dot-notation specs' do
        guards.install_bypass_method!('FakeClassMethodClass.class_level_method')
        result = nil
        guards.wrap(additional_bypass_methods: Set.new(['FakeClassMethodClass.class_level_method'])) do
          result = FakeClassMethodClass.class_level_method
        end
        expect(result).to eq(:original)
      end

      it 'is idempotent for class method specs' do
        ancestor_count_before = target_class.singleton_class.ancestors.length
        guards.install_bypass_method!('FakeClassMethodClass.class_level_method')
        guards.install_bypass_method!('FakeClassMethodClass.class_level_method')
        ancestor_count_after = target_class.singleton_class.ancestors.length
        expect(ancestor_count_after - ancestor_count_before).to eq(1)
      end
    end

    context 'channel-specific bypass methods' do
      let(:target_class) do
        klass = Class.new do
          def channel_method
            :original
          end
        end
        stub_const('FakeChannelClass', klass)
        klass
      end

      before do
        target_class
        RailsConsoleAi.configuration.bypass_guards_for_methods = []
        RailsConsoleAi.configuration.channels = {
          'slack' => { 'bypass_guards_for_methods' => ['FakeChannelClass#channel_method'] },
          'console' => {}
        }
        guards.add(:test) { |&b| b.call }
      end

      after do
        RailsConsoleAi.configuration.channels = {}
        Thread.current[:rails_console_ai_bypass_methods] = nil
      end

      it 'installs shims from all channel configs' do
        ancestor_count_before = target_class.ancestors.length
        guards.wrap(channel_mode: 'slack') { }
        ancestor_count_after = target_class.ancestors.length
        expect(ancestor_count_after - ancestor_count_before).to eq(1)
      end

      it 'shim activates when method is in the active channel bypass set' do
        instance = target_class.new
        result = nil
        guards.wrap(channel_mode: 'slack') do
          result = instance.channel_method
        end
        expect(result).to eq(:original)
      end

      it 'shim is a no-op when method is not in the active channel bypass set' do
        instance = target_class.new
        result = nil
        guards.wrap(channel_mode: 'console') do
          result = instance.channel_method
        end
        expect(result).to eq(:original)
      end

      it 'merges global and channel-specific bypass methods' do
        RailsConsoleAi.configuration.bypass_guards_for_methods = ['FakeChannelClass#channel_method']
        instance = target_class.new
        result = nil
        guards.wrap(channel_mode: 'console') do
          result = instance.channel_method
        end
        expect(result).to eq(:original)
      end

      it 'sets bypass_methods thread-local with correct set for channel' do
        bypass_set = nil
        guards.wrap(channel_mode: 'slack') do
          bypass_set = Thread.current[:rails_console_ai_bypass_methods]
        end
        expect(bypass_set).to include('FakeChannelClass#channel_method')
      end

      it 'clears bypass_methods thread-local after execution' do
        guards.wrap(channel_mode: 'slack') { }
        expect(Thread.current[:rails_console_ai_bypass_methods]).to be_nil
      end
    end
  end
end

RSpec.describe RailsConsoleAi::BuiltinGuards do
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
        flag_during = Thread.current[:rails_console_ai_block_writes]
      end

      expect(flag_during).to eq(true)
      expect(Thread.current[:rails_console_ai_block_writes]).to eq(false)
    end

    it 'clears the flag even on exception' do
      guard = described_class.database_writes
      allow(described_class).to receive(:ensure_write_blocker_installed!)

      begin
        guard.call { raise "boom" }
      rescue
      end

      expect(Thread.current[:rails_console_ai_block_writes]).to eq(false)
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

  describe RailsConsoleAi::BuiltinGuards::WriteBlocker do
    let(:test_class) do
      Class.new do
        def execute(sql, *args, **kwargs)
          sql # base implementation just returns sql
        end

        def exec_query(sql, *args, **kwargs)
          sql
        end

        def exec_insert(sql, *args, **kwargs)
          sql
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
      klass.prepend(RailsConsoleAi::BuiltinGuards::WriteBlocker)
      klass
    end

    let(:adapter) { blocked_class.new }

    context 'when block_writes flag is set' do
      before { Thread.current[:rails_console_ai_block_writes] = true }
      after  { Thread.current[:rails_console_ai_block_writes] = false }

      it 'blocks INSERT statements' do
        expect { adapter.execute("INSERT INTO users (name) VALUES ('test')") }
          .to raise_error(RailsConsoleAi::SafetyError, /Database write blocked/)
      end

      it 'blocks UPDATE statements' do
        expect { adapter.execute("UPDATE users SET name = 'test'") }
          .to raise_error(RailsConsoleAi::SafetyError, /Database write blocked/)
      end

      it 'blocks DELETE statements' do
        expect { adapter.execute("DELETE FROM users WHERE id = 1") }
          .to raise_error(RailsConsoleAi::SafetyError, /Database write blocked/)
      end

      it 'blocks DROP statements' do
        expect { adapter.execute("DROP TABLE users") }
          .to raise_error(RailsConsoleAi::SafetyError, /Database write blocked/)
      end

      it 'blocks TRUNCATE statements' do
        expect { adapter.execute("TRUNCATE TABLE users") }
          .to raise_error(RailsConsoleAi::SafetyError, /Database write blocked/)
      end

      it 'allows SELECT statements' do
        expect(adapter.execute("SELECT * FROM users")).to eq("SELECT * FROM users")
      end

      it 'allows SHOW statements' do
        expect(adapter.execute("SHOW TABLES")).to eq("SHOW TABLES")
      end

      it 'blocks exec_query with INSERT' do
        expect { adapter.exec_query("INSERT INTO users (name) VALUES ('test')") }
          .to raise_error(RailsConsoleAi::SafetyError, /Database write blocked/)
      end

      it 'allows exec_query with SELECT' do
        expect(adapter.exec_query("SELECT * FROM users")).to eq("SELECT * FROM users")
      end

      it 'blocks exec_insert' do
        expect { adapter.exec_insert("INSERT INTO users (name) VALUES ('test')") }
          .to raise_error(RailsConsoleAi::SafetyError, /Database write blocked/)
      end

      it 'blocks exec_delete' do
        expect { adapter.exec_delete("DELETE FROM users WHERE id = 1") }
          .to raise_error(RailsConsoleAi::SafetyError, /Database write blocked/)
      end

      it 'blocks exec_update' do
        expect { adapter.exec_update("UPDATE users SET name = 'test'") }
          .to raise_error(RailsConsoleAi::SafetyError, /Database write blocked/)
      end

      it 'includes guard and blocked_key in SafetyError' do
        error = nil
        begin
          adapter.execute("INSERT INTO users (name) VALUES ('test')")
        rescue RailsConsoleAi::SafetyError => e
          error = e
        end
        expect(error.guard).to eq(:database_writes)
        expect(error.blocked_key).to eq("users")
      end

      it 'allows writes to allowlisted tables' do
        RailsConsoleAi.configuration.safety_guards.allow(:database_writes, 'users')
        expect(adapter.execute("INSERT INTO users (name) VALUES ('test')"))
          .to eq("INSERT INTO users (name) VALUES ('test')")
      end
    end

    context 'when block_writes flag is not set' do
      before { Thread.current[:rails_console_ai_block_writes] = false }

      it 'allows all statements' do
        expect(adapter.execute("INSERT INTO users (name) VALUES ('test')"))
          .to eq("INSERT INTO users (name) VALUES ('test')")
        expect(adapter.execute("SELECT * FROM users"))
          .to eq("SELECT * FROM users")
      end
    end

    context 'when bypass_guards flag is set' do
      before do
        Thread.current[:rails_console_ai_block_writes]  = true
        Thread.current[:rails_console_ai_bypass_guards] = true
      end
      after { Thread.current[:rails_console_ai_bypass_guards] = nil }

      it 'allows writes even when block_writes is true' do
        expect(adapter.execute("INSERT INTO users (name) VALUES ('test')"))
          .to eq("INSERT INTO users (name) VALUES ('test')")
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
        flag_during = Thread.current[:rails_console_ai_block_http]
      end

      expect(flag_during).to eq(true)
      expect(Thread.current[:rails_console_ai_block_http]).to eq(false)
    end

    it 'clears the flag even on exception' do
      guard = described_class.http_mutations
      allow(described_class).to receive(:ensure_http_blocker_installed!)

      begin
        guard.call { raise "boom" }
      rescue
      end

      expect(Thread.current[:rails_console_ai_block_http]).to eq(false)
    end
  end

  describe RailsConsoleAi::BuiltinGuards::HttpBlocker do
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
      klass.prepend(RailsConsoleAi::BuiltinGuards::HttpBlocker)
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
      before { Thread.current[:rails_console_ai_block_http] = true }
      after  { Thread.current[:rails_console_ai_block_http] = false }

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
          .to raise_error(RailsConsoleAi::SafetyError, /HTTP POST blocked/)
      end

      it 'blocks PUT requests' do
        expect { http.request(put_req) }
          .to raise_error(RailsConsoleAi::SafetyError, /HTTP PUT blocked/)
      end

      it 'blocks PATCH requests' do
        expect { http.request(patch_req) }
          .to raise_error(RailsConsoleAi::SafetyError, /HTTP PATCH blocked/)
      end

      it 'blocks DELETE requests' do
        expect { http.request(delete_req) }
          .to raise_error(RailsConsoleAi::SafetyError, /HTTP DELETE blocked/)
      end

      it 'includes guard and blocked_key in SafetyError' do
        error = nil
        begin
          http.request(post_req)
        rescue RailsConsoleAi::SafetyError => e
          error = e
        end
        expect(error.guard).to eq(:http_mutations)
        expect(error.blocked_key).to eq("example.com")
      end

      it 'allows requests to allowlisted hosts' do
        RailsConsoleAi.configuration.safety_guards.allow(:http_mutations, "example.com")
        expect(http.request(post_req)).to eq("POST /users")
      end

      it 'allows requests matching allowlisted regexp' do
        RailsConsoleAi.configuration.safety_guards.allow(:http_mutations, /example\.com/)
        expect(http.request(put_req)).to eq("PUT /users/1")
      end
    end

    context 'when block_http flag is not set' do
      before { Thread.current[:rails_console_ai_block_http] = false }

      it 'allows all requests' do
        expect(http.request(post_req)).to eq('POST /users')
        expect(http.request(delete_req)).to eq('DELETE /users/1')
      end
    end

    context 'when bypass_guards flag is set' do
      before do
        Thread.current[:rails_console_ai_block_http]     = true
        Thread.current[:rails_console_ai_bypass_guards]  = true
      end
      after { Thread.current[:rails_console_ai_bypass_guards] = nil }

      it 'allows HTTP mutations even when block_http is true' do
        expect(http.request(post_req)).to eq('POST /users')
        expect(http.request(delete_req)).to eq('DELETE /users/1')
      end
    end
  end
end
