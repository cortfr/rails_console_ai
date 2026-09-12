require 'spec_helper'
require 'rails_console_ai/executor'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/conversation_engine'

# Session #1618 failure mode: asked to save a 41KB file as an artifact, the model
# emitted a one-sentence preamble and then started writing the file into the
# save_artifact arguments. That blew the 16,000-token output cap, so the response
# came back stop_reason=max_tokens with the call half-written. The engine read it
# as a finished turn, dropped the call, and printed the preamble as the answer —
# and did exactly the same thing on every retry, at 16,000 output tokens a go.
RSpec.describe RailsConsoleAi::ConversationEngine, 'truncated responses' do
  # Always cut off at the output cap, exactly as a too-large tool argument is.
  class FakeTruncatingProvider
    attr_reader :calls, :messages_seen

    def initialize(recover_after: nil)
      @calls = 0
      @recover_after = recover_after
      @messages_seen = []
    end

    def chat_with_tools(messages, tools:, system_prompt:)
      @calls += 1
      @messages_seen << messages.map { |m| m[:content].to_s }

      if @recover_after && @calls > @recover_after
        return RailsConsoleAi::Providers::ChatResult.new(
          text: 'Saved it from Ruby instead.', input_tokens: 100, output_tokens: 20,
          stop_reason: :end_turn
        )
      end

      RailsConsoleAi::Providers::ChatResult.new(
        text: 'Now saving the actual verbatim content as the artifact.',
        input_tokens: 100, output_tokens: 16_000,
        stop_reason: :max_tokens,
        # A partial call is what actually arrives; it must never be executed.
        tool_calls: [{ id: 'call_1', name: 'save_artifact',
                       arguments: { 'content' => '<!DOCTYPE html' } }]
      )
    end

    def chat(messages, system_prompt: nil)
      raise 'should not be called'
    end

    def format_assistant_message(result)
      { role: :assistant, content: result.text }
    end

    def format_tool_result(tool_call_id, result_string)
      { role: :tool, tool_call_id: tool_call_id, content: result_string }
    end
  end

  class RecordingToolsStub
    attr_reader :definitions, :executed

    def initialize
      @definitions = []
      @executed = []
    end

    def execute(name, args)
      @executed << [name, args]
      'ok'
    end

    def last_cached?; false; end
    def last_sub_agent_usage; nil; end
  end

  let(:statuses) { [] }
  let(:warnings) { [] }
  let(:errors) { [] }
  let(:channel) do
    ch = double('channel',
      mode: 'slack',
      user_identity: 'jess',
      system_instructions: nil,
      cancelled?: false,
      supports_danger?: false
    )
    allow(ch).to receive(:display_status) { |s| statuses << s }
    allow(ch).to receive(:display_warning) { |s| warnings << s }
    allow(ch).to receive(:display_error) { |s| errors << s }
    allow(ch).to receive(:display_thinking)
    allow(ch).to receive(:display_tool_call)
    allow(ch).to receive(:wrap_llm_call) { |&b| b.call }
    ch
  end
  let(:test_binding) { Object.new.instance_eval { binding } }
  let(:tools) { RecordingToolsStub.new }
  subject(:engine) { described_class.new(binding_context: test_binding, channel: channel) }

  before do
    RailsConsoleAi.configure do |c|
      c.provider = :anthropic
      c.api_key = 'test-key'
      c.model = 'claude-sonnet-5'
      c.max_tokens = 16_000
      c.max_tool_rounds = 50
      c.session_logging = false
    end
  end

  def run_loop(provider)
    engine.instance_variable_set(:@provider, provider)
    engine.send(:send_query_with_tools,
      [{ role: :user, content: 'save that file as an artifact, verbatim' }],
      system_prompt: 'test system prompt',
      tools_override: tools)
  end

  it 'never executes the half-written tool call' do
    run_loop(FakeTruncatingProvider.new)
    expect(tools.executed).to be_empty
  end

  it 'tells the user the response was cut off instead of failing silently' do
    run_loop(FakeTruncatingProvider.new)
    expect(warnings.join("\n")).to include('output-token cap')
  end

  it 'nudges the model toward saving from Ruby rather than retrying the same call' do
    provider = FakeTruncatingProvider.new
    run_loop(provider)
    nudge = provider.messages_seen.last.find { |c| c.include?('cut off at the') }
    expect(nudge).to include('RailsConsoleAi.save_artifact')
    expect(nudge).to include('execute_code')
  end

  it 'stops after the retry instead of truncating forever' do
    provider = FakeTruncatingProvider.new
    run_loop(provider)
    expect(provider.calls).to eq(described_class::MAX_TRUNCATION_RETRIES + 1)
    expect(errors.join("\n")).to include('Truncated again')
  end

  it 'carries on normally when the nudged retry comes back within the cap' do
    provider = FakeTruncatingProvider.new(recover_after: 1)
    result, = run_loop(provider)
    expect(result.text).to eq('Saved it from Ruby instead.')
    expect(errors).to be_empty
  end
end
