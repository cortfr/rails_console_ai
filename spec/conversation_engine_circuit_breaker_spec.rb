require 'spec_helper'
require 'rails_console_ai/executor'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/conversation_engine'

# Circuit breakers for runaway tool loops (session #1069 failure mode):
# the LLM keeps writing DIFFERENT code that fails the SAME way, so the
# identical-call loop detection never fires. Two guards catch it instead:
# - repeated-error: same normalized error signature across different tool calls
# - token budget: input tokens in a single tool loop cross nudge/stop thresholds
RSpec.describe RailsConsoleAi::ConversationEngine, 'runaway-loop circuit breakers' do
  # Always asks for another execute_code call with NEW arguments each round
  # (defeating identical-call loop detection) until the engine forces a final
  # answer via the finalize call. The finalize call must go through
  # chat_with_tools: `chat` here mimics Bedrock, which rejects transcripts
  # containing tool_use/tool_result blocks when the request defines no tools.
  class FakeLoopingProvider
    # All four wrap-up nudges say "final answer now" or "best answer now";
    # the mid-loop warn nudges say neither.
    FINAL_NUDGE = /(final|best) answer now/

    attr_reader :tool_rounds, :finalize_calls, :last_finalize_messages

    def initialize(input_tokens_per_round: 1_000, finalize_result: nil)
      @round = 0
      @tool_rounds = 0
      @finalize_calls = 0
      @input_tokens_per_round = input_tokens_per_round
      @finalize_result = finalize_result
    end

    def chat_with_tools(messages, tools:, system_prompt:)
      last = messages.last
      if last[:role] == :user && last[:content].to_s.match?(FINAL_NUDGE)
        @finalize_calls += 1
        @last_finalize_messages = messages
        return @finalize_result || RailsConsoleAi::Providers::ChatResult.new(
          text: 'Final summary.', input_tokens: 10, output_tokens: 10, stop_reason: :end_turn
        )
      end

      @round += 1
      @tool_rounds += 1
      RailsConsoleAi::Providers::ChatResult.new(
        text: '',
        input_tokens: @input_tokens_per_round,
        output_tokens: 10,
        stop_reason: :tool_use,
        tool_calls: [{ id: "call_#{@round}", name: 'execute_code',
                       arguments: { 'code' => "attempt_#{@round}" } }]
      )
    end

    def chat(messages, system_prompt: nil)
      raise RailsConsoleAi::Providers::ProviderError,
        'AWS Bedrock error: The toolConfig field must be defined when using toolUse and toolResult content blocks.'
    end

    def format_assistant_message(result)
      tc = result.tool_calls.first
      { role: :assistant,
        content: [{ 'type' => 'tool_use', 'id' => tc[:id], 'name' => tc[:name], 'input' => tc[:arguments] }] }
    end

    def format_tool_result(tool_call_id, result_string)
      { role: :tool, tool_call_id: tool_call_id, content: result_string }
    end
  end

  # Tools stub whose execute returns whatever the block produces (call count passed in).
  class FakeToolsStub
    attr_reader :definitions, :calls

    def initialize(&result_fn)
      @result_fn = result_fn
      @definitions = []
      @calls = 0
    end

    def execute(_name, _args)
      @calls += 1
      @result_fn.call(@calls)
    end

    def last_cached?
      false
    end

    def last_sub_agent_usage
      nil
    end
  end

  let(:statuses) { [] }
  let(:channel) do
    ch = double('channel',
      mode: 'slack',
      user_identity: 'jess',
      system_instructions: nil,
      cancelled?: false,
      supports_danger?: false
    )
    allow(ch).to receive(:display_status) { |s| statuses << s }
    allow(ch).to receive(:display_thinking)
    allow(ch).to receive(:display_tool_call)
    allow(ch).to receive(:wrap_llm_call) { |&b| b.call }
    ch
  end
  let(:test_binding) { Object.new.instance_eval { binding } }
  subject(:engine) { described_class.new(binding_context: test_binding, channel: channel) }

  before do
    RailsConsoleAi.configure do |c|
      c.provider = :anthropic
      c.api_key = 'test-key'
      c.max_tool_rounds = 50
      c.session_logging = false
    end
  end

  def run_loop(provider, tools)
    engine.instance_variable_set(:@provider, provider)
    engine.send(:send_query_with_tools,
      [{ role: :user, content: 'why was the SMS not sent?' }],
      system_prompt: 'test system prompt',
      tools_override: tools)
  end

  describe 'repeated-error breaker' do
    let(:provider) { FakeLoopingProvider.new }
    let(:tools) { FakeToolsStub.new { |_n| 'ERROR: OpenSSL::Cipher::CipherError: bad decrypt' } }

    it 'injects a strategy-change nudge at the warn threshold' do
      run_loop(provider, tools)
      warn_msg = provider.last_finalize_messages.find do |m|
        m[:role] == :user && m[:content].to_s.include?('hit the same error')
      end
      expect(warn_msg).not_to be_nil
    end

    it 'breaks at the break threshold and forces a final answer' do
      result, = run_loop(provider, tools)
      expect(provider.tool_rounds).to eq(described_class::REPEAT_ERROR_BREAK_THRESHOLD)
      expect(provider.finalize_calls).to eq(1)
      expect(result.text).to eq('Final summary.')
      expect(provider.last_finalize_messages.last[:content]).to include('hit the same error repeatedly')
      expect(statuses.join("\n")).to include('Circuit breaker')
    end

    it 'treats errors differing only in numbers as the same signature' do
      tools = FakeToolsStub.new { |n| "ERROR: ActiveRecord::RecordNotFound: Couldn't find Event with id=#{n}" }
      run_loop(provider, tools)
      expect(provider.tool_rounds).to eq(described_class::REPEAT_ERROR_BREAK_THRESHOLD)
    end

    it 'does not trip on successful results' do
      tools = FakeToolsStub.new { |n| "Output:\nok #{n}\n\nReturn value: #{n}" }
      RailsConsoleAi.configuration.max_tool_rounds = 8
      run_loop(provider, tools)
      expect(provider.tool_rounds).to eq(8) # runs to the round cap, not the breaker
      expect(statuses.join("\n")).not_to include('Circuit breaker')
    end
  end

  describe 'token budget breaker' do
    it 'nudges at token_nudge_threshold and stops at token_stop_threshold' do
      RailsConsoleAi.configuration.token_nudge_threshold = 2_500
      RailsConsoleAi.configuration.token_stop_threshold = 4_500
      provider = FakeLoopingProvider.new(input_tokens_per_round: 1_000)
      tools = FakeToolsStub.new { |n| "Output:\nok #{n}\n\nReturn value: nil" }

      result, = run_loop(provider, tools)

      # nudge lands after round 3 (3000 >= 2500), stop after round 5 (5000 >= 4500)
      expect(provider.tool_rounds).to eq(5)
      expect(provider.finalize_calls).to eq(1)
      expect(result.text).to eq('Final summary.')
      nudge = provider.last_finalize_messages.find do |m|
        m[:role] == :user && m[:content].to_s.include?('Wrap up now')
      end
      expect(nudge).not_to be_nil
      expect(provider.last_finalize_messages.last[:content]).to include('exceeded its token budget')
    end

    it 'is disabled when thresholds are nil' do
      RailsConsoleAi.configuration.token_nudge_threshold = nil
      RailsConsoleAi.configuration.token_stop_threshold = nil
      RailsConsoleAi.configuration.max_tool_rounds = 6
      provider = FakeLoopingProvider.new(input_tokens_per_round: 1_000_000)
      tools = FakeToolsStub.new { |n| "Output:\nok #{n}\n\nReturn value: nil" }

      run_loop(provider, tools)
      expect(provider.tool_rounds).to eq(6) # only the round cap stops it
    end
  end

  # Bedrock rejects any request whose messages contain toolUse/toolResult
  # blocks unless the request defines toolConfig — so the forced-final-answer
  # call must keep the tool definitions on the request (production error:
  # "The toolConfig field must be defined when using toolUse and toolResult
  # content blocks", seen via explore_output and delegate_task).
  describe 'wrap-up finalize call' do
    let(:tools) { FakeToolsStub.new { |n| "Output:\nok #{n}\n\nReturn value: nil" } }

    it 'uses chat_with_tools over the tool-bearing transcript' do
      RailsConsoleAi.configuration.max_tool_rounds = 3
      provider = FakeLoopingProvider.new

      result, = run_loop(provider, tools)

      expect(provider.finalize_calls).to eq(1)
      expect(result.text).to eq('Final summary.')
      # The finalize transcript still contains tool_use blocks — the exact
      # shape Bedrock rejects when the request defines no tools. If the
      # engine regresses to provider.chat, the fake raises the Bedrock error.
      tool_use_msgs = provider.last_finalize_messages.select do |m|
        m[:content].is_a?(Array) && m[:content].any? { |b| b['type'] == 'tool_use' }
      end
      expect(tool_use_msgs).not_to be_empty
    end

    it 'takes the text and ignores tool calls if the finalize response still tries to use tools' do
      RailsConsoleAi.configuration.max_tool_rounds = 3
      provider = FakeLoopingProvider.new(finalize_result: RailsConsoleAi::Providers::ChatResult.new(
        text: 'Partial answer.', input_tokens: 10, output_tokens: 10, stop_reason: :tool_use,
        tool_calls: [{ id: 'call_final', name: 'execute_code', arguments: { 'code' => 'one_more' } }]
      ))

      result, = run_loop(provider, tools)

      expect(result.text).to eq('Partial answer.')
      expect(result.tool_use?).to be_falsey
      expect(tools.calls).to eq(3) # the finalize response's tool call was not executed
    end
  end
end
