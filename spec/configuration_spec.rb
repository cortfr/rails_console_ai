require 'spec_helper'

RSpec.describe ConsoleAgent::Configuration do
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
  end

  describe '#resolved_model' do
    it 'returns explicit model when set' do
      config.model = 'custom-model'
      expect(config.resolved_model).to eq('custom-model')
    end

    it 'returns default model for anthropic' do
      config.provider = :anthropic
      expect(config.resolved_model).to eq('claude-sonnet-4-6')
    end

    it 'returns default model for openai' do
      config.provider = :openai
      expect(config.resolved_model).to eq('gpt-5.3-codex')
    end
  end

  describe '#safety_guards' do
    it 'returns a SafetyGuards instance' do
      expect(config.safety_guards).to be_a(ConsoleAgent::SafetyGuards)
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
        .to raise_error(ConsoleAgent::ConfigurationError, /Unknown built-in/)
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
        ConsoleAgent::ConfigurationError, /Unknown provider/
      )
    end

    it 'raises when no API key is available' do
      allow(ENV).to receive(:[]).and_return(nil)
      expect { config.validate! }.to raise_error(
        ConsoleAgent::ConfigurationError, /No API key/
      )
    end

    it 'does not raise when API key is set' do
      config.api_key = 'test-key'
      expect { config.validate! }.not_to raise_error
    end
  end
end
