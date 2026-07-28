require 'spec_helper'
require 'rails_console_ai/executor'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/context_builder'
require 'rails_console_ai/conversation_engine'
require 'rails_console_ai/session_logger'

# Session-row status lifecycle (missing-session incident): the row must be
# created with status 'running' BEFORE the tool loop starts, so a turn that
# hangs or dies mid-loop still leaves a visible record, and must end 'ready'
# on success / 'failed' on error.
RSpec.describe RailsConsoleAi::ConversationEngine, 'session status tracking' do
  let(:events) { [] }

  class FakeAnswerNowProvider
    def initialize(events)
      @events = events
    end

    def chat_with_tools(_messages, tools:, system_prompt:)
      @events << [:provider_call, nil]
      RailsConsoleAi::Providers::ChatResult.new(
        text: 'All done.', input_tokens: 10, output_tokens: 5, stop_reason: :end_turn
      )
    end

    def chat(messages, system_prompt: nil)
      RailsConsoleAi::Providers::ChatResult.new(
        text: 'Final.', input_tokens: 1, output_tokens: 1, stop_reason: :end_turn
      )
    end

    def format_assistant_message(result)
      { role: :assistant, content: result.text }
    end

    def format_tool_result(tool_call_id, result_string)
      { role: :tool, tool_call_id: tool_call_id, content: result_string }
    end
  end

  let(:channel) do
    ch = double('channel').as_null_object
    allow(ch).to receive(:mode).and_return('slack')
    allow(ch).to receive(:user_identity).and_return('jess')
    allow(ch).to receive(:cancelled?).and_return(false)
    allow(ch).to receive(:supports_danger?).and_return(false)
    allow(ch).to receive(:wrap_llm_call) { |&b| b.call }
    # `display` is a real Kernel method, so as_null_object doesn't intercept it
    allow(ch).to receive(:display)
    ch
  end
  let(:test_binding) { Object.new.instance_eval { binding } }
  subject(:engine) { described_class.new(binding_context: test_binding, channel: channel) }

  before do
    RailsConsoleAi.configure do |c|
      c.provider = :anthropic
      c.api_key = 'test-key'
      c.session_logging = true
    end

    allow(RailsConsoleAi::SessionLogger).to receive(:log) do |attrs|
      events << [:create, attrs[:status]]
      42
    end
    allow(RailsConsoleAi::SessionLogger).to receive(:update) do |_id, attrs|
      events << [:update, attrs[:status]]
      nil
    end
  end

  def install_provider(provider)
    engine.instance_variable_set(:@provider, provider)
  end

  describe 'successful turn' do
    it 'creates the session row with status running before the provider is called' do
      install_provider(FakeAnswerNowProvider.new(events))
      engine.process_message('what happened to the sync?')

      expect(events.first).to eq([:create, 'running'])
      expect(events.index([:provider_call, nil])).to be > events.index([:create, 'running'])
    end

    it 'marks the session ready when the turn completes' do
      install_provider(FakeAnswerNowProvider.new(events))
      engine.process_message('what happened to the sync?')

      expect(events.last).to eq([:update, 'ready'])
    end
  end

  describe 'provider failure' do
    it 'marks the session failed after retries are exhausted' do
      provider = double('provider')
      allow(provider).to receive(:chat_with_tools) do
        events << [:provider_call, nil]
        raise RailsConsoleAi::Providers::ProviderError, 'boom'
      end
      install_provider(provider)

      engine.process_message('what happened?')

      expect(events.first).to eq([:create, 'running'])
      expect(events.last).to eq([:update, 'failed'])
    end
  end

  describe 'unexpected crash mid-turn' do
    it 'marks the session failed and re-raises' do
      provider = double('provider')
      allow(provider).to receive(:chat_with_tools).and_raise(RuntimeError, 'segfault-adjacent')
      install_provider(provider)

      expect { engine.process_message('what happened?') }.to raise_error(RuntimeError)
      expect(events.first).to eq([:create, 'running'])
      expect(events.last).to eq([:update, 'failed'])
    end
  end

  describe 'a turn that never finishes (hang / kill simulation)' do
    it 'has already persisted the running row before execution starts' do
      # Simulate the incident: the "process" dies inside the tool loop.
      # Thread.kill-style death runs no rescue blocks, so the only record
      # that survives is whatever was written before the loop began.
      provider = double('provider')
      allow(provider).to receive(:chat_with_tools).and_throw(:process_died)
      install_provider(provider)

      catch(:process_died) { engine.process_message('run the thing') }
      expect(events).to include([:create, 'running'])
    end
  end

  describe 'direct code execution' do
    it 'creates a running row before eval and marks ready after' do
      engine.init_interactive
      engine.execute_direct('1 + 1')

      expect(events.first).to eq([:create, 'running'])
      expect(events.last).to eq([:update, 'ready'])
    end
  end
end
