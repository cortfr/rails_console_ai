require 'spec_helper'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/providers/anthropic'

RSpec.describe RailsConsoleAi::Providers::Anthropic do
  let(:config) do
    RailsConsoleAi::Configuration.new.tap do |c|
      c.provider = :anthropic
      c.api_key = 'test-anthropic-key'
      c.model = 'claude-test'
      c.max_tokens = 1024
      c.temperature = 0.5
    end
  end

  subject(:provider) { described_class.new(config) }

  describe '#chat' do
    let(:messages) { [{ role: :user, content: 'Hello' }] }

    it 'sends a request and returns a ChatResult with token usage' do
      stub_request(:post, 'https://api.anthropic.com/v1/messages')
        .with(
          headers: {
            'x-api-key' => 'test-anthropic-key',
            'anthropic-version' => '2023-06-01',
            'Content-Type' => 'application/json'
          }
        )
        .to_return(
          status: 200,
          body: {
            content: [{ type: 'text', text: 'Hello back!' }],
            usage: { input_tokens: 10, output_tokens: 5 },
            stop_reason: 'end_turn'
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = provider.chat(messages, system_prompt: 'Be helpful')
      expect(result.text).to eq('Hello back!')
      expect(result.input_tokens).to eq(10)
      expect(result.output_tokens).to eq(5)
      expect(result.stop_reason).to eq(:end_turn)
    end

    it 'raises ProviderError on API errors' do
      stub_request(:post, 'https://api.anthropic.com/v1/messages')
        .to_return(
          status: 401,
          body: { error: { message: 'Invalid API key' } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      expect { provider.chat(messages) }.to raise_error(
        RailsConsoleAi::Providers::ProviderError, /Invalid API key/
      )
    end
  end

  describe '#chat_with_tools' do
    let(:messages) { [{ role: :user, content: 'List tables' }] }
    let(:mock_tools) do
      tools = double('tools')
      allow(tools).to receive(:to_anthropic_format).and_return([
        { 'name' => 'list_tables', 'description' => 'List tables', 'input_schema' => { 'type' => 'object', 'properties' => {} } }
      ])
      tools
    end

    it 'includes tools in the request and parses tool_use response' do
      stub_request(:post, 'https://api.anthropic.com/v1/messages')
        .with { |req|
          body = JSON.parse(req.body)
          body['tools'] && body['tools'].length == 1
        }
        .to_return(
          status: 200,
          body: {
            content: [
              { type: 'text', text: 'Let me check.' },
              { type: 'tool_use', id: 'tool_123', name: 'list_tables', input: {} }
            ],
            usage: { input_tokens: 50, output_tokens: 20 },
            stop_reason: 'tool_use'
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = provider.chat_with_tools(messages, tools: mock_tools)
      expect(result.stop_reason).to eq(:tool_use)
      expect(result.tool_use?).to be true
      expect(result.tool_calls.length).to eq(1)
      expect(result.tool_calls[0][:name]).to eq('list_tables')
      expect(result.tool_calls[0][:id]).to eq('tool_123')
      expect(result.text).to eq('Let me check.')
    end

    it 'returns end_turn when no tools are called' do
      stub_request(:post, 'https://api.anthropic.com/v1/messages')
        .to_return(
          status: 200,
          body: {
            content: [{ type: 'text', text: 'Here is your answer.' }],
            usage: { input_tokens: 50, output_tokens: 30 },
            stop_reason: 'end_turn'
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = provider.chat_with_tools(messages, tools: mock_tools)
      expect(result.stop_reason).to eq(:end_turn)
      expect(result.tool_use?).to be false
      expect(result.text).to eq('Here is your answer.')
    end
  end

  describe '#format_assistant_message' do
    it 'builds an assistant message with tool calls' do
      result = RailsConsoleAi::Providers::ChatResult.new(
        text: 'Checking...',
        tool_calls: [{ id: 'tool_1', name: 'list_tables', arguments: {} }]
      )
      msg = provider.format_assistant_message(result)
      expect(msg[:role]).to eq('assistant')
      expect(msg[:content].length).to eq(2)
      expect(msg[:content][0]['type']).to eq('text')
      expect(msg[:content][1]['type']).to eq('tool_use')
    end
  end

  describe '#format_tool_result' do
    it 'builds a tool result message' do
      msg = provider.format_tool_result('tool_1', 'users, posts')
      expect(msg[:role]).to eq('user')
      expect(msg[:content][0]['type']).to eq('tool_result')
      expect(msg[:content][0]['tool_use_id']).to eq('tool_1')
      expect(msg[:content][0]['content']).to eq('users, posts')
    end
  end
end
