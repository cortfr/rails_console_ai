require 'spec_helper'
require 'rails_console_ai/executor'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/providers/anthropic'
require 'rails_console_ai/context_builder'
require 'rails_console_ai/conversation_engine'
require 'rails_console_ai/tools/registry'

# A thinking block is signed against everything that precedes it: the system
# prompt, the tool set and every earlier message. Sending one back is how the
# model keeps its reasoning from one round of a tool loop to the next — and the
# API rejects it if anything before it has changed since. So two things are
# checked here on every build: that thinking goes back exactly as it arrived,
# and that the harness never rewrites what a replayed block is bound to.
#
# Like the caching specs, these prove the requests are shaped correctly. Only
# the real API can prove it accepts them — see
# spec/integration/thinking_replay_integration_spec.rb.
RSpec.describe 'thinking replay' do
  def suppress_output
    old_stdout = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = old_stdout
  end

  def without_markers(node)
    case node
    when Array then node.map { |n| without_markers(n) }
    when Hash  then node.reject { |k, _| k == 'cache_control' }.transform_values { |v| without_markers(v) }
    else node
    end
  end

  def thinking(signature)
    { 'type' => 'thinking', 'thinking' => '', 'signature' => signature }
  end

  def text(string)
    { 'type' => 'text', 'text' => string }
  end

  def tool_use(id, name, input = {})
    { 'type' => 'tool_use', 'id' => id, 'name' => name, 'input' => input }
  end

  def describe_table(id, table)
    tool_use(id, 'describe_table', 'table_name' => table)
  end

  # Schema lookups are never collapsed (do_not_trim), so the large-output
  # examples read a file instead.
  def read_file(id, path)
    tool_use(id, 'read_file', 'path' => path)
  end

  # Signatures of the thinking blocks in a request body, in order.
  def signatures(body)
    body['messages'].flat_map { |m| m['content'].is_a?(Array) ? m['content'] : [] }
                    .select { |b| b['type'] == 'thinking' }
                    .map { |b| b['signature'] }
  end

  def tool_result_text(body, tool_use_id)
    body['messages'].flat_map { |m| m['content'].is_a?(Array) ? m['content'] : [] }
                    .find { |b| b['type'] == 'tool_result' && b['tool_use_id'] == tool_use_id }
                    &.fetch('content')
  end

  let(:bodies) { [] }
  let(:responses) { [] }
  # What describe_table and read_file return, per table or path. Every other
  # tool runs for real.
  let(:tables) { Hash.new('id integer, name varchar') }
  let(:large_output) { 'row ' * 7_000 } # over LARGE_OUTPUT_THRESHOLD

  let(:channel) do
    ch = double('channel',
      mode: 'console', user_identity: 'test', system_instructions: nil,
      cancelled?: false, supports_danger?: true
    )
    %i[display_status display_thinking display_tool_call display_warning display_error
       display display_result display_code].each { |m| allow(ch).to receive(m) }
    allow(ch).to receive(:wrap_llm_call) { |&b| b.call }
    ch
  end
  let(:console_binding) { Object.new.instance_eval { binding } }
  subject(:engine) do
    RailsConsoleAi::ConversationEngine.new(binding_context: console_binding, channel: channel)
  end

  def respond(*content, stop_reason: 'tool_use')
    responses << { status: 200, headers: { 'Content-Type' => 'application/json' },
                   body: { content: content, stop_reason: stop_reason,
                           usage: { input_tokens: 100, output_tokens: 20 } }.to_json }
  end

  def finish(string = 'Done.')
    respond(thinking('sig-final'), text(string), stop_reason: 'end_turn')
  end

  def ask(question)
    suppress_output { engine.process_message(question) }
  end

  before do
    RailsConsoleAi.configure do |c|
      c.provider = :anthropic
      c.api_key = 'test-key'
      c.model = 'claude-sonnet-5-5'
      c.session_logging = false
    end

    outputs = tables
    allow_any_instance_of(RailsConsoleAi::Tools::Registry).to receive(:execute).and_wrap_original do |original, name, args|
      %w[describe_table read_file].include?(name) ? outputs[args['table_name'] || args['path']] : original.call(name, args)
    end

    stub_request(:post, 'https://api.anthropic.com/v1/messages').to_return do |req|
      bodies << JSON.parse(req.body)
      responses.shift || raise('the scripted provider ran out of responses')
    end
  end

  describe 'within a tool loop' do
    it 'sends an assistant turn back block for block, thinking first' do
      respond(thinking('sig-1'), text('Checking the schema.'), describe_table('call_1', 'users'))
      finish

      ask('what columns does users have?')

      expect(bodies.length).to eq(2)
      expect(bodies[1]['messages'][1]).to eq(
        'role' => 'assistant',
        'content' => [thinking('sig-1'), text('Checking the schema.'), describe_table('call_1', 'users')]
      )
    end

    it 'keeps every earlier thinking block as the loop goes on' do
      respond(thinking('sig-1'), describe_table('call_1', 'users'))
      respond(thinking('sig-2'), describe_table('call_2', 'orders'))
      respond(thinking('sig-3'), describe_table('call_3', 'items'))
      finish

      ask('compare the three tables')

      expect(bodies.map { |b| signatures(b) }).to eq([[], %w[sig-1], %w[sig-1 sig-2], %w[sig-1 sig-2 sig-3]])
    end

    it 'leaves a turn without thinking in its usual shape' do
      respond(text('Checking.'), describe_table('call_1', 'users'))
      respond(text('Done.'), stop_reason: 'end_turn')

      ask('what columns does users have?')

      expect(bodies[1]['messages'][1]['content']).to eq([text('Checking.'), describe_table('call_1', 'users')])
    end

    # The old behaviour: a large output was shown once, then replaced with a
    # one-line reference before the next round — rewriting a message the
    # thinking blocks after it were already bound to.
    it 'does not rewrite a large output that has already been sent' do
      tables['events.log'] = large_output
      respond(thinking('sig-1'), read_file('call_1', 'events.log'))
      respond(thinking('sig-2'), describe_table('call_2', 'users'))
      respond(thinking('sig-3'), describe_table('call_3', 'orders'))
      finish

      ask('look at the event log, then users and orders')

      expect(tool_result_text(bodies[1], 'call_1')).to include('Output truncated at')
      bodies.each_cons(2) do |earlier, later|
        shared = earlier['messages'].length
        expect(without_markers(later['messages'].first(shared))).to eq(without_markers(earlier['messages']))
      end
      expect(signatures(bodies.last)).to eq(%w[sig-1 sig-2 sig-3])
    end

    it 'returns a recalled output as a new message instead of editing the old one' do
      tables['events.log'] = large_output
      respond(thinking('sig-1'), read_file('call_1', 'events.log'))
      respond(thinking('sig-2'), tool_use('call_2', 'recall_output', 'id' => 1))
      finish

      ask('show me the whole event log')

      last = bodies.last
      expect(tool_result_text(last, 'call_1')).to include('Output truncated at')
      expect(tool_result_text(last, 'call_2')).to eq(large_output)
      expect(without_markers(last['messages'].first(3))).to eq(without_markers(bodies[1]['messages']))
      expect(signatures(last)).to eq(%w[sig-1 sig-2])
    end
  end

  describe 'at the start of the next turn' do
    before do
      tables['events.log'] = large_output
      respond(thinking('sig-1'), describe_table('call_1', 'users'))
      respond(thinking('sig-2'), read_file('call_2', 'events.log'))
      respond(thinking('sig-3'), describe_table('call_3', 'orders'))
      finish
      ask('look at users, the event log and orders')

      finish('Still done.')
      ask('anything else?')
    end

    it 'collapses the large output to a reference' do
      expect(tool_result_text(bodies.last, 'call_2')).to match(/\[Output omitted .*output_id=\d+/)
    end

    it 'drops the thinking that followed the collapsed output, and only that' do
      # sig-2 belongs to the assistant turn that asked for the output, so it
      # precedes the edit and is still valid; sig-3 came after it.
      expect(signatures(bodies.last)).to eq(%w[sig-1 sig-2])
    end

    it 'sends the same thing for those messages from then on' do
      respond(thinking('sig-4'), describe_table('call_4', 'users'))
      finish('Really done.')
      ask('one more')

      second_turn, third_turn = bodies[4], bodies[5]
      shared = second_turn['messages'].length - 1 # everything but that turn's question
      expect(without_markers(third_turn['messages'].first(shared)))
        .to eq(without_markers(second_turn['messages'].first(shared)))
    end
  end

  describe 'when what the blocks are bound to changes' do
    it 'drops thinking when the system prompt changes' do
      RailsConsoleAi.configuration.use_builtin_safety_guard(:mailers)
      respond(thinking('sig-1'), describe_table('call_1', 'users'))
      finish
      ask('what columns does users have?')

      RailsConsoleAi.configuration.safety_guards.disable! # safe mode off: the prompt loses its safety section
      finish('Still done.')
      ask('anything else?')

      expect(bodies[2]['system']).not_to eq(bodies[1]['system'])
      expect(signatures(bodies[2])).to eq([])
    end

    it 'drops thinking from a restored session' do
      respond(thinking('sig-1'), describe_table('call_1', 'users'))
      finish
      ask('what columns does users have?')

      stored = engine.instance_variable_get(:@history).to_json
      restored = RailsConsoleAi::ConversationEngine.new(binding_context: console_binding, channel: channel)
      restored.init_interactive
      restored.restore_session(double('session', conversation: stored, id: 1, query: 'q', name: nil,
                                                 input_tokens: 0, output_tokens: 0, duration_ms: 0, model: nil))
      finish('Restored.')
      suppress_output { restored.process_message('carry on') }

      expect(signatures(bodies.last)).to eq([])
      expect(bodies.last['messages'].length).to be > 3
    end
  end

  describe 'when the provider rejects a replayed block' do
    let(:rejection) do
      { status: 400, headers: { 'Content-Type' => 'application/json' },
        body: { type: 'error', error: { type: 'invalid_request_error',
                                        message: 'messages.1.content.0: Invalid `signature` in `thinking` block. ' \
                                                 'The block is bound to a different conversation.' } }.to_json }
    end

    it 'retries once without thinking and stops replaying it for the session' do
      respond(thinking('sig-1'), describe_table('call_1', 'users'))
      responses << rejection
      respond(thinking('sig-2'), describe_table('call_2', 'orders'))
      finish

      ask('compare users and orders')

      expect(signatures(bodies[1])).to eq(%w[sig-1])  # rejected
      expect(signatures(bodies[2])).to eq([])         # the retry
      expect(signatures(bodies[3])).to eq([])         # sig-2 is not replayed either
      expect(channel).to have_received(:display_warning).with(/rejected the replayed thinking/)
      expect(engine.instance_variable_get(:@history).last[:content]).to eq('Done.')
    end

    it 'does not swallow an error that has nothing to do with thinking' do
      respond(thinking('sig-1'), describe_table('call_1', 'users'))
      responses << { status: 400, headers: { 'Content-Type' => 'application/json' },
                     body: { error: { message: 'prompt is too long' } }.to_json }
      # process_message makes one more attempt after a failed turn
      responses << { status: 400, headers: { 'Content-Type' => 'application/json' },
                     body: { error: { message: 'prompt is too long' } }.to_json }

      ask('what columns does users have?')

      expect(channel).to have_received(:display_error).with(/prompt is too long/).at_least(:once)
      expect(channel).not_to have_received(:display_warning).with(/rejected the replayed thinking/)
    end
  end

  describe '/compact' do
    # A signature is about a kilobyte of opaque text per thinking block.
    it 'does not hand thinking signatures to the summarizer' do
      respond(thinking('sig-1'), describe_table('call_1', 'users'))
      respond(thinking('sig-2'), describe_table('call_2', 'orders'))
      finish
      ask('compare users and orders')
      ask_again = -> { finish('Yes.'); ask('sure?') }
      ask_again.call

      respond(text('Summary of the session.'), stop_reason: 'end_turn')
      suppress_output { engine.compact_history }

      summarizer_request = bodies.last.to_json
      expect(summarizer_request).to include('describe_table')
      expect(summarizer_request).not_to include('sig-1')
      expect(engine.history.length).to eq(1)
    end
  end

  describe RailsConsoleAi::Providers::Anthropic do
    subject(:provider) { described_class.new(RailsConsoleAi.configuration) }

    it 'keeps redacted thinking, and drops an empty text block the API would refuse' do
      redacted = { 'type' => 'redacted_thinking', 'data' => 'opaque' }
      respond(redacted, text(''), describe_table('call_1', 'users'))

      result = provider.chat_with_tools([{ role: :user, content: 'hi' }],
                                        tools: RailsConsoleAi::Tools::Registry.new, system_prompt: 'sys')

      expect(provider.format_assistant_message(result)[:content])
        .to eq([redacted, describe_table('call_1', 'users')])
    end

    it 'reports no replay blocks for a turn without thinking' do
      respond(text('hello'), stop_reason: 'end_turn')

      result = provider.chat_with_tools([{ role: :user, content: 'hi' }],
                                        tools: RailsConsoleAi::Tools::Registry.new, system_prompt: 'sys')

      expect(result.content_blocks).to be_nil
    end
  end
end
