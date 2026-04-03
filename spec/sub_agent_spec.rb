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
