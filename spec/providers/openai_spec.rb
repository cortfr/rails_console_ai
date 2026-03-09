require 'spec_helper'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/providers/openai'

RSpec.describe RailsConsoleAi::Providers::OpenAI do
  let(:config) do
    RailsConsoleAi::Configuration.new.tap do |c|
      c.provider = :openai
      c.api_key = 'test-openai-key'
      c.model = 'gpt-test'
      c.max_tokens = 1024
      c.temperature = 0.5
    end
  end

  subject(:provider) { described_class.new(config) }

  describe '#chat' do
    let(:messages) { [{ role: :user, content: 'Hello' }] }

    it 'sends a request and returns a ChatResult with token usage' do
      stub_request(:post, 'https://api.openai.com/v1/chat/completions')
        .with(
          headers: {
            'Authorization' => 'Bearer test-openai-key',
            'Content-Type' => 'application/json'
          }
        )
        .to_return(
          status: 200,
          body: {
            choices: [{ message: { content: 'Hello back!' }, finish_reason: 'stop' }],
            usage: { prompt_tokens: 20, completion_tokens: 8, total_tokens: 28 }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = provider.chat(messages, system_prompt: 'Be helpful')
      expect(result.text).to eq('Hello back!')
      expect(result.input_tokens).to eq(20)
      expect(result.output_tokens).to eq(8)
      expect(result.stop_reason).to eq(:end_turn)
    end

    it 'raises ProviderError on API errors' do
      stub_request(:post, 'https://api.openai.com/v1/chat/completions')
        .to_return(
          status: 429,
          body: { error: { message: 'Rate limit exceeded' } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      expect { provider.chat(messages) }.to raise_error(
        RailsConsoleAi::Providers::ProviderError, /Rate limit exceeded/
      )
    end
  end

  describe '#chat_with_tools' do
    let(:messages) { [{ role: :user, content: 'List tables' }] }
    let(:mock_tools) do
      tools = double('tools')
      allow(tools).to receive(:to_openai_format).and_return([
        { 'type' => 'function', 'function' => { 'name' => 'list_tables', 'description' => 'List tables', 'parameters' => { 'type' => 'object', 'properties' => {} } } }
      ])
      tools
    end

    it 'includes tools in the request and parses tool_calls response' do
      stub_request(:post, 'https://api.openai.com/v1/chat/completions')
        .with { |req|
          body = JSON.parse(req.body)
          body['tools'] && body['tools'].length == 1
        }
        .to_return(
          status: 200,
          body: {
            choices: [{
              message: {
                content: 'Let me check.',
                tool_calls: [{
                  id: 'call_123',
                  type: 'function',
                  function: { name: 'list_tables', arguments: '{}' }
                }]
              },
              finish_reason: 'tool_calls'
            }],
            usage: { prompt_tokens: 50, completion_tokens: 20 }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = provider.chat_with_tools(messages, tools: mock_tools)
      expect(result.stop_reason).to eq(:tool_use)
      expect(result.tool_use?).to be true
      expect(result.tool_calls.length).to eq(1)
      expect(result.tool_calls[0][:name]).to eq('list_tables')
      expect(result.tool_calls[0][:id]).to eq('call_123')
    end

    it 'returns end_turn when no tools are called' do
      stub_request(:post, 'https://api.openai.com/v1/chat/completions')
        .to_return(
          status: 200,
          body: {
            choices: [{ message: { content: 'Here is your answer.' }, finish_reason: 'stop' }],
            usage: { prompt_tokens: 50, completion_tokens: 30 }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = provider.chat_with_tools(messages, tools: mock_tools)
      expect(result.stop_reason).to eq(:end_turn)
      expect(result.tool_use?).to be false
    end
  end

  describe '#format_assistant_message' do
    it 'builds an assistant message with tool_calls' do
      result = RailsConsoleAi::Providers::ChatResult.new(
        text: 'Checking...',
        tool_calls: [{ id: 'call_1', name: 'list_tables', arguments: {} }]
      )
      msg = provider.format_assistant_message(result)
      expect(msg[:role]).to eq('assistant')
      expect(msg[:content]).to eq('Checking...')
      expect(msg[:tool_calls].length).to eq(1)
      expect(msg[:tool_calls][0]['function']['name']).to eq('list_tables')
    end
  end

  describe '#format_tool_result' do
    it 'builds a tool result message' do
      msg = provider.format_tool_result('call_1', 'users, posts')
      expect(msg[:role]).to eq('tool')
      expect(msg[:tool_call_id]).to eq('call_1')
      expect(msg[:content]).to eq('users, posts')
    end
  end
end
