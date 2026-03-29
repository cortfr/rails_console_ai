require_relative 'spec_helper'

RSpec.describe 'Sub-agent integration' do
  include IntegrationHelpers

  before(:each) do
    skip 'ANTHROPIC_API_KEY not set — run with ANTHROPIC_API_KEY=sk-... to enable' unless ENV['ANTHROPIC_API_KEY']
    RailsConsoleAi.reset_configuration!
  end

  let(:tmpdir) { Dir.mktmpdir('rails_console_ai_llm_test') }
  let(:storage) { RailsConsoleAi::Storage::FileStorage.new(tmpdir) }

  after { FileUtils.rm_rf(tmpdir) }

  describe 'delegate_task tool' do
    it 'LLM calls delegate_task when instructed', :slow do
      # Create a custom agent
      storage.write('agents/find-shard.md', <<~MD)
        ---
        name: Find shard
        description: Given a user ID, determines which database shard they are on
        max_rounds: 3
        ---

        Report that user 123 is on shard 5. Do not use any tools. Just respond with the answer.
      MD

      channel = IntegrationHelpers::CaptureChannel.new
      engine = build_engine(storage: storage, channel: channel)

      engine.add_user_message(
        'I need to know which shard user 123 is on. ' \
        'Use the delegate_task tool with the "Find shard" agent to find out. ' \
        'Do not try to answer directly.'
      )
      engine.send_and_execute

      tools_called = tool_names_called(channel)
      expect(tools_called).to include('delegate_task'),
        "Expected LLM to call delegate_task, but it called: #{tools_called.inspect}\n" \
        "Final output: #{channel.messages.last(3).inspect}"
    end
  end

  describe 'sub-agent execution' do
    it 'sub-agent runs code and returns summary' do
      channel = IntegrationHelpers::CaptureChannel.new
      binding_context = Object.new.instance_eval { binding }
      executor = RailsConsoleAi::Executor.new(binding_context, channel: channel)

      RailsConsoleAi.configure do |c|
        c.provider = :anthropic
        c.api_key = ENV['ANTHROPIC_API_KEY']
        c.model = 'claude-sonnet-4-6'
        c.temperature = 0.0
        c.storage_adapter = storage
        c.sub_agent_max_rounds = 5
      end

      sub = RailsConsoleAi::SubAgent.new(
        task: 'What is 2 + 2? Use the execute_code tool to compute it, then report the answer.',
        agent_config: { 'name' => 'Math', 'max_rounds' => 5 },
        binding_context: binding_context,
        parent_channel: channel,
        executor: executor
      )

      result = sub.run

      expect(result).to include('4'),
        "Expected sub-agent to compute 2+2=4, got: #{result}"
      expect(sub.input_tokens).to be > 0
      expect(sub.output_tokens).to be > 0
      expect(sub.model_used).not_to be_nil
    end
  end

  describe 'tool restrictions' do
    it 'sub-agent with limited tools only uses allowed tools' do
      channel = IntegrationHelpers::CaptureChannel.new
      binding_context = Object.new.instance_eval { binding }
      executor = RailsConsoleAi::Executor.new(binding_context, channel: channel)

      RailsConsoleAi.configure do |c|
        c.provider = :anthropic
        c.api_key = ENV['ANTHROPIC_API_KEY']
        c.model = 'claude-sonnet-4-6'
        c.temperature = 0.0
        c.storage_adapter = storage
        c.sub_agent_max_rounds = 5
      end

      sub = RailsConsoleAi::SubAgent.new(
        task: 'What is 3 * 7? Use execute_code to compute it.',
        agent_config: {
          'name' => 'Limited',
          'max_rounds' => 5,
          'tools' => ['execute_code']
        },
        binding_context: binding_context,
        parent_channel: channel,
        executor: executor
      )

      result = sub.run

      expect(result).to include('21'),
        "Expected sub-agent to compute 3*7=21, got: #{result}"

      # Verify only execute_code was called (filter out sub-agent status prefixes)
      sub_agent_tools = channel.tool_calls
        .select { |tc| tc.include?('[sub-agent') || !tc.start_with?(' ') }
        .map { |tc| tc.sub(/.*-> /, '').split('(').first }
        .reject(&:empty?)

      disallowed = sub_agent_tools - ['execute_code']
      expect(disallowed).to be_empty,
        "Sub-agent called disallowed tools: #{disallowed.inspect}"
    end
  end

  describe 'custom agent instructions' do
    it 'sub-agent follows custom body instructions' do
      channel = IntegrationHelpers::CaptureChannel.new
      binding_context = Object.new.instance_eval { binding }
      executor = RailsConsoleAi::Executor.new(binding_context, channel: channel)

      RailsConsoleAi.configure do |c|
        c.provider = :anthropic
        c.api_key = ENV['ANTHROPIC_API_KEY']
        c.model = 'claude-sonnet-4-6'
        c.temperature = 0.0
        c.storage_adapter = storage
        c.sub_agent_max_rounds = 3
      end

      sub = RailsConsoleAi::SubAgent.new(
        task: 'Report the magic number.',
        agent_config: {
          'name' => 'Magic Number',
          'max_rounds' => 3,
          'body' => 'The magic number is always 42. When asked, respond with exactly: "The magic number is 42." Do not use any tools.'
        },
        binding_context: binding_context,
        parent_channel: channel,
        executor: executor
      )

      result = sub.run

      expect(result).to include('42'),
        "Expected sub-agent to follow instructions and report 42, got: #{result}"
    end
  end

  describe 'guide context' do
    it 'sub-agent can access the application guide' do
      storage.write(RailsConsoleAi::GUIDE_KEY, <<~GUIDE)
        # Test App Guide
        This application uses a BAZINGA_CODE of "XJ-42" for all API authentication.
      GUIDE

      channel = IntegrationHelpers::CaptureChannel.new
      binding_context = Object.new.instance_eval { binding }
      executor = RailsConsoleAi::Executor.new(binding_context, channel: channel)

      RailsConsoleAi.configure do |c|
        c.provider = :anthropic
        c.api_key = ENV['ANTHROPIC_API_KEY']
        c.model = 'claude-sonnet-4-6'
        c.temperature = 0.0
        c.storage_adapter = storage
        c.sub_agent_max_rounds = 3
      end

      sub = RailsConsoleAi::SubAgent.new(
        task: 'What is the BAZINGA_CODE used for API authentication? Answer from your context only, do not use tools.',
        agent_config: { 'name' => 'Guide test', 'max_rounds' => 3 },
        binding_context: binding_context,
        parent_channel: channel,
        executor: executor
      )

      result = sub.run

      expect(result).to include('XJ-42'),
        "Expected sub-agent to find BAZINGA_CODE from guide, got: #{result}"
    end
  end
end
