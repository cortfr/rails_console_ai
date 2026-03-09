require 'spec_helper'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/providers/openai'
require 'rails_console_ai/providers/local'

RSpec.describe RailsConsoleAi::Providers::Local do
  let(:config) do
    RailsConsoleAi::Configuration.new.tap do |c|
      c.provider = :local
      c.local_url = 'http://localhost:11434'
      c.local_model = 'qwen2.5:7b'
      c.local_api_key = nil
      c.max_tokens = 1024
      c.temperature = 0.5
    end
  end

  subject(:provider) { described_class.new(config) }

  it 'inherits from OpenAI' do
    expect(described_class).to be < RailsConsoleAi::Providers::OpenAI
  end

  describe '#chat' do
    let(:messages) { [{ role: :user, content: 'Hello' }] }

    it 'sends requests to local_url without auth header when no api key' do
      stub_request(:post, 'http://localhost:11434/v1/chat/completions')
        .with { |req| !req.headers.key?('Authorization') }
        .to_return(
          status: 200,
          body: {
            choices: [{ message: { content: 'Hi!' }, finish_reason: 'stop' }],
            usage: { prompt_tokens: 10, completion_tokens: 5 }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = provider.chat(messages)
      expect(result.text).to eq('Hi!')
      expect(result.input_tokens).to eq(10)
      expect(result.output_tokens).to eq(5)
      expect(result.stop_reason).to eq(:end_turn)
    end

    it 'includes auth header when local_api_key is set' do
      config.local_api_key = 'local-secret'

      stub_request(:post, 'http://localhost:11434/v1/chat/completions')
        .with(headers: { 'Authorization' => 'Bearer local-secret' })
        .to_return(
          status: 200,
          body: {
            choices: [{ message: { content: 'Hi!' }, finish_reason: 'stop' }],
            usage: { prompt_tokens: 10, completion_tokens: 5 }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = provider.chat(messages)
      expect(result.text).to eq('Hi!')
    end

    it 'uses local_model in request body' do
      stub_request(:post, 'http://localhost:11434/v1/chat/completions')
        .with { |req|
          body = JSON.parse(req.body)
          body['model'] == 'qwen2.5:7b'
        }
        .to_return(
          status: 200,
          body: {
            choices: [{ message: { content: 'Hi!' }, finish_reason: 'stop' }],
            usage: { prompt_tokens: 10, completion_tokens: 5 }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      provider.chat(messages)
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

    it 'parses tool calls correctly (inherited behavior)' do
      stub_request(:post, 'http://localhost:11434/v1/chat/completions')
        .to_return(
          status: 200,
          body: {
            choices: [{
              message: {
                content: 'Let me check.',
                tool_calls: [{
                  id: 'call_abc',
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
      expect(result.tool_calls[0][:id]).to eq('call_abc')
    end
  end

  describe 'text-based tool call fallback' do
    let(:messages) { [{ role: :user, content: 'Count users' }] }
    let(:mock_tools) do
      tools = double('tools')
      allow(tools).to receive(:to_openai_format).and_return([
        { 'type' => 'function', 'function' => { 'name' => 'execute_plan', 'description' => 'Run a plan', 'parameters' => { 'type' => 'object', 'properties' => {} } } },
        { 'type' => 'function', 'function' => { 'name' => 'list_tables', 'description' => 'List tables', 'parameters' => { 'type' => 'object', 'properties' => {} } } }
      ])
      tools
    end

    it 'parses tool calls from content when model emits JSON text' do
      stub_request(:post, 'http://localhost:11434/v1/chat/completions')
        .to_return(
          status: 200,
          body: {
            choices: [{
              message: { content: '{"name":"execute_plan","arguments":{"steps":[{"description":"Count users","code":"User.count"}]}}' },
              finish_reason: 'stop'
            }],
            usage: { prompt_tokens: 50, completion_tokens: 20 }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = provider.chat_with_tools(messages, tools: mock_tools)
      expect(result.stop_reason).to eq(:tool_use)
      expect(result.tool_use?).to be true
      expect(result.tool_calls.length).to eq(1)
      expect(result.tool_calls[0][:name]).to eq('execute_plan')
      expect(result.text).to eq('')
    end

    it 'ignores JSON content when name does not match a known tool' do
      stub_request(:post, 'http://localhost:11434/v1/chat/completions')
        .to_return(
          status: 200,
          body: {
            choices: [{
              message: { content: '{"name":"Frank","age":42}' },
              finish_reason: 'stop'
            }],
            usage: { prompt_tokens: 50, completion_tokens: 20 }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = provider.chat_with_tools(messages, tools: mock_tools)
      expect(result.stop_reason).to eq(:end_turn)
      expect(result.tool_use?).to be false
      expect(result.text).to eq('{"name":"Frank","age":42}')
    end

    it 'parses tool calls from markdown code blocks' do
      stub_request(:post, 'http://localhost:11434/v1/chat/completions')
        .to_return(
          status: 200,
          body: {
            choices: [{
              message: { content: "```json\n{\"name\":\"list_tables\",\"arguments\":{}}\n```" },
              finish_reason: 'stop'
            }],
            usage: { prompt_tokens: 50, completion_tokens: 20 }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = provider.chat_with_tools(messages, tools: mock_tools)
      expect(result.stop_reason).to eq(:tool_use)
      expect(result.tool_calls[0][:name]).to eq('list_tables')
    end

    it 'does not attempt text fallback when no tools are provided' do
      stub_request(:post, 'http://localhost:11434/v1/chat/completions')
        .to_return(
          status: 200,
          body: {
            choices: [{
              message: { content: '{"name":"execute_plan","arguments":{}}' },
              finish_reason: 'stop'
            }],
            usage: { prompt_tokens: 50, completion_tokens: 20 }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = provider.chat(messages)
      expect(result.stop_reason).to eq(:end_turn)
      expect(result.text).to eq('{"name":"execute_plan","arguments":{}}')
    end
  end

  describe '#format_assistant_message' do
    it 'delegates to OpenAI implementation' do
      result = RailsConsoleAi::Providers::ChatResult.new(
        text: 'Checking...',
        tool_calls: [{ id: 'call_1', name: 'list_tables', arguments: {} }]
      )
      msg = provider.format_assistant_message(result)
      expect(msg[:role]).to eq('assistant')
      expect(msg[:tool_calls].length).to eq(1)
    end
  end

  describe '#format_tool_result' do
    it 'delegates to OpenAI implementation' do
      msg = provider.format_tool_result('call_1', 'users, posts')
      expect(msg[:role]).to eq('tool')
      expect(msg[:tool_call_id]).to eq('call_1')
    end
  end
end
