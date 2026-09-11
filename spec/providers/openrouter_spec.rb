require 'spec_helper'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/providers/openai'
require 'rails_console_ai/providers/openrouter'

RSpec.describe RailsConsoleAi::Providers::OpenRouter do
  let(:config) do
    RailsConsoleAi::Configuration.new.tap do |c|
      c.provider = :openrouter
      c.api_key = 'test-openrouter-key'
      c.model = 'anthropic/claude-sonnet-5'
      c.max_tokens = 4096
      c.temperature = 0.5
      # These examples assert how errors surface, not how they are retried. Left at
      # the default, the 429 case below would wait out real backoff between three
      # attempts. Retry behaviour has its own spec: spec/provider_retries_spec.rb.
      c.max_retries = 0
    end
  end

  subject(:provider) { described_class.new(config) }

  describe '#chat' do
    let(:messages) { [{ role: :user, content: 'Hello' }] }

    it 'sends a request to OpenRouter and returns a ChatResult with token usage' do
      stub_request(:post, 'https://openrouter.ai/api/v1/chat/completions')
        .with(
          headers: {
            'Authorization' => 'Bearer test-openrouter-key',
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

    it 'maps prompt_tokens_details to cache fields' do
      stub_request(:post, 'https://openrouter.ai/api/v1/chat/completions')
        .to_return(
          status: 200,
          body: {
            choices: [{ message: { content: 'Cached!' }, finish_reason: 'stop' }],
            usage: {
              prompt_tokens: 100,
              completion_tokens: 10,
              cost: 0.0023,
              prompt_tokens_details: {
                cached_tokens: 80,
                cache_write_tokens: 20
              }
            }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = provider.chat(messages)
      expect(result.cache_read_input_tokens).to eq(80)
      expect(result.cache_write_input_tokens).to eq(20)
      expect(result.cost).to eq(0.0023)
    end

    # usage.cost is the whole point of preferring OpenRouter's reported dollars
    # over an estimate, and it is omitted unless the request opts in.
    it 'asks for cost in the usage block' do
      stub_request(:post, 'https://openrouter.ai/api/v1/chat/completions')
        .with { |req| JSON.parse(req.body).dig('usage', 'include') == true }
        .to_return(
          status: 200,
          body: { choices: [{ message: { content: 'ok' }, finish_reason: 'stop' }],
                  usage: { prompt_tokens: 10, completion_tokens: 5, cost: 0.0007 } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      expect(provider.chat(messages).cost).to eq(0.0007)
    end

    # The engine reconstructs total prompt volume as input + cache_read +
    # cache_write (Anthropic's contract). OpenRouter's prompt_tokens already
    # includes both cache buckets, so it has to be reduced to the remainder.
    it 'reports input_tokens as the uncached remainder' do
      stub_request(:post, 'https://openrouter.ai/api/v1/chat/completions')
        .to_return(
          status: 200,
          body: { choices: [{ message: { content: 'ok' }, finish_reason: 'stop' }],
                  usage: { prompt_tokens: 9634, completion_tokens: 5,
                           prompt_tokens_details: { cached_tokens: 9632 } } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = provider.chat(messages)
      expect(result.input_tokens).to eq(2)
      expect(result.input_tokens + result.cache_read_input_tokens).to eq(9634)
    end

    it 'sends cache_control for Anthropic models' do
      stub_request(:post, 'https://openrouter.ai/api/v1/chat/completions')
        .with { |req|
          body = JSON.parse(req.body)
          body['cache_control'] && body['cache_control']['type'] == 'ephemeral'
        }
        .to_return(
          status: 200,
          body: {
            choices: [{ message: { content: 'ok' }, finish_reason: 'stop' }],
            usage: { prompt_tokens: 10, completion_tokens: 5 }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      provider.chat(messages)
    end

    it 'gives the static system prefix its own explicit breakpoint' do
      captured = nil
      stub_request(:post, 'https://openrouter.ai/api/v1/chat/completions')
        .to_return do |req|
          captured = JSON.parse(req.body)
          { status: 200,
            body: { choices: [{ message: { content: 'ok' }, finish_reason: 'stop' }],
                    usage: { prompt_tokens: 10, completion_tokens: 5 } }.to_json,
            headers: { 'Content-Type' => 'application/json' } }
        end

      provider.chat(messages, system_prompt: 'a stable system prompt')

      # Root-level cache_control handles the growing tail; the system prompt needs
      # its own marker so the expensive static prefix has a guaranteed read point.
      system_msg = captured['messages'].first
      expect(system_msg['role']).to eq('system')
      expect(system_msg['content']).to eq(
        [{ 'type' => 'text', 'text' => 'a stable system prompt',
           'cache_control' => { 'type' => 'ephemeral' } }]
      )
    end

    it 'carries the configured 1-hour TTL on every breakpoint' do
      config.cache_ttl = '1h'
      captured = nil
      stub_request(:post, 'https://openrouter.ai/api/v1/chat/completions')
        .to_return do |req|
          captured = JSON.parse(req.body)
          { status: 200,
            body: { choices: [{ message: { content: 'ok' }, finish_reason: 'stop' }],
                    usage: { prompt_tokens: 10, completion_tokens: 5 } }.to_json,
            headers: { 'Content-Type' => 'application/json' } }
        end

      provider.chat(messages, system_prompt: 'a stable system prompt')

      marker = { 'type' => 'ephemeral', 'ttl' => '1h' }
      # A marker whose TTL differs from the root-level field's is rejected, and
      # longer-TTL entries must precede shorter ones — so it is all or nothing.
      expect(captured['cache_control']).to eq(marker)
      expect(captured['messages'].first['content'].first['cache_control']).to eq(marker)
    end

    it 'leaves the system prompt a plain string for non-Anthropic models' do
      config.model = 'openai/gpt-4o'
      captured = nil
      stub_request(:post, 'https://openrouter.ai/api/v1/chat/completions')
        .to_return do |req|
          captured = JSON.parse(req.body)
          { status: 200,
            body: { choices: [{ message: { content: 'ok' }, finish_reason: 'stop' }],
                    usage: { prompt_tokens: 10, completion_tokens: 5 } }.to_json,
            headers: { 'Content-Type' => 'application/json' } }
        end

      provider.chat(messages, system_prompt: 'a stable system prompt')

      # Those models cache server-side without breakpoints; multipart content here
      # would just be a shape they need not handle.
      expect(captured['messages'].first['content']).to eq('a stable system prompt')
    end

    it 'omits cache_control for non-Anthropic models' do
      config.model = 'openai/gpt-4o'

      stub_request(:post, 'https://openrouter.ai/api/v1/chat/completions')
        .with { |req|
          body = JSON.parse(req.body)
          !body.key?('cache_control')
        }
        .to_return(
          status: 200,
          body: {
            choices: [{ message: { content: 'ok' }, finish_reason: 'stop' }],
            usage: { prompt_tokens: 10, completion_tokens: 5 }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      provider.chat(messages)
    end

    it 'sends session_id when routing_session_id is set' do
      provider.routing_session_id = 'test-session-123'

      stub_request(:post, 'https://openrouter.ai/api/v1/chat/completions')
        .with { |req|
          body = JSON.parse(req.body)
          body['session_id'] == 'test-session-123'
        }
        .to_return(
          status: 200,
          body: {
            choices: [{ message: { content: 'ok' }, finish_reason: 'stop' }],
            usage: { prompt_tokens: 10, completion_tokens: 5 }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      provider.chat(messages)
    end

    it 'sends HTTP-Referer and X-Title when configured' do
      config.openrouter_site_url = 'https://example.com'
      config.openrouter_app_name = 'MyApp'

      stub_request(:post, 'https://openrouter.ai/api/v1/chat/completions')
        .with(
          headers: {
            'Authorization' => 'Bearer test-openrouter-key',
            'HTTP-Referer' => 'https://example.com',
            'X-Title' => 'MyApp',
            'Content-Type' => 'application/json'
          }
        )
        .to_return(
          status: 200,
          body: {
            choices: [{ message: { content: 'ok' }, finish_reason: 'stop' }],
            usage: { prompt_tokens: 10, completion_tokens: 5 }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      provider.chat(messages)
    end

    it 'raises ProviderError on HTTP 200 with top-level error' do
      stub_request(:post, 'https://openrouter.ai/api/v1/chat/completions')
        .to_return(
          status: 200,
          body: {
            error: { message: 'Rate limit exceeded', code: 429 }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      expect { provider.chat(messages) }.to raise_error(
        RailsConsoleAi::Providers::ProviderError, /OpenRouter error \(429\): Rate limit exceeded/
      )
    end

    it 'raises ProviderError on HTTP 200 with choices[0].error' do
      stub_request(:post, 'https://openrouter.ai/api/v1/chat/completions')
        .to_return(
          status: 200,
          body: {
            choices: [{
              error: { message: 'Context length exceeded', code: 'context_length_exceeded' }
            }]
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      expect { provider.chat(messages) }.to raise_error(
        RailsConsoleAi::Providers::ProviderError, /OpenRouter error \(context_length_exceeded\): Context length exceeded/
      )
    end

    it 'raises ProviderError on HTTP error status' do
      stub_request(:post, 'https://openrouter.ai/api/v1/chat/completions')
        .to_return(
          status: 429,
          body: { error: { message: 'Too many requests' } }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      expect { provider.chat(messages) }.to raise_error(
        RailsConsoleAi::Providers::ProviderError, /Too many requests/
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
      stub_request(:post, 'https://openrouter.ai/api/v1/chat/completions')
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

    it 'forces stop_reason to tool_use when tool_calls present even if finish_reason differs' do
      stub_request(:post, 'https://openrouter.ai/api/v1/chat/completions')
        .to_return(
          status: 200,
          body: {
            choices: [{
              message: {
                tool_calls: [{
                  id: 'call_123',
                  type: 'function',
                  function: { name: 'list_tables', arguments: '{}' }
                }]
              },
              finish_reason: 'stop'
            }],
            usage: { prompt_tokens: 50, completion_tokens: 20 }
          }.to_json,
          headers: { 'Content-Type' => 'application/json' }
        )

      result = provider.chat_with_tools(messages, tools: mock_tools)
      expect(result.stop_reason).to eq(:tool_use)
      expect(result.tool_calls.length).to eq(1)
    end
  end

  describe '#format_assistant_message' do
    it 'builds an assistant message with tool_calls (inherited from OpenAI)' do
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
    it 'builds a tool result message (inherited from OpenAI)' do
      msg = provider.format_tool_result('call_1', 'users, posts')
      expect(msg[:role]).to eq('tool')
      expect(msg[:tool_call_id]).to eq('call_1')
      expect(msg[:content]).to eq('users, posts')
    end
  end
end
