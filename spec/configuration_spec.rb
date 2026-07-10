require 'spec_helper'

RSpec.describe RailsConsoleAi::Configuration do
  subject(:config) { described_class.new }

  describe 'defaults' do
    it 'sets provider to :anthropic' do
      expect(config.provider).to eq(:anthropic)
    end

    it 'sets max_tokens to nil (auto-resolved per model)' do
      expect(config.max_tokens).to be_nil
    end

    it 'sets auto_execute to false' do
      expect(config.auto_execute).to eq(false)
    end

    it 'sets temperature to 0.2' do
      expect(config.temperature).to eq(0.2)
    end

    it 'sets timeout to 30' do
      expect(config.timeout).to eq(30)
    end

    it 'sets max_tool_rounds to 200' do
      expect(config.max_tool_rounds).to eq(200)
    end
  end

  describe 'PROVIDERS' do
    it 'includes :local' do
      expect(RailsConsoleAi::Configuration::PROVIDERS).to include(:local)
    end
  end

  describe '#resolved_api_key' do
    it 'returns api_key when set explicitly' do
      config.api_key = 'test-key'
      expect(config.resolved_api_key).to eq('test-key')
    end

    it 'falls back to ANTHROPIC_API_KEY for anthropic provider' do
      config.provider = :anthropic
      allow(ENV).to receive(:[]).with('ANTHROPIC_API_KEY').and_return('env-key')
      expect(config.resolved_api_key).to eq('env-key')
    end

    it 'falls back to OPENAI_API_KEY for openai provider' do
      config.provider = :openai
      allow(ENV).to receive(:[]).with('OPENAI_API_KEY').and_return('env-key')
      expect(config.resolved_api_key).to eq('env-key')
    end

    it 'returns nil when no key is available' do
      allow(ENV).to receive(:[]).and_return(nil)
      expect(config.resolved_api_key).to be_nil
    end

    it "returns 'no-key' for local provider without api key" do
      config.provider = :local
      expect(config.resolved_api_key).to eq('no-key')
    end

    it 'returns local_api_key when set for local provider' do
      config.provider = :local
      config.local_api_key = 'my-local-key'
      expect(config.resolved_api_key).to eq('my-local-key')
    end
  end

  describe '#resolved_model' do
    it 'returns explicit model when set' do
      config.model = 'custom-model'
      expect(config.resolved_model).to eq('custom-model')
    end

    it 'returns default model for anthropic' do
      config.provider = :anthropic
      expect(config.resolved_model).to eq('claude-sonnet-5')
    end

    it 'returns default model for bedrock' do
      config.provider = :bedrock
      expect(config.resolved_model).to eq('us.anthropic.claude-sonnet-5')
    end

    it 'returns default model for openai' do
      config.provider = :openai
      expect(config.resolved_model).to eq('gpt-5.3-codex')
    end

    it 'returns local_model for local provider' do
      config.provider = :local
      expect(config.resolved_model).to eq('qwen2.5:7b')
    end
  end

  describe '#resolved_thinking_model' do
    it 'returns default thinking model for anthropic' do
      config.provider = :anthropic
      expect(config.resolved_thinking_model).to eq('claude-opus-4-8')
    end

    it 'returns default thinking model for bedrock' do
      config.provider = :bedrock
      expect(config.resolved_thinking_model).to eq('us.anthropic.claude-opus-4-8')
    end
  end

  describe '.model_family' do
    it 'matches bare Anthropic model IDs' do
      expect(described_class.model_family('claude-sonnet-5')[:input]).to eq(3.0)
    end

    it 'matches Bedrock inference profile IDs' do
      expect(described_class.model_family('us.anthropic.claude-opus-4-8')[:input]).to eq(5.0)
      expect(described_class.model_family('global.anthropic.claude-sonnet-5')[:input]).to eq(3.0)
    end

    it 'matches dated snapshots and version suffixes' do
      expect(described_class.model_family('claude-haiku-4-5-20251001')[:input]).to eq(1.0)
      expect(described_class.model_family('us.anthropic.claude-opus-4-6-v1')[:input]).to eq(5.0)
    end

    it 'returns nil for unknown models' do
      expect(described_class.model_family('gpt-5.3-codex')).to be_nil
      expect(described_class.model_family(nil)).to be_nil
    end
  end

  describe '.pricing_for' do
    it 'returns per-token pricing with derived cache rates' do
      pricing = described_class.pricing_for('us.anthropic.claude-sonnet-5')
      expect(pricing[:input]).to eq(3.0 / 1_000_000)
      expect(pricing[:output]).to eq(15.0 / 1_000_000)
      expect(pricing[:cache_read]).to be_within(1e-12).of(0.30 / 1_000_000)
      expect(pricing[:cache_write]).to be_within(1e-12).of(3.75 / 1_000_000)
    end

    it 'prices opus 4.x at $5/$25 per MTok' do
      pricing = described_class.pricing_for('claude-opus-4-6')
      expect(pricing[:input]).to eq(5.0 / 1_000_000)
      expect(pricing[:output]).to eq(25.0 / 1_000_000)
    end

    it 'returns nil for unknown models' do
      expect(described_class.pricing_for('qwen2.5:7b')).to be_nil
    end
  end

  describe '#resolved_max_tokens' do
    it 'returns explicit max_tokens when set' do
      config.max_tokens = 1234
      expect(config.resolved_max_tokens).to eq(1234)
    end

    it 'resolves family default for Bedrock profile IDs' do
      config.provider = :bedrock
      config.model = 'us.anthropic.claude-sonnet-5'
      expect(config.resolved_max_tokens).to eq(16_000)
    end

    it 'falls back to 4096 for unknown models' do
      config.model = 'some-unknown-model'
      expect(config.resolved_max_tokens).to eq(4096)
    end
  end

  describe '#resolved_temperature' do
    it 'returns nil for families that reject temperature' do
      %w[
        claude-sonnet-5
        us.anthropic.claude-sonnet-5
        claude-opus-4-7
        us.anthropic.claude-opus-4-8
        claude-fable-5
      ].each do |model|
        config.model = model
        expect(config.resolved_temperature).to be_nil, "expected nil temperature for #{model}"
      end
    end

    it 'returns the configured temperature for families that accept it' do
      config.model = 'us.anthropic.claude-sonnet-4-6'
      expect(config.resolved_temperature).to eq(0.2)
    end

    it 'returns the configured temperature for unknown models' do
      config.model = 'qwen2.5:7b'
      expect(config.resolved_temperature).to eq(0.2)
    end
  end

  describe '#safety_guards' do
    it 'returns a SafetyGuards instance' do
      expect(config.safety_guards).to be_a(RailsConsoleAi::SafetyGuards)
    end

    it 'returns the same instance on repeated calls' do
      expect(config.safety_guards).to be(config.safety_guards)
    end
  end

  describe '#safety_guard' do
    it 'registers a custom guard' do
      config.safety_guard(:test) { |&b| b.call }
      expect(config.safety_guards.names).to include(:test)
    end
  end

  describe '#use_builtin_safety_guard' do
    it 'registers the database_writes guard' do
      config.use_builtin_safety_guard(:database_writes)
      expect(config.safety_guards.names).to include(:database_writes)
    end

    it 'registers the http_mutations guard' do
      config.use_builtin_safety_guard(:http_mutations)
      expect(config.safety_guards.names).to include(:http_mutations)
    end

    it 'registers the mailers guard' do
      config.use_builtin_safety_guard(:mailers)
      expect(config.safety_guards.names).to include(:mailers)
    end

    it 'raises for unknown built-in guards' do
      expect { config.use_builtin_safety_guard(:unknown) }
        .to raise_error(RailsConsoleAi::ConfigurationError, /Unknown built-in/)
    end

    it 'registers allowlist entries with allow: option' do
      config.use_builtin_safety_guard(:http_mutations, allow: [/s3\.amazonaws\.com/, "example.com"])
      expect(config.safety_guards.allowed?(:http_mutations, "s3.amazonaws.com")).to be true
      expect(config.safety_guards.allowed?(:http_mutations, "example.com")).to be true
      expect(config.safety_guards.allowed?(:http_mutations, "evil.com")).to be false
    end

    it 'accepts a single allow value (not array)' do
      config.use_builtin_safety_guard(:database_writes, allow: 'sessions')
      expect(config.safety_guards.allowed?(:database_writes, "sessions")).to be true
    end
  end

  describe '#validate!' do
    it 'raises for unknown provider' do
      config.provider = :unknown
      expect { config.validate! }.to raise_error(
        RailsConsoleAi::ConfigurationError, /Unknown provider/
      )
    end

    it 'raises when no API key is available' do
      allow(ENV).to receive(:[]).and_return(nil)
      expect { config.validate! }.to raise_error(
        RailsConsoleAi::ConfigurationError, /No API key/
      )
    end

    it 'does not raise when API key is set' do
      config.api_key = 'test-key'
      expect { config.validate! }.not_to raise_error
    end

    it 'passes for :local without API key' do
      config.provider = :local
      expect { config.validate! }.not_to raise_error
    end

    it 'raises for :local when local_url is empty' do
      config.provider = :local
      config.local_url = ''
      expect { config.validate! }.to raise_error(
        RailsConsoleAi::ConfigurationError, /local_url/
      )
    end
  end

  describe '#channel_setting' do
    it 'returns the value from channels hash' do
      config.channels = { 'slack' => { 'allowed_usernames' => ['alice'] } }
      expect(config.channel_setting('slack', 'allowed_usernames')).to eq(['alice'])
    end

    it 'falls back to slack_allowed_usernames for backward compat' do
      config.slack_allowed_usernames = ['bob']
      expect(config.channel_setting('slack', 'allowed_usernames')).to eq(['bob'])
    end

    it 'prefers channels hash over legacy setting' do
      config.slack_allowed_usernames = ['bob']
      config.channels = { 'slack' => { 'allowed_usernames' => ['alice'] } }
      expect(config.channel_setting('slack', 'allowed_usernames')).to eq(['alice'])
    end

    it 'returns nil for unconfigured settings' do
      expect(config.channel_setting('slack', 'allow_code_execution')).to be_nil
    end

    it 'returns nil for unconfigured channel' do
      expect(config.channel_setting('console', 'allowed_usernames')).to be_nil
    end
  end

  describe '#username_allowed?' do
    it 'returns true when setting is nil (not configured)' do
      expect(config.username_allowed?('slack', 'allow_code_execution', 'frank')).to be true
    end

    it 'returns true when list includes ALL' do
      config.channels = { 'slack' => { 'allow_code_execution' => 'ALL' } }
      expect(config.username_allowed?('slack', 'allow_code_execution', 'anyone')).to be true
    end

    it 'returns true when username is in the list' do
      config.channels = { 'slack' => { 'allow_code_execution' => ['frank'] } }
      expect(config.username_allowed?('slack', 'allow_code_execution', 'Frank')).to be true
    end

    it 'returns false when username is not in the list' do
      config.channels = { 'slack' => { 'allow_code_execution' => ['frank'] } }
      expect(config.username_allowed?('slack', 'allow_code_execution', 'alice')).to be false
    end

    it 'is case insensitive' do
      config.channels = { 'slack' => { 'allowed_usernames' => ['Frank'] } }
      expect(config.username_allowed?('slack', 'allowed_usernames', 'frank')).to be true
    end
  end
end
