require 'spec_helper'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/providers/anthropic'
require 'rails_console_ai/providers/openai'
require 'rails_console_ai/providers/openrouter'

# Effort is sent in each provider's own shape, and only to model families that
# accept it. Bedrock's shape is covered in spec/providers/bedrock_spec.rb.
RSpec.describe 'effort' do
  let(:messages) { [{ role: :user, content: 'Hello' }] }

  describe RailsConsoleAi::Configuration do
    subject(:config) { described_class.new }

    it 'defaults to medium for the default tier and high for thinking' do
      expect(config.effort).to eq('medium')
      expect(config.thinking_effort).to eq('high')
    end

    it 'resolves effort for families that accept it' do
      %w[claude-opus-5-5 us.anthropic.claude-opus-5-5 anthropic/claude-opus-5.5 claude-sonnet-5].each do |model|
        config.model = model
        expect(config.resolved_effort).to eq('medium'), "expected effort for #{model}"
      end
    end

    it 'omits effort for haiku, unknown models, and when unset' do
      { 'claude-haiku-4-5' => 'medium', 'gpt-5.3-codex' => 'medium', 'qwen2.5:7b' => 'medium',
        'claude-opus-5-5' => nil }.each do |model, effort|
        config.model = model
        config.effort = effort
        expect(config.resolved_effort).to be_nil, "expected no effort for #{model}"
      end
    end

    it 'rejects an invalid effort level' do
      config.api_key = 'k'
      config.effort = 'turbo'
      expect { config.validate! }.to raise_error(RailsConsoleAi::ConfigurationError, /Invalid effort/)
      config.effort = 'low'
      config.thinking_effort = 'extreme'
      expect { config.validate! }.to raise_error(RailsConsoleAi::ConfigurationError, /Invalid thinking_effort/)
    end
  end

  describe RailsConsoleAi::Providers::Anthropic do
    let(:config) do
      RailsConsoleAi::Configuration.new.tap do |c|
        c.provider = :anthropic
        c.api_key = 'k'
        c.model = model
      end
    end
    let(:model) { 'claude-opus-5-5' }

    def sent_body
      body = nil
      stub_request(:post, 'https://api.anthropic.com/v1/messages')
        .with { |req| body = JSON.parse(req.body) }
        .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
          body: { content: [{ type: 'text', text: 'hi' }], usage: {}, stop_reason: 'end_turn' }.to_json)
      described_class.new(config).chat(messages)
      body
    end

    it 'sends output_config.effort' do
      expect(sent_body['output_config']).to eq('effort' => 'medium')
    end

    context 'with a model that takes no effort' do
      let(:model) { 'claude-haiku-4-5' }

      it 'omits output_config' do
        expect(sent_body).not_to have_key('output_config')
      end
    end
  end

  describe RailsConsoleAi::Providers::OpenRouter do
    let(:config) do
      RailsConsoleAi::Configuration.new.tap do |c|
        c.provider = :openrouter
        c.api_key = 'k'
        c.model = 'anthropic/claude-opus-5.5'
        c.effort = 'high'
      end
    end

    it 'sends effort as verbosity' do
      body = nil
      stub_request(:post, 'https://openrouter.ai/api/v1/chat/completions')
        .with { |req| body = JSON.parse(req.body) }
        .to_return(status: 200, headers: { 'Content-Type' => 'application/json' },
          body: { choices: [{ message: { content: 'hi' }, finish_reason: 'stop' }], usage: {} }.to_json)
      described_class.new(config).chat(messages)
      expect(body['verbosity']).to eq('high')
      expect(body).not_to have_key('reasoning')
    end
  end
end
