require 'spec_helper'
require 'json'
require 'rails_console_ai/session_logger'

RSpec.describe RailsConsoleAi::SessionLogger do
  let(:mock_connection) { double('connection') }
  let(:mock_session) { double('SessionClass') }

  before do
    stub_const('RailsConsoleAi::Session', mock_session)
    allow(mock_connection).to receive(:table_exists?).with('rails_console_ai_sessions').and_return(true)
    allow(mock_session).to receive(:connection).and_return(mock_connection)
    allow(mock_session).to receive(:create!)

    # Reset memoized table_exists between tests
    described_class.instance_variable_set(:@table_exists, nil)
  end

  after do
    described_class.instance_variable_set(:@table_exists, nil)
  end

  describe '.log' do
    let(:attrs) do
      {
        query: 'show all tables',
        conversation: [{ role: :user, content: 'show all tables' }],
        mode: 'one_shot',
        input_tokens: 100,
        output_tokens: 50,
        executed: true,
        code_executed: 'Table.all',
        code_output: 'some output',
        code_result: '[#<Table>]',
        duration_ms: 1234
      }
    end

    it 'creates a Session record with the given attributes' do
      described_class.log(attrs)

      expect(mock_session).to have_received(:create!).with(
        hash_including(
          query: 'show all tables',
          mode: 'one_shot',
          input_tokens: 100,
          output_tokens: 50,
          executed: true,
          code_executed: 'Table.all'
        )
      )
    end

    it 'returns nil when session_logging is disabled' do
      RailsConsoleAi.configure { |c| c.session_logging = false }

      described_class.log(attrs)
      expect(mock_session).not_to have_received(:create!)
    end

    it 'returns nil when table does not exist' do
      described_class.instance_variable_set(:@table_exists, nil)
      allow(mock_connection).to receive(:table_exists?).with('rails_console_ai_sessions').and_return(false)

      result = described_class.log(attrs)
      expect(result).to be_nil
      expect(mock_session).not_to have_received(:create!)
    end

    it 'rescues errors and logs a warning' do
      allow(mock_session).to receive(:create!).and_raise(StandardError, 'db error')
      logger = double('Logger')
      allow(RailsConsoleAi).to receive(:logger).and_return(logger)
      allow(logger).to receive(:warn)

      expect(described_class.log(attrs)).to be_nil
      expect(logger).to have_received(:warn).with(/session logging failed/)
    end

    it 'serializes conversation as JSON' do
      described_class.log(attrs)

      expect(mock_session).to have_received(:create!) do |params|
        parsed = JSON.parse(params[:conversation])
        expect(parsed).to be_an(Array)
        expect(parsed.first['role']).to eq('user')
      end
    end

    it 'uses ENV["USER"] for user_name' do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('USER').and_return('devuser')

      described_class.log(attrs)

      expect(mock_session).to have_received(:create!).with(
        hash_including(user_name: 'devuser')
      )
    end

    it 'includes provider and model from configuration' do
      RailsConsoleAi.configure do |c|
        c.provider = :openai
        c.model = 'gpt-4'
      end

      described_class.log(attrs)

      expect(mock_session).to have_received(:create!).with(
        hash_including(provider: 'openai', model: 'gpt-4')
      )
    end

    it 'returns the record id' do
      record = double('record', id: 42)
      allow(mock_session).to receive(:create!).and_return(record)

      result = described_class.log(attrs)
      expect(result).to eq(42)
    end

    it 'passes name when provided' do
      described_class.log(attrs.merge(name: 'my_session'))

      expect(mock_session).to have_received(:create!).with(
        hash_including(name: 'my_session')
      )
    end

    it 'passes nil name when not provided' do
      described_class.log(attrs)

      expect(mock_session).to have_received(:create!).with(
        hash_including(name: nil)
      )
    end
  end

  describe '.update' do
    let(:mock_relation) { double('relation') }

    before do
      allow(mock_session).to receive(:where).with(id: 42).and_return(mock_relation)
      allow(mock_relation).to receive(:update_all)
    end

    it 'updates the session record with given attributes' do
      described_class.update(42,
        conversation: [{ role: :user, content: 'hello' }],
        input_tokens: 200,
        output_tokens: 100
      )

      expect(mock_relation).to have_received(:update_all).with(
        hash_including(input_tokens: 200, output_tokens: 100)
      )
    end

    it 'serializes conversation as JSON' do
      described_class.update(42, conversation: [{ role: :user, content: 'hi' }])

      expect(mock_relation).to have_received(:update_all) do |params|
        parsed = JSON.parse(params[:conversation])
        expect(parsed.first['role']).to eq('user')
      end
    end

    it 'sets duration_ms on finish' do
      described_class.update(42, duration_ms: 5000)

      expect(mock_relation).to have_received(:update_all).with(
        hash_including(duration_ms: 5000)
      )
    end

    it 'does nothing when id is nil' do
      described_class.update(nil, input_tokens: 100)
      expect(mock_session).not_to have_received(:where)
    end

    it 'does nothing when session_logging is disabled' do
      RailsConsoleAi.configure { |c| c.session_logging = false }
      described_class.update(42, input_tokens: 100)
      expect(mock_session).not_to have_received(:where)
    end

    it 'updates name when provided' do
      described_class.update(42, name: 'renamed_session')

      expect(mock_relation).to have_received(:update_all).with(
        hash_including(name: 'renamed_session')
      )
    end

    it 'rescues errors and logs a warning' do
      allow(mock_session).to receive(:where).and_raise(StandardError, 'db error')
      logger = double('Logger')
      allow(RailsConsoleAi).to receive(:logger).and_return(logger)
      allow(logger).to receive(:warn)

      expect(described_class.update(42, input_tokens: 100)).to be_nil
      expect(logger).to have_received(:warn).with(/session update failed/)
    end
  end
end
