require 'spec_helper'
require 'rails_console_ai/executor'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/conversation_engine'

RSpec.describe RailsConsoleAi::ConversationEngine, 'model override' do
  let(:channel) { double('channel', mode: 'console', user_identity: 'test', system_instructions: nil) }
  let(:test_binding) { binding }

  subject(:engine) { described_class.new(binding_context: test_binding, channel: channel) }

  before do
    RailsConsoleAi.configure do |c|
      c.provider = :anthropic
      c.model = nil
      c.thinking_model = nil
      c.api_key = 'test-key'
    end
  end

  describe '#effective_model' do
    it 'returns the global resolved model by default' do
      expect(engine.effective_model).to eq('claude-sonnet-4-6')
    end

    it 'returns the override after upgrade_to_thinking_model' do
      suppress_output { engine.upgrade_to_thinking_model }
      expect(engine.effective_model).to eq('claude-opus-4-6')
    end

    it 'returns the default after downgrade_from_thinking_model' do
      suppress_output { engine.upgrade_to_thinking_model }
      suppress_output { engine.downgrade_from_thinking_model }
      expect(engine.effective_model).to eq('claude-sonnet-4-6')
    end
  end

  describe '#upgrade_to_thinking_model' do
    it 'does not mutate the global configuration' do
      suppress_output { engine.upgrade_to_thinking_model }
      expect(RailsConsoleAi.configuration.resolved_model).to eq('claude-sonnet-4-6')
    end

    it 'returns the thinking model' do
      result = suppress_output { engine.upgrade_to_thinking_model }
      expect(result).to eq('claude-opus-4-6')
    end

    it 'is scoped to the engine instance' do
      engine2 = described_class.new(binding_context: test_binding, channel: channel)

      suppress_output { engine.upgrade_to_thinking_model }

      expect(engine.effective_model).to eq('claude-opus-4-6')
      expect(engine2.effective_model).to eq('claude-sonnet-4-6')
    end
  end

  describe '#downgrade_from_thinking_model' do
    it 'returns the default model' do
      suppress_output { engine.upgrade_to_thinking_model }
      result = suppress_output { engine.downgrade_from_thinking_model }
      expect(result).to eq('claude-sonnet-4-6')
    end

    it 'resets the provider' do
      suppress_output { engine.upgrade_to_thinking_model }
      provider_after_think = engine.send(:provider)

      suppress_output { engine.downgrade_from_thinking_model }
      provider_after_unthink = engine.send(:provider)

      expect(provider_after_unthink).not_to equal(provider_after_think)
    end
  end

  describe '#provider' do
    it 'uses the global config model by default' do
      provider = engine.send(:provider)
      expect(provider.config.resolved_model).to eq('claude-sonnet-4-6')
    end

    it 'uses the overridden model after upgrade' do
      suppress_output { engine.upgrade_to_thinking_model }
      provider = engine.send(:provider)
      expect(provider.config.resolved_model).to eq('claude-opus-4-6')
    end

    it 'does not share config with the global singleton after upgrade' do
      suppress_output { engine.upgrade_to_thinking_model }
      provider = engine.send(:provider)
      expect(provider.config).not_to equal(RailsConsoleAi.configuration)
    end
  end

  describe '#track_usage' do
    let(:result) do
      double('result',
        input_tokens: 100,
        output_tokens: 50,
        cache_read_input_tokens: 0,
        cache_write_input_tokens: 0)
    end

    it 'attributes tokens to the effective model' do
      suppress_output { engine.upgrade_to_thinking_model }
      engine.send(:track_usage, result)

      usage = engine.instance_variable_get(:@token_usage)
      expect(usage['claude-opus-4-6'][:input]).to eq(100)
      expect(usage['claude-opus-4-6'][:output]).to eq(50)
      expect(usage.key?('claude-sonnet-4-6')).to be false
    end
  end

  private

  def suppress_output
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = old_stdout
  end
end
