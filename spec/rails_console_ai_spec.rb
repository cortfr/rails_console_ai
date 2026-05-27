require 'spec_helper'
require 'rails_console_ai/session_logger'

RSpec.describe RailsConsoleAi do
  describe '.configuration' do
    it 'returns a Configuration instance' do
      expect(RailsConsoleAi.configuration).to be_a(RailsConsoleAi::Configuration)
    end

    it 'returns the same instance on repeated calls' do
      expect(RailsConsoleAi.configuration).to equal(RailsConsoleAi.configuration)
    end
  end

  describe '.configure' do
    it 'yields the configuration object' do
      RailsConsoleAi.configure do |config|
        config.provider = :openai
        config.max_tokens = 2048
      end

      expect(RailsConsoleAi.configuration.provider).to eq(:openai)
      expect(RailsConsoleAi.configuration.max_tokens).to eq(2048)
    end
  end

  describe '.reset_configuration!' do
    it 'creates a fresh configuration' do
      RailsConsoleAi.configure { |c| c.provider = :openai }
      RailsConsoleAi.reset_configuration!
      expect(RailsConsoleAi.configuration.provider).to eq(:anthropic)
    end
  end

  describe 'background agent API' do
    let(:mock_session_class) { double('SessionClass') }
    let(:mock_relation)      { double('Relation') }

    before do
      stub_const('RailsConsoleAi::Session', mock_session_class)
    end

    describe '.run_agent' do
      it 'enqueues a Session row with status=queued, mode=agent_api and returns the id' do
        expect(RailsConsoleAi::SessionLogger).to receive(:log).with(
          hash_including(
            query: 'how many users?',
            mode: 'agent_api',
            status: 'queued',
            executed: false,
            name: 'smoke',
            user_name: 'cli'
          )
        ).and_return(123)

        expect(RailsConsoleAi.run_agent('how many users?', name: 'smoke', user_name: 'cli')).to eq(123)
      end

      it 'raises when SessionLogger returns nil (table missing / logging disabled)' do
        allow(RailsConsoleAi::SessionLogger).to receive(:log).and_return(nil)
        expect { RailsConsoleAi.run_agent('hi') }.to raise_error(/Failed to enqueue/)
      end
    end

    describe '.check_agent' do
      it 'returns the status of the matching session' do
        allow(mock_session_class).to receive(:where).with(id: 42).and_return(mock_relation)
        allow(mock_relation).to receive(:pluck).with(:status).and_return(['running'])

        expect(RailsConsoleAi.check_agent(42)).to eq('running')
      end

      it 'returns nil when no session is found' do
        allow(mock_session_class).to receive(:where).with(id: 99).and_return(mock_relation)
        allow(mock_relation).to receive(:pluck).with(:status).and_return([])

        expect(RailsConsoleAi.check_agent(99)).to be_nil
      end
    end

    describe '.get_agent_response' do
      it 'returns status/result/error from the matching session' do
        row = double('row', status: 'ready', result: 'the answer is 42', error_message: nil)
        allow(mock_session_class).to receive(:where).with(id: 42).and_return(mock_relation)
        allow(mock_relation).to receive(:select).with(:status, :result, :error_message).and_return(mock_relation)
        allow(mock_relation).to receive(:first).and_return(row)

        expect(RailsConsoleAi.get_agent_response(42)).to eq(
          status: 'ready', result: 'the answer is 42', error: nil
        )
      end

      it 'returns a hash with nil values when no session is found' do
        allow(mock_session_class).to receive(:where).with(id: 99).and_return(mock_relation)
        allow(mock_relation).to receive(:select).with(:status, :result, :error_message).and_return(mock_relation)
        allow(mock_relation).to receive(:first).and_return(nil)

        expect(RailsConsoleAi.get_agent_response(99)).to eq(
          status: nil, result: nil, error: nil
        )
      end
    end
  end
end
