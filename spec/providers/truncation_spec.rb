require 'spec_helper'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/providers/anthropic'
require 'rails_console_ai/providers/openai'
require 'rails_console_ai/providers/openrouter'
require 'rails_console_ai/providers/local'
require 'rails_console_ai/providers/bedrock'

# Same shim spec/providers/bedrock_spec.rb installs, so this file also runs alone.
unless defined?(Aws::BedrockRuntime::Client)
  module Aws
    module BedrockRuntime
      module Errors
        class ServiceError < StandardError; end
      end
      class Client
        def initialize(opts = {}); end
        def converse(params); end
      end
    end
  end
end

# A response cut off at the output cap has to arrive as its own stop reason.
# Folded into :end_turn — which is what every provider used to do — it is
# indistinguishable from a finished answer, the half-written tool call in it is
# silently dropped, and the model retries the same oversized call forever.
RSpec.describe 'truncated responses' do
  let(:mock_tools) do
    tools = double('tools')
    allow(tools).to receive(:to_openai_format).and_return([
      { 'type' => 'function', 'function' => { 'name' => 'save_artifact', 'parameters' => { 'type' => 'object', 'properties' => {} } } }
    ])
    allow(tools).to receive(:to_anthropic_format).and_return([
      { 'name' => 'save_artifact', 'description' => 'save', 'input_schema' => { 'type' => 'object', 'properties' => {} } }
    ])
    allow(tools).to receive(:to_bedrock_format).and_return([
      { tool_spec: { name: 'save_artifact', description: 'save', input_schema: { json: { 'type' => 'object' } } } }
    ])
    tools
  end

  let(:messages) { [{ role: :user, content: 'Save that file as an artifact' }] }

  describe RailsConsoleAi::Providers::Anthropic do
    subject(:provider) do
      described_class.new(RailsConsoleAi::Configuration.new.tap { |c|
        c.provider = :anthropic
        c.api_key = 'test-key'
        c.model = 'claude-sonnet-5'
        c.max_retries = 0
      })
    end

    it 'reports max_tokens as truncation, not as a finished turn' do
      stub_request(:post, 'https://api.anthropic.com/v1/messages')
        .to_return(
          status: 200,
          body: {
            content: [{ type: 'text', text: 'Now saving the artifact.' }],
            stop_reason: 'max_tokens',
            usage: { input_tokens: 100, output_tokens: 16_000 }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = provider.chat_with_tools(messages, tools: mock_tools)
      expect(result.stop_reason).to eq(:max_tokens)
      expect(result.truncated?).to be true
      expect(result.tool_use?).to be false
    end

    it 'still reports a real end_turn as :end_turn' do
      stub_request(:post, 'https://api.anthropic.com/v1/messages')
        .to_return(
          status: 200,
          body: {
            content: [{ type: 'text', text: 'Done.' }],
            stop_reason: 'end_turn',
            usage: { input_tokens: 100, output_tokens: 10 }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = provider.chat_with_tools(messages, tools: mock_tools)
      expect(result.stop_reason).to eq(:end_turn)
      expect(result.truncated?).to be false
    end
  end

  describe RailsConsoleAi::Providers::OpenAI do
    subject(:provider) do
      described_class.new(RailsConsoleAi::Configuration.new.tap { |c|
        c.provider = :openai
        c.api_key = 'test-key'
        c.model = 'gpt-test'
        c.max_retries = 0
      })
    end

    it "maps OpenAI's 'length' finish reason to truncation" do
      stub_request(:post, 'https://api.openai.com/v1/chat/completions')
        .to_return(
          status: 200,
          body: {
            choices: [{ message: { content: 'Now saving' }, finish_reason: 'length' }],
            usage: { prompt_tokens: 100, completion_tokens: 1024 }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = provider.chat_with_tools(messages, tools: mock_tools)
      expect(result.truncated?).to be true
      expect(result.tool_use?).to be false
    end
  end

  describe RailsConsoleAi::Providers::Local do
    subject(:provider) do
      described_class.new(RailsConsoleAi::Configuration.new.tap { |c|
        c.provider = :local
        c.local_url = 'http://localhost:11434'
        c.local_model = 'qwen2.5:7b'
      })
    end

    it "maps the local server's 'length' finish reason to truncation" do
      stub_request(:post, 'http://localhost:11434/v1/chat/completions')
        .to_return(
          status: 200,
          body: {
            choices: [{ message: { content: 'Now saving' }, finish_reason: 'length' }],
            usage: { prompt_tokens: 100, completion_tokens: 1024 }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = provider.chat_with_tools(messages, tools: mock_tools)
      expect(result.truncated?).to be true
    end
  end

  describe RailsConsoleAi::Providers::OpenRouter do
    subject(:provider) do
      described_class.new(RailsConsoleAi::Configuration.new.tap { |c|
        c.provider = :openrouter
        c.api_key = 'test-key'
        c.model = 'anthropic/claude-sonnet-5'
        c.max_retries = 0
      })
    end

    # OpenRouter promotes a response carrying tool calls to :tool_use even when
    # the upstream labelled it "stop". A truncated response also carries tool
    # calls — half-written ones — and must not be promoted with them.
    it 'does not promote a truncated response with a partial tool call to :tool_use' do
      stub_request(:post, 'https://openrouter.ai/api/v1/chat/completions')
        .to_return(
          status: 200,
          body: {
            choices: [{
              message: {
                content: 'Now saving',
                tool_calls: [{ id: 'call_1', type: 'function',
                               function: { name: 'save_artifact', arguments: '{"content": "<!DOCTYPE' } }]
              },
              finish_reason: 'length'
            }],
            usage: { prompt_tokens: 100, completion_tokens: 4096 }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = provider.chat_with_tools(messages, tools: mock_tools)
      expect(result.truncated?).to be true
      expect(result.tool_use?).to be false
    end
  end

  describe RailsConsoleAi::Providers::Bedrock do
    subject(:provider) do
      described_class.new(RailsConsoleAi::Configuration.new.tap { |c|
        c.provider = :bedrock
        c.model = 'us.anthropic.claude-sonnet-5'
        c.bedrock_region = 'us-east-1'
      })
    end

    let(:mock_client) { instance_double(Aws::BedrockRuntime::Client) }

    before { allow(Aws::BedrockRuntime::Client).to receive(:new).and_return(mock_client) }

    it 'reports max_tokens as truncation, not as a finished turn' do
      block = double('text_block', text: 'Now saving the artifact.', tool_use: nil)
      allow(block).to receive(:respond_to?).with(:text).and_return(true)
      allow(block).to receive(:respond_to?).with(:tool_use).and_return(false)
      response = double('response',
                        output: double('output', message: double('message', content: [block])),
                        usage: double('usage', input_tokens: 100, output_tokens: 16_000),
                        stop_reason: 'max_tokens')
      allow(mock_client).to receive(:converse).and_return(response)

      result = provider.chat_with_tools(messages, tools: mock_tools)
      expect(result.stop_reason).to eq(:max_tokens)
      expect(result.truncated?).to be true
      expect(result.tool_use?).to be false
    end
  end
end
