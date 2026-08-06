require 'spec_helper'
require 'rails_console_ai/sub_agent'
require 'rails_console_ai/channel/sub_agent'
require 'rails_console_ai/storage/file_storage'
require 'tmpdir'

RSpec.describe RailsConsoleAi::SubAgent do
  let(:tmpdir) { Dir.mktmpdir('rails_console_ai_test') }
  let(:storage) { RailsConsoleAi::Storage::FileStorage.new(tmpdir) }
  let(:binding_context) { Object.new.instance_eval { binding } }
  let(:parent_channel) { instance_double(RailsConsoleAi::Channel::Base, mode: 'slack', user_identity: 'frank', cancelled?: false, supports_danger?: false) }
  let(:executor) { RailsConsoleAi::Executor.new(binding_context, channel: parent_channel) }

  before do
    RailsConsoleAi.configure do |c|
      c.storage_adapter = storage
      c.provider = :anthropic
      c.api_key = 'test-key'
      c.sub_agent_max_rounds = 5
    end
  end

  after { FileUtils.rm_rf(tmpdir) }

  describe '#run' do
    let(:provider) { instance_double(RailsConsoleAi::Providers::Base) }
    let(:chat_result) do
      RailsConsoleAi::Providers::ChatResult.new(
        text: 'User 123 is on shard 5.',
        input_tokens: 100,
        output_tokens: 50,
        stop_reason: :end_turn
      )
    end

    before do
      allow(RailsConsoleAi::Providers).to receive(:build).and_return(provider)
      allow(provider).to receive(:chat_with_tools).and_return(chat_result)
      allow(parent_channel).to receive(:display_status)
    end

    it 'returns the LLM text response' do
      sub = described_class.new(
        task: 'Find user 123 shard',
        agent_config: nil,
        binding_context: binding_context,
        parent_channel: parent_channel,
        executor: executor
      )

      result = sub.run
      expect(result).to eq('User 123 is on shard 5.')
    end

    it 'tracks token usage' do
      sub = described_class.new(
        task: 'Find user 123 shard',
        agent_config: nil,
        binding_context: binding_context,
        parent_channel: parent_channel,
        executor: executor
      )

      sub.run
      expect(sub.input_tokens).to eq(100)
      expect(sub.output_tokens).to eq(50)
    end

    it 'uses agent_config max_rounds when provided' do
      agent_config = { 'name' => 'Test Agent', 'max_rounds' => 2, 'body' => 'Custom instructions.' }

      sub = described_class.new(
        task: 'test',
        agent_config: agent_config,
        binding_context: binding_context,
        parent_channel: parent_channel,
        executor: executor
      )

      # Should use max_rounds from agent_config (2), not global (5)
      # We verify by checking the provider is called at most 2 times
      call_count = 0
      allow(provider).to receive(:chat_with_tools) do
        call_count += 1
        chat_result
      end

      sub.run
      expect(call_count).to be <= 2
    end

    it 'forwards status to parent channel' do
      sub = described_class.new(
        task: 'test',
        agent_config: nil,
        binding_context: binding_context,
        parent_channel: parent_channel,
        executor: executor
      )

      sub.run
      expect(parent_channel).to have_received(:display_status).at_least(:once)
    end

    it 'binds output_payload to a local variable visible to execute_code' do
      payload = 'a' * 5000
      allow(parent_channel).to receive(:display_tool_call)
      allow(parent_channel).to receive(:display_thinking)
      allow(parent_channel).to receive(:display_warning)
      allow(parent_channel).to receive(:display_error)
      allow(parent_channel).to receive(:display_result_output)

      tool_call_result = RailsConsoleAi::Providers::ChatResult.new(
        text: nil,
        input_tokens: 10,
        output_tokens: 5,
        stop_reason: :tool_use,
        tool_calls: [{ id: 'tu1', name: 'execute_code', arguments: { 'code' => 'output.length' } }]
      )
      final_result = RailsConsoleAi::Providers::ChatResult.new(
        text: 'done',
        input_tokens: 10,
        output_tokens: 5,
        stop_reason: :end_turn
      )

      call_count = 0
      observed_messages = []
      allow(provider).to receive(:chat_with_tools) do |msgs, **_kwargs|
        observed_messages << Marshal.load(Marshal.dump(msgs))
        call_count += 1
        call_count == 1 ? tool_call_result : final_result
      end
      allow(provider).to receive(:format_assistant_message).and_return({ role: :assistant, content: [] })
      allow(provider).to receive(:format_tool_result) { |id, content| { role: :tool, tool_use_id: id, content: content } }

      sub = described_class.new(
        task: 'how long is the output?',
        agent_config: { 'tools' => ['execute_code'], 'max_rounds' => 3 },
        binding_context: binding_context,
        parent_channel: parent_channel,
        executor: executor,
        output_payload: payload
      )

      result = sub.run
      expect(result).to eq('done')

      # On the second provider call, the messages should include the execute_code tool result
      # containing the payload's length (5000) — proving `output` was bound.
      second_call_msgs = observed_messages[1]
      expect(second_call_msgs).not_to be_nil, "expected sub-agent to make a second provider call"
      tool_msg = second_call_msgs.last
      expect(tool_msg[:content].to_s).to include('5000')
    end

    it 'does not leak output local back into the parent binding' do
      parent_binding = Object.new.instance_eval { binding }
      parent_executor = RailsConsoleAi::Executor.new(parent_binding, channel: parent_channel)

      allow(provider).to receive(:chat_with_tools).and_return(chat_result)

      sub = described_class.new(
        task: 'noop',
        agent_config: { 'tools' => ['execute_code'], 'max_rounds' => 1 },
        binding_context: parent_binding,
        parent_channel: parent_channel,
        executor: parent_executor,
        output_payload: 'some payload'
      )
      sub.run

      expect(parent_binding.local_variables).not_to include(:output)
    end

    # Bedrock rejects any request whose messages contain toolUse/toolResult
    # blocks unless the request defines toolConfig, so the forced-final-answer
    # call after max_rounds must keep the tool definitions on the request
    # (production error via explore_output / delegate_task: "The toolConfig
    # field must be defined when using toolUse and toolResult content blocks").
    describe 'finalize after exhausting max_rounds' do
      let(:tool_call_result) do
        RailsConsoleAi::Providers::ChatResult.new(
          text: nil,
          input_tokens: 10,
          output_tokens: 5,
          stop_reason: :tool_use,
          tool_calls: [{ id: 'tu1', name: 'execute_code', arguments: { 'code' => '1 + 1' } }]
        )
      end

      before do
        allow(parent_channel).to receive(:display_tool_call)
        allow(parent_channel).to receive(:display_thinking)
        allow(parent_channel).to receive(:display_warning)
        allow(parent_channel).to receive(:display_error)
        allow(parent_channel).to receive(:display_result_output)
        allow(provider).to receive(:format_assistant_message).and_return(
          { role: :assistant, content: [{ 'type' => 'tool_use', 'id' => 'tu1', 'name' => 'execute_code', 'input' => { 'code' => '1 + 1' } }] }
        )
        allow(provider).to receive(:format_tool_result) do |id, content|
          { role: :user, content: [{ 'type' => 'tool_result', 'tool_use_id' => id, 'content' => content }] }
        end
        # The finalize call must not use the no-tools chat: on Bedrock it fails
        # because the transcript contains toolUse/toolResult blocks.
        allow(provider).to receive(:chat) do
          raise RailsConsoleAi::Providers::ProviderError,
            'AWS Bedrock error: The toolConfig field must be defined when using toolUse and toolResult content blocks.'
        end
      end

      def build_sub_agent
        described_class.new(
          task: 'investigate',
          agent_config: { 'tools' => ['execute_code'], 'max_rounds' => 2 },
          binding_context: binding_context,
          parent_channel: parent_channel,
          executor: executor
        )
      end

      it 'finalizes via chat_with_tools over the tool-bearing transcript' do
        final_result = RailsConsoleAi::Providers::ChatResult.new(
          text: 'Best answer from what I learned.', input_tokens: 10, output_tokens: 5, stop_reason: :end_turn
        )
        observed_messages = []
        allow(provider).to receive(:chat_with_tools) do |msgs, **_kwargs|
          observed_messages << Marshal.load(Marshal.dump(msgs))
          msgs.last[:content].to_s.include?('best answer now') ? final_result : tool_call_result
        end

        result = build_sub_agent.run
        expect(result).to eq('Best answer from what I learned.')

        finalize_msgs = observed_messages.last
        expect(finalize_msgs.last[:content]).to include('best answer now')
        # The transcript sent to the finalize call still contains tool_use
        # blocks — the exact shape Bedrock rejects without toolConfig.
        tool_use_msgs = finalize_msgs.select do |m|
          m[:content].is_a?(Array) && m[:content].any? { |b| b['type'] == 'tool_use' }
        end
        expect(tool_use_msgs).not_to be_empty
      end

      it 'takes the text and ignores tool calls if the finalize response still tries to use tools' do
        finalize_with_tools = RailsConsoleAi::Providers::ChatResult.new(
          text: 'Partial answer.',
          input_tokens: 10,
          output_tokens: 5,
          stop_reason: :tool_use,
          tool_calls: [{ id: 'tu_final', name: 'execute_code', arguments: { 'code' => 'one_more' } }]
        )
        allow(provider).to receive(:chat_with_tools) do |msgs, **_kwargs|
          msgs.last[:content].to_s.include?('best answer now') ? finalize_with_tools : tool_call_result
        end

        expect(build_sub_agent.run).to eq('Partial answer.')
      end

      it 'returns a placeholder when the finalize response has no text' do
        empty_finalize = RailsConsoleAi::Providers::ChatResult.new(
          text: '',
          input_tokens: 10,
          output_tokens: 5,
          stop_reason: :tool_use,
          tool_calls: [{ id: 'tu_final', name: 'execute_code', arguments: { 'code' => 'one_more' } }]
        )
        allow(provider).to receive(:chat_with_tools) do |msgs, **_kwargs|
          msgs.last[:content].to_s.include?('best answer now') ? empty_finalize : tool_call_result
        end

        expect(build_sub_agent.run).to eq('(sub-agent returned no result)')
      end
    end

    it 'includes agent body in system prompt' do
      agent_config = { 'name' => 'Find shard', 'body' => 'Check user.shard column.' }

      sub = described_class.new(
        task: 'test',
        agent_config: agent_config,
        binding_context: binding_context,
        parent_channel: parent_channel,
        executor: executor
      )

      allow(provider).to receive(:chat_with_tools) do |_messages, tools:, system_prompt:|
        expect(system_prompt).to include('Check user.shard column.')
        chat_result
      end

      sub.run
    end
  end

  describe '#build_system_prompt' do
    def prompt_for(agent_config)
      described_class.new(
        task: 'test',
        agent_config: agent_config,
        binding_context: binding_context,
        parent_channel: parent_channel,
        executor: executor
      ).send(:build_system_prompt)
    end

    it 'includes base_instructions by default' do
      expect(prompt_for('name' => 'Investigator', 'body' => 'do a thing'))
        .to include('Prefer ActiveRecord query interface')
    end

    it 'omits base_instructions when skip_base_instructions is set' do
      expect(prompt_for('name' => 'x', 'skip_base_instructions' => true, 'body' => 'do a thing'))
        .not_to include('Prefer ActiveRecord query interface')
    end

    it 'the output-explorer config skips base_instructions and forbids DB access' do
      prompt = prompt_for(RailsConsoleAi::Tools::Registry::EXPLORE_OUTPUT_AGENT_CONFIG)
      expect(prompt).not_to include('Prefer ActiveRecord query interface')
      expect(prompt).to include('Database / ActiveRecord access is DISABLED')
    end
  end
