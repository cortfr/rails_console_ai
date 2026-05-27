require 'spec_helper'
require 'rails_console_ai/executor'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/conversation_engine'
require 'rails_console_ai/session_logger'

# Focused on the existing_session_id routing in one_shot — when supplied,
# log_session must call SessionLogger.update (NOT .log), so the row created
# by RailsConsoleAi.run_agent is the same one updated with the result.
RSpec.describe RailsConsoleAi::ConversationEngine, 'one_shot routing' do
  let(:channel) do
    double('channel',
      mode: 'api',
      user_identity: 'cli',
      system_instructions: nil,
      cancelled?: false,
      wrap_llm_call: nil
    )
  end
  let(:test_binding) { Object.new.instance_eval { binding } }
  subject(:engine) { described_class.new(binding_context: test_binding, channel: channel) }

  before do
    RailsConsoleAi.configure do |c|
      c.provider = :anthropic
      c.api_key = 'test-key'
      c.session_logging = true
    end

    # Stub the LLM round so we don't talk to the network and exec nothing
    allow(engine).to receive(:one_shot_round).and_return([nil, nil, false])
    engine.instance_variable_set(:@_last_result_text, 'final answer')
    # Bypass channel.wrap_llm_call (only used by send_query, which we skip)
    allow(channel).to receive(:wrap_llm_call) { |&block| block.call }
  end

  it 'updates the existing session row when existing_session_id is given' do
    expect(RailsConsoleAi::SessionLogger).to receive(:update).with(
      42,
      hash_including(mode: 'one_shot', query: 'hi')
    )
    expect(RailsConsoleAi::SessionLogger).not_to receive(:log)

    engine.one_shot('hi', existing_session_id: 42)
  end

  it 'logs a new session row when no existing_session_id is given' do
    expect(RailsConsoleAi::SessionLogger).to receive(:log).with(
      hash_including(mode: 'one_shot', query: 'hi')
    )
    expect(RailsConsoleAi::SessionLogger).not_to receive(:update)

    engine.one_shot('hi')
  end
end
