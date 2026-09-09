require 'spec_helper'
require 'rails_console_ai/executor'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/providers/anthropic'
require 'rails_console_ai/providers/bedrock'
require 'rails_console_ai/context_builder'
require 'rails_console_ai/conversation_engine'

# Minimal stand-in for the AWS SDK, mirroring spec/providers/bedrock_spec.rb.
# `Types::CachePointBlock` matters here specifically: the provider probes it for a
# `ttl` member before sending one, because older SDK versions raise on it.
module Aws
  module BedrockRuntime
    module Errors
      class ServiceError < StandardError; end
    end
    class Client
      def initialize(opts = {}); end
      def converse(params); end
    end
    module Types
      CachePointBlock = Struct.new(:type, :ttl) unless defined?(CachePointBlock)
    end
  end
end

# Prompt caching is a prefix match: any byte that changes inside the prefix
# invalidates every cached block after it. Nothing announces a break — requests
# keep succeeding, the bill just goes up — so the checks here are structural and
# run on every build. They cannot prove a cache HIT (that needs the real API; see
# spec/integration/prompt_caching_integration_spec.rb) — they prove the request is
# still shaped so a hit is possible.
RSpec.describe 'prompt caching' do
  def suppress_output
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = old_stdout
  end

  # Strip the moving breakpoint before comparing two requests. The marker
  # legitimately moves to the tail on every request and is not an invalidator —
  # blocks marked by an earlier request stay valid read points.
  def without_markers(node)
    case node
    when Array then node.map { |n| without_markers(n) }
    when Hash  then node.reject { |k, _| k == 'cache_control' }
                       .transform_values { |v| without_markers(v) }
    else node
    end
  end

  def count_breakpoints(node)
    case node
    when Array then node.sum { |n| count_breakpoints(n) }
    when Hash  then (node.key?('cache_control') ? 1 : 0) + node.values.sum { |v| count_breakpoints(v) }
    else 0
    end
  end

  describe RailsConsoleAi::Providers::Anthropic do
    let(:config) do
      RailsConsoleAi::Configuration.new.tap do |c|
        c.provider = :anthropic
        c.api_key = 'test-key'
        c.model = 'claude-sonnet-5'
      end
    end
    subject(:provider) { described_class.new(config) }

    let(:bodies) { [] }

    before do
      stub_request(:post, 'https://api.anthropic.com/v1/messages')
        .to_return do |req|
          bodies << JSON.parse(req.body)
          {
            status: 200,
            body: {
              content: [{ type: 'text', text: 'ok' }],
              usage: { input_tokens: 5, output_tokens: 5 },
              stop_reason: 'end_turn'
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          }
        end
    end

    let(:tools) do
      double('tools', to_anthropic_format: [
        { 'name' => 'a', 'description' => 'a', 'input_schema' => {} },
        { 'name' => 'b', 'description' => 'b', 'input_schema' => {} }
      ])
    end

    it 'caches the conversation tail, not just tools and system' do
      provider.chat_with_tools(
        [{ role: :user, content: 'first' }, { role: :user, content: 'second' }],
        tools: tools, system_prompt: 'stable prompt'
      )

      body = bodies.last
      expect(body['system'].last['cache_control']).to eq('type' => 'ephemeral')
      expect(body['tools'].last['cache_control']).to eq('type' => 'ephemeral')
      # The breakpoint is on the LAST message — without it every round of a tool
      # loop re-bills the whole accumulated history at full input price.
      expect(body['messages'].last['content'].last['cache_control']).to eq('type' => 'ephemeral')
      expect(body['messages'].first['content']).to eq([{ 'type' => 'text', 'text' => 'first' }])
    end

    it 'marks the last block of an array-content message' do
      history = [
        { role: :user, content: 'q' },
        { role: :user, content: [
          { 'type' => 'tool_result', 'tool_use_id' => 't1', 'content' => 'row one' },
          { 'type' => 'tool_result', 'tool_use_id' => 't2', 'content' => 'row two' }
        ] }
      ]

      provider.chat_with_tools(history, tools: tools, system_prompt: 'stable prompt')

      blocks = bodies.last['messages'].last['content']
      expect(blocks.first).not_to have_key('cache_control')
      expect(blocks.last['cache_control']).to eq('type' => 'ephemeral')
      # The caller's history must not be mutated — those hashes are the engine's
      # persisted conversation, and a stray marker in them would be re-sent.
      expect(history.last[:content].last).not_to have_key('cache_control')
    end

    it 'stays within the 4-breakpoint limit' do
      provider.chat_with_tools(
        Array.new(6) { |i| { role: :user, content: "msg #{i}" } },
        tools: tools, system_prompt: 'stable prompt'
      )

      expect(count_breakpoints(bodies.last)).to be <= 4
    end

    it 'applies the configured 1-hour TTL to every breakpoint' do
      config.cache_ttl = '1h'

      provider.chat_with_tools(
        [{ role: :user, content: 'hello' }],
        tools: tools, system_prompt: 'stable prompt'
      )

      body = bodies.last
      marker = { 'type' => 'ephemeral', 'ttl' => '1h' }
      # Entries with the longer TTL must precede shorter ones, so the TTL is all
      # or nothing across tools / system / messages.
      expect(body['tools'].last['cache_control']).to eq(marker)
      expect(body['system'].last['cache_control']).to eq(marker)
      expect(body['messages'].last['content'].last['cache_control']).to eq(marker)
    end

    it 'does not mark an empty trailing message' do
      provider.chat_with_tools(
        [{ role: :user, content: 'hi' }, { role: :assistant, content: '' }],
        tools: tools, system_prompt: 'stable prompt'
      )

      expect(count_breakpoints(bodies.last['messages'])).to eq(0)
    end
  end

  describe RailsConsoleAi::Providers::Bedrock do
    let(:config) do
      RailsConsoleAi::Configuration.new.tap do |c|
        c.provider = :bedrock
        c.model = 'us.anthropic.claude-sonnet-5'
        c.max_tokens = 1024
        c.bedrock_region = 'us-east-1'
      end
    end
    subject(:provider) { described_class.new(config) }

    let(:captured) { [] }
    let(:mock_client) do
      client = instance_double(Aws::BedrockRuntime::Client)
      allow(client).to receive(:converse) do |params|
        captured << params
        usage = double('usage', input_tokens: 5, output_tokens: 5)
        message = double('message', content: [])
        double('response', output: double('output', message: message),
                           usage: usage, stop_reason: 'end_turn')
      end
      client
    end
    let(:tools) do
      double('tools', to_bedrock_format: [{ tool_spec: { name: 'a', description: 'a', input_schema: { json: {} } } }])
    end

    before { allow(Aws::BedrockRuntime::Client).to receive(:new).and_return(mock_client) }

    it 'appends a cache point to the last message' do
      # Roles alternate on purpose: #format_messages merges consecutive same-role
      # messages into one, so two user turns would collapse and there would be no
      # earlier message left to assert stays unmarked.
      provider.chat_with_tools(
        [{ role: :user, content: 'first' },
         { role: :assistant, content: 'ok' },
         { role: :user, content: 'second' }],
        tools: tools, system_prompt: 'stable prompt'
      )

      msgs = captured.last[:messages]
      expect(msgs.length).to eq(3)
      expect(msgs.last[:content].last).to eq(cache_point: { type: 'default' })
      expect(msgs.first[:content].last).not_to have_key(:cache_point)
      expect(captured.last[:system].last).to eq(cache_point: { type: 'default' })
    end

    # Bedrock does support the 1-hour cache; the TTL rides on the cache point.
    it 'carries the 1-hour TTL on every cache point' do
      config.cache_ttl = '1h'

      provider.chat_with_tools(
        [{ role: :user, content: 'first' }], tools: tools, system_prompt: 'stable prompt'
      )

      point = { cache_point: { type: 'default', ttl: '1h' } }
      expect(captured.last[:system].last).to eq(point)
      expect(captured.last[:tool_config][:tools].last).to eq(point)
      expect(captured.last[:messages].last[:content].last).to eq(point)
    end

    # Older aws-sdk-bedrockruntime has no `ttl` member and the SDK raises on an
    # unknown param, so the TTL is dropped rather than risking the whole request.
    it 'omits the TTL when the installed SDK has no ttl member' do
      config.cache_ttl = '1h'
      allow(provider).to receive(:cache_ttl_supported?).and_return(false)

      provider.chat_with_tools(
        [{ role: :user, content: 'first' }], tools: tools, system_prompt: 'stable prompt'
      )

      expect(captured.last[:messages].last[:content].last).to eq(cache_point: { type: 'default' })
    end
  end

  describe 'prefix stability across turns' do
    let(:bodies) { [] }
    let(:channel) do
      ch = double('channel',
        mode: 'console',
        user_identity: 'test',
        system_instructions: nil,
        cancelled?: false,
        supports_danger?: true
      )
      allow(ch).to receive(:display_status)
      allow(ch).to receive(:display_thinking)
      allow(ch).to receive(:display_tool_call)
      allow(ch).to receive(:display_warning)
      allow(ch).to receive(:display_error)
      allow(ch).to receive(:display)
      allow(ch).to receive(:display_result)
      allow(ch).to receive(:display_code)
      allow(ch).to receive(:wrap_llm_call) { |&b| b.call }
      ch
    end
    let(:console_binding) { Object.new.instance_eval { binding } }
    subject(:engine) do
      RailsConsoleAi::ConversationEngine.new(binding_context: console_binding, channel: channel)
    end

    before do
      RailsConsoleAi.configure do |c|
        c.provider = :anthropic
        c.api_key = 'test-key'
        c.model = 'claude-sonnet-5'
        c.session_logging = false
      end

      stub_request(:post, 'https://api.anthropic.com/v1/messages')
        .to_return do |req|
          bodies << JSON.parse(req.body)
          {
            status: 200,
            body: {
              content: [{ type: 'text', text: "answer #{bodies.length}" }],
              usage: { input_tokens: 100, output_tokens: 20 },
              stop_reason: 'end_turn'
            }.to_json,
            headers: { 'Content-Type' => 'application/json' }
          }
        end
    end

    # The regression this guards against: the system prompt renders ahead of the
    # whole conversation, so anything session-volatile in it (a variable list, a
    # timestamp, a mode flag) re-bills every cached message on every turn.
    it 'keeps the system prompt byte-identical when the console binding changes' do
      suppress_output { engine.process_message('how many users?') }

      console_binding.local_variable_set(:orders, [1, 2, 3])
      suppress_output { engine.process_message('and orders?') }

      expect(bodies.length).to eq(2)
      expect(bodies[1]['system']).to eq(bodies[0]['system'])
    end

    it 'still tells the model about the binding variables, via the user turn' do
      console_binding.local_variable_set(:orders, [1, 2, 3])
      suppress_output { engine.process_message('and orders?') }

      expect(bodies[0]['system'].last['text']).not_to include('orders')
      tail = bodies[0]['messages'].last['content'].map { |b| b['text'] }.join
      expect(tail).to include('and orders?')
      expect(tail).to include('orders (Array)')
    end

    # The overlap between two consecutive requests must be byte-identical: the
    # earlier request's prompt should reappear unchanged as a prefix of the next.
    # The first divergence inside that overlap is the invalidation point.
    it 'grows the message array append-only' do
      suppress_output { engine.process_message('first question') }
      suppress_output { engine.process_message('second question') }

      previous = without_markers(bodies[0]['messages'])
      current  = without_markers(bodies[1]['messages'])

      expect(current.length).to be > previous.length
      expect(current.first(previous.length)).to eq(previous)
    end
  end

  describe 'tool-loop bookkeeping' do
    # Asks for one tool call per round with fresh arguments each time, so the
    # identical-call breaker never fires and the round cap forces the wrap-up.
    class CacheReportingProvider
      FINAL_NUDGE = /(final|best) answer now/

      attr_reader :calls

      def initialize
        @round = 0
        @calls = 0
      end

      def chat_with_tools(messages, tools:, system_prompt:)
        @calls += 1
        last = messages.last
        if last[:role] == :user && last[:content].to_s.match?(FINAL_NUDGE)
          return RailsConsoleAi::Providers::ChatResult.new(
            text: 'Final summary.', input_tokens: 1, output_tokens: 1,
            cache_read_input_tokens: 7, cache_write_input_tokens: 3,
            stop_reason: :end_turn
          )
        end

        @round += 1
        RailsConsoleAi::Providers::ChatResult.new(
          text: '', input_tokens: 10, output_tokens: 5,
          cache_read_input_tokens: 100, cache_write_input_tokens: 20,
          stop_reason: :tool_use,
          tool_calls: [{ id: "call_#{@round}", name: 'execute_code',
                         arguments: { 'code' => "attempt_#{@round}" } }]
        )
      end

      def format_assistant_message(result)
        tc = result.tool_calls.first
        { role: :assistant,
          content: [{ 'type' => 'tool_use', 'id' => tc[:id], 'name' => tc[:name], 'input' => tc[:arguments] }] }
      end

      def format_tool_result(tool_call_id, result_string)
        { role: :user,
          content: [{ 'type' => 'tool_result', 'tool_use_id' => tool_call_id, 'content' => result_string.to_s }] }
      end
    end

    class NudgeToolsStub
      attr_reader :definitions

      def initialize(result)
        @result = result
        @definitions = []
      end

      def execute(_name, _args) = @result
      def last_cached? = false
      def last_sub_agent_usage = nil
    end

    let(:channel) do
      ch = double('channel',
        mode: 'slack', user_identity: 'jess', system_instructions: nil,
        cancelled?: false, supports_danger?: false
      )
      allow(ch).to receive(:display_status)
      allow(ch).to receive(:display_thinking)
      allow(ch).to receive(:display_tool_call)
      allow(ch).to receive(:wrap_llm_call) { |&b| b.call }
      ch
    end
    let(:test_binding) { Object.new.instance_eval { binding } }
    let(:provider) { CacheReportingProvider.new }
    subject(:engine) do
      RailsConsoleAi::ConversationEngine.new(binding_context: test_binding, channel: channel)
    end

    before do
      RailsConsoleAi.configure do |c|
        c.provider = :anthropic
        c.api_key = 'test-key'
        c.max_tool_rounds = 8
        c.session_logging = false
      end
      engine.instance_variable_set(:@provider, provider)
    end

    def run_loop(tool_result)
      suppress_output do
        engine.send(:send_query_with_tools,
          [{ role: :user, content: 'why was the SMS not sent?' }],
          system_prompt: 'stable prompt',
          tools_override: NudgeToolsStub.new(tool_result))
      end
    end

    # A message injected for one request and dropped before the next rewrites the
    # prefix at the point it was injected, so everything cached after it misses.
    it 'persists steering nudges into the returned history' do
      _result, new_messages, _stats = run_loop('ERROR: OpenSSL::Cipher::CipherError: bad decrypt')

      nudges = new_messages.select { |m| m[:role] == :user && m[:content].is_a?(String) }
      expect(nudges.map { |m| m[:content] }).to include(a_string_matching(/hit the same error/))
      expect(nudges.map { |m| m[:content] }).to include(a_string_matching(/(final|best) answer now/))
    end

    # Cache activity is the only evidence the caching above is working, and the
    # loop is where nearly all of it happens — so it has to survive the roll-up.
    it 'reports summed cache usage out of the loop' do
      result, _new_messages, _stats = run_loop('some rows')

      expect(result.cache_read_input_tokens).to be > 0
      expect(result.cache_write_input_tokens).to be > 0
      # Every round's counters, not just the last call's.
      expect(result.cache_read_input_tokens).to eq(100 * (provider.calls - 1) + 7)
      expect(result.cache_write_input_tokens).to eq(20 * (provider.calls - 1) + 3)
    end

    # The visible symptom of the old arithmetic: a well-cached round reported a
    # NEGATIVE cost, because cache_read was discounted out of an input count that
    # never contained it.
    it 'never reports a negative per-call cost, however well cached' do
      result = RailsConsoleAi::Providers::ChatResult.new(
        text: 'ok', input_tokens: 2, output_tokens: 80,
        cache_read_input_tokens: 13_900, cache_write_input_tokens: 954,
        stop_reason: :end_turn
      )

      stats = engine.send(:format_llm_stats, result)

      expect(stats).to include('cache r: 13.9K w: 954')
      cost = stats[/~\$(-?[\d.]+)/, 1].to_f
      expect(cost).to be > 0
    end

    # The token budget is a runaway-loop guard, and it was calibrated when message
    # history was billed at full price. Measuring it on `input_tokens` alone means
    # caching silently disarms it: a loop can grow to any size while that counter
    # sits near zero.
    it 'measures the token budget against total prompt volume, not uncached input' do
      # The fake provider bills 10 uncached + 120 cached input tokens per round over
      # 8 rounds: 1,040 prompt tokens but only 80 uncached. A threshold between the
      # two can only be crossed by a budget that counts the cached tokens.
      RailsConsoleAi.configuration.token_nudge_threshold = 500
      RailsConsoleAi.configuration.token_stop_threshold = nil

      _result, new_messages, _stats = run_loop('some rows')

      wrap_up = new_messages.find do |m|
        m[:content].is_a?(String) && m[:content].include?('prompt tokens without reaching a conclusion')
      end
      expect(wrap_up).not_to be_nil
    end

    it 'prices each usage bucket at its own rate' do
      pricing = RailsConsoleAi::Configuration.pricing_for('claude-sonnet-5')

      # input_tokens is the uncached remainder, so buckets simply add up;
      # discounting cache_read out of input would understate the total.
      cost = (1_000 * pricing[:input]) + (500 * pricing[:output]) +
             (10_000 * pricing[:cache_read]) + (2_000 * pricing[:cache_write])

      expect(cost).to be_within(1e-12).of(
        (1_000 * 2.0 + 500 * 10.0 + 10_000 * 0.2 + 2_000 * 2.5) / 1_000_000
      )
    end
  end
end