end

RSpec.describe RailsConsoleAi::Channel::SubAgent do
  let(:parent_channel) { instance_double(RailsConsoleAi::Channel::Base, mode: 'slack', user_identity: 'frank', cancelled?: false, supports_danger?: false) }

  subject(:channel) { described_class.new(parent_channel: parent_channel, task_label: 'Find shard') }

  before do
    allow(parent_channel).to receive(:display_status)
    allow(parent_channel).to receive(:display_thinking)
    allow(parent_channel).to receive(:display_tool_call)
    allow(parent_channel).to receive(:display_warning)
    allow(parent_channel).to receive(:display_error)
    allow(parent_channel).to receive(:display_result_output)
  end

  it 'forwards thinking to parent' do
    channel.display_thinking('Let me check the model...')
    expect(parent_channel).to have_received(:display_thinking).with('Let me check the model...')
  end

  it 'forwards status to parent' do
    channel.display_status('some status')
    expect(parent_channel).to have_received(:display_status).with('some status')
  end

  it 'forwards tool calls to parent' do
    channel.display_tool_call('search_code("reschedule_fee")')
    expect(parent_channel).to have_received(:display_tool_call).with('search_code("reschedule_fee")')
  end

  it 'auto-confirms everything' do
    expect(channel.confirm('Run code?')).to eq('y')
  end

  it 'returns cannot-ask message for prompt' do
    expect(channel.prompt('What user?')).to eq('(sub-agent cannot ask user)')
  end

  it 'delegates cancelled? to parent' do
    allow(parent_channel).to receive(:cancelled?).and_return(true)
    expect(channel.cancelled?).to be true
  end

  it 'reports mode as sub_agent' do
    expect(channel.mode).to eq('sub_agent')
  end

  it 'delegates user_identity to parent' do
    expect(channel.user_identity).to eq('frank')
  end

  it 'swallows display and display_result' do
    expect { channel.display('hello') }.not_to raise_error
    expect { channel.display_code('code') }.not_to raise_error
    expect { channel.display_result('result') }.not_to raise_error
    # These should NOT have been forwarded to parent
    expect(parent_channel).not_to have_received(:display_status)
  end

  it 'forwards warnings and errors to parent' do
    channel.display_warning('watch out')
    channel.display_error('something broke')
    expect(parent_channel).to have_received(:display_warning).with('watch out')
    expect(parent_channel).to have_received(:display_error).with('something broke')
  end
end
