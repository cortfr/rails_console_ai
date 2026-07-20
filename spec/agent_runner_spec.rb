require 'spec_helper'
require 'rails_console_ai/agent_runner'

RSpec.describe RailsConsoleAi::AgentRunner do
  let(:runner) { described_class.new(concurrency: 2, poll_interval: 0.01) }

  let(:mock_session_class) { class_double('RailsConsoleAi::Session') }
  let(:queued_scope)       { double('queued_scope') }
  let(:claim_scope)        { double('claim_scope') }

  before do
    stub_const('RailsConsoleAi::Session', mock_session_class)
  end

  describe '#claim_next (atomic claim)' do
    let(:session) { double('Session', id: 7, query: 'hello', user_name: 'cli') }

    before do
      allow(mock_session_class).to receive(:where).with(mode: 'agent_api', status: 'queued').and_return(queued_scope)
      allow(queued_scope).to receive(:order).with(:created_at).and_return(queued_scope)
      allow(queued_scope).to receive(:limit).and_return(queued_scope)
      allow(queued_scope).to receive(:pluck).with(:id).and_return([7])
    end

    it 'claims a row when the atomic update affects 1 row' do
      allow(mock_session_class).to receive(:where).with(id: 7, status: 'queued', mode: 'agent_api').and_return(claim_scope)
      allow(claim_scope).to receive(:update_all).with(status: 'running').and_return(1)
      allow(mock_session_class).to receive(:find).with(7).and_return(session)

      result = runner.send(:claim_next, 5)
      expect(result).to eq([session])
    end

    it 'skips rows lost to a racing runner (update_all returns 0)' do
      allow(mock_session_class).to receive(:where).with(id: 7, status: 'queued', mode: 'agent_api').and_return(claim_scope)
      allow(claim_scope).to receive(:update_all).with(status: 'running').and_return(0)
      allow(mock_session_class).to receive(:find)

      result = runner.send(:claim_next, 5)
      expect(result).to be_empty
      expect(mock_session_class).not_to have_received(:find)
    end

    it 'filters strictly on mode=agent_api AND status=queued (legacy one_shot rows invisible)' do
      # When no candidates come back, the runner never issues the per-row claim UPDATE.
      allow(queued_scope).to receive(:pluck).with(:id).and_return([])

      runner.send(:claim_next, 5)
      expect(mock_session_class).to have_received(:where).with(mode: 'agent_api', status: 'queued')
    end
  end

  describe '#run_one' do
    let(:session) { double('Session', id: 11, query: 'how many users?', user_name: 'cli') }
    let(:captured_channel) { instance_double(RailsConsoleAi::Channel::Api, captured_output: "Let me query the users table.\n") }
    let(:engine) { instance_double(RailsConsoleAi::ConversationEngine) }
    let(:abort_scope) { double('abort_scope') }

    before do
      require 'rails_console_ai/channel/api'
      require 'rails_console_ai/conversation_engine'
      allow(RailsConsoleAi::Channel::Api).to receive(:new).and_return(captured_channel)
      allow(RailsConsoleAi::ConversationEngine).to receive(:new).and_return(engine)
      # aborted? polls the row's status mid-run; report "not aborted" by default.
      allow(mock_session_class).to receive(:where).with(id: 11).and_return(abort_scope)
      allow(abort_scope).to receive(:pluck).with(:status).and_return(['running'])
    end

    it 'composes the result from LLM prose + the code return value' do
      allow(engine).to receive(:one_shot).with('how many users?', existing_session_id: 11).and_return(42)
      expect(RailsConsoleAi::SessionLogger).to receive(:update).with(11,
        status: 'ready',
        result: "Let me query the users table.\n\nResult: 42\n"
      )

      runner.send(:run_one, session)
    end

    it 'omits the Result line when one_shot returns nil (no code executed)' do
      allow(engine).to receive(:one_shot).and_return(nil)
      expect(RailsConsoleAi::SessionLogger).to receive(:update).with(11,
        status: 'ready',
        result: "Let me query the users table.\n"
      )

      runner.send(:run_one, session)
    end

    it 'marks the row failed with an error_message when one_shot raises' do
      allow(engine).to receive(:one_shot).and_raise(RuntimeError, 'boom')
      allow(RailsConsoleAi.logger).to receive(:error)

      expect(RailsConsoleAi::SessionLogger).to receive(:update).with(11,
        hash_including(status: 'failed', error_message: /RuntimeError: boom/)
      )

      runner.send(:run_one, session)
    end
  end

  describe '#drain' do
    it 'marks still-running jobs as failed on hard stop' do
      runner.instance_variable_set(:@threads, { 5 => double('thread', alive?: false) })
      # First reap clears the dead thread, leaving none stuck.
      expect(RailsConsoleAi::SessionLogger).not_to receive(:update)
      runner.send(:drain)
    end

    it 'fails sessions whose threads remain alive past the drain deadline' do
      stub_const('RailsConsoleAi::AgentRunner::DRAIN_TIMEOUT', 0)
      live_thread = double('thread', alive?: true)
      runner.instance_variable_set(:@threads, { 9 => live_thread })

      expect(RailsConsoleAi::SessionLogger).to receive(:update).with(9,
        status: 'failed',
        error_message: 'Runner shut down before completion'
      )

      runner.send(:drain)
    end
  end
end
