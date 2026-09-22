require 'spec_helper'
require 'rails_console_ai/executor'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/conversation_engine'

RSpec.describe RailsConsoleAi::ConversationEngine, 'model tiers' do
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

  describe 'default tier' do
    it 'runs opus 5.5 at medium effort' do
      expect(engine.model_tier).to eq(:default)
      expect(engine.effective_model).to eq('claude-opus-5-5')
      expect(engine.effective_effort).to eq('medium')
      expect(engine.effective_model_label).to eq('claude-opus-5-5 (medium effort)')
    end

    it 'builds the provider from the global config' do
      expect(engine.send(:provider).config).to equal(RailsConsoleAi.configuration)
    end
  end

  describe '#upgrade_to_thinking_model' do
    it 'keeps opus 5.5 but raises effort to high' do
      result = suppress_output { engine.upgrade_to_thinking_model }
      expect(result).to eq('claude-opus-5-5')
      expect(engine.model_tier).to eq(:thinking)
      expect(engine.effective_effort).to eq('high')
    end

    it 'switches even though the thinking model matches the default model' do
      output = capture_output { engine.upgrade_to_thinking_model }
      expect(output).to include('Switched to thinking model: claude-opus-5-5 (high effort)')
    end

    it 'says so when already on the thinking tier' do
      suppress_output { engine.upgrade_to_thinking_model }
      output = capture_output { engine.upgrade_to_thinking_model }
      expect(output).to include('Already using thinking model')
    end

    it 'sends high effort through a provider config copy, leaving the global untouched' do
      suppress_output { engine.upgrade_to_thinking_model }
      provider = engine.send(:provider)
      expect(provider.config).not_to equal(RailsConsoleAi.configuration)
      expect(provider.config.resolved_model).to eq('claude-opus-5-5')
      expect(provider.config.resolved_effort).to eq('high')
      expect(RailsConsoleAi.configuration.resolved_effort).to eq('medium')
    end

    it 'honors a configured thinking_model and thinking_effort' do
      RailsConsoleAi.configuration.thinking_model = 'claude-opus-5'
      RailsConsoleAi.configuration.thinking_effort = 'xhigh'
      suppress_output { engine.upgrade_to_thinking_model }
      expect(engine.effective_model_label).to eq('claude-opus-5 (xhigh effort)')
    end

    it 'is scoped to the engine instance' do
      engine2 = described_class.new(binding_context: test_binding, channel: channel)
      suppress_output { engine.upgrade_to_thinking_model }
      expect(engine.model_tier).to eq(:thinking)
      expect(engine2.model_tier).to eq(:default)
    end
  end

  describe '#switch_to_cheap_model' do
    it 'runs sonnet 5 with no effort sent' do
      result = suppress_output { engine.switch_to_cheap_model }
      expect(result).to eq('claude-sonnet-5')
      expect(engine.effective_effort).to be_nil
      expect(engine.send(:provider).config.resolved_effort).to be_nil
    end

    it 'honors a configured cheap_model' do
      RailsConsoleAi.configuration.cheap_model = 'claude-haiku-4-5'
      suppress_output { engine.switch_to_cheap_model }
      expect(engine.effective_model).to eq('claude-haiku-4-5')
    end
  end

  describe '#downgrade_from_thinking_model' do
    it 'returns to the default tier from thinking or cheap' do
      %i[upgrade_to_thinking_model switch_to_cheap_model].each do |switch|
        suppress_output { engine.public_send(switch) }
        result = suppress_output { engine.downgrade_from_thinking_model }
        expect(result).to eq('claude-opus-5-5')
        expect(engine.model_tier).to eq(:default)
        expect(engine.effective_effort).to eq('medium')
      end
    end

    it 'resets the provider' do
      suppress_output { engine.upgrade_to_thinking_model }
      provider_after_think = engine.send(:provider)
      suppress_output { engine.downgrade_from_thinking_model }
      expect(engine.send(:provider)).not_to equal(provider_after_think)
    end
  end

  describe '#switch_model_tier' do
    it 'rejects unknown tiers' do
      expect { engine.switch_model_tier(:turbo) }.to raise_error(ArgumentError, /turbo/)
    end
  end

  describe '#maybe_auto_upgrade_thinking' do
    it 'upgrades on "think harder" and its variants' do
      ['please think harder about this', 'think deeper here', 'think carefully'].each do |text|
        e = described_class.new(binding_context: test_binding, channel: channel)
        suppress_output { e.maybe_auto_upgrade_thinking(text) }
        expect(e.model_tier).to eq(:thinking), "expected #{text.inspect} to upgrade"
      end
    end

    it 'does not upgrade for ordinary messages or non-strings' do
      suppress_output { engine.maybe_auto_upgrade_thinking('what do you think about this query?') }
      expect { engine.maybe_auto_upgrade_thinking(nil) }.not_to raise_error
      expect(engine.model_tier).to eq(:default)
    end
  end

  describe '#track_usage' do
    let(:result) do
      double('result', input_tokens: 100, output_tokens: 50,
        cache_read_input_tokens: 0, cache_write_input_tokens: 0, cost: nil)
    end

    it 'attributes tokens to the effective model' do
      suppress_output { engine.switch_to_cheap_model }
      engine.send(:track_usage, result)

      usage = engine.instance_variable_get(:@token_usage)
      expect(usage['claude-sonnet-5'][:input]).to eq(100)
      expect(usage['claude-sonnet-5'][:output]).to eq(50)
      expect(usage.key?('claude-opus-5-5')).to be false
    end
  end

  private

  def capture_output
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old_stdout
  end

  def suppress_output(&block)
    old_stdout = $stdout
    $stdout = StringIO.new
    block.call
  ensure
    $stdout = old_stdout
  end
end
