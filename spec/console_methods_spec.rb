require 'spec_helper'
require 'console_agent/console_methods'

RSpec.describe ConsoleAgent::ConsoleMethods do
  let(:test_class) { Class.new { include ConsoleAgent::ConsoleMethods } }
  let(:instance) { test_class.new }

  describe '#ai_sessions' do
    let(:mock_session_class) { double('SessionClass') }
    let(:mock_scope) { double('scope') }

    before do
      stub_const('ConsoleAgent::Session', mock_session_class)
      allow(mock_session_class).to receive(:recent).and_return(mock_scope)
      allow(mock_scope).to receive(:limit).and_return([])
      allow(mock_scope).to receive(:search).and_return(mock_scope)
    end

    it 'lists recent sessions' do
      session = double('session',
        id: 1,
        name: 'my_session',
        query: 'find user',
        mode: 'interactive',
        created_at: Time.now - 300,
        input_tokens: 100,
        output_tokens: 50
      )
      allow(mock_scope).to receive(:limit).with(10).and_return([session])

      output = capture_stdout { instance.ai_sessions }
      expect(output).to include('#1')
      expect(output).to include('my_session')
      expect(output).to include('ai_resume')
    end

    it 'shows message when no sessions found' do
      output = capture_stdout { instance.ai_sessions }
      expect(output).to include('No sessions found')
    end

    it 'filters by search term' do
      allow(mock_scope).to receive(:limit).with(10).and_return([])

      instance.ai_sessions(10, search: 'salesforce')
      expect(mock_scope).to have_received(:search).with('salesforce')
    end

    it 'limits results by n parameter' do
      instance.ai_sessions(5)
      expect(mock_scope).to have_received(:limit).with(5)
    end
  end

  describe '#ai_resume' do
    let(:mock_session_class) { double('SessionClass') }
    let(:mock_repl) { instance_double('ConsoleAgent::Repl') }

    before do
      stub_const('ConsoleAgent::Session', mock_session_class)
      allow(ConsoleAgent).to receive(:current_user).and_return('testuser')
      allow(ConsoleAgent::Repl).to receive(:new).and_return(mock_repl)
      allow(mock_repl).to receive(:resume)
    end

    it 'finds session by integer id' do
      session = double('session', id: 42)
      allow(mock_session_class).to receive(:find_by).with(id: 42).and_return(session)

      instance.ai_resume(42)
      expect(mock_repl).to have_received(:resume).with(session)
    end

    it 'finds session by name' do
      session = double('session', id: 42)
      name_scope = double('name_scope')
      allow(mock_session_class).to receive(:where).with(name: 'sf_user_123').and_return(name_scope)
      allow(name_scope).to receive(:recent).and_return(name_scope)
      allow(name_scope).to receive(:first).and_return(session)

      instance.ai_resume('sf_user_123')
      expect(mock_repl).to have_received(:resume).with(session)
    end

    it 'shows error when session not found' do
      allow(mock_session_class).to receive(:find_by).with(id: 999).and_return(nil)

      output = capture_stderr { instance.ai_resume(999) }
      expect(output).to include('Session not found')
    end
  end

  describe '#ai_name' do
    let(:mock_session_class) { double('SessionClass') }

    before do
      stub_const('ConsoleAgent::Session', mock_session_class)
      # Stub SessionLogger dependencies
      allow(mock_session_class).to receive(:connection).and_return(
        double('connection', table_exists?: true)
      )
    end

    it 'names a session by id' do
      session = double('session', id: 42)
      allow(mock_session_class).to receive(:find_by).with(id: 42).and_return(session)
      allow(ConsoleAgent::SessionLogger).to receive(:update)

      # Reset table_exists cache
      ConsoleAgent::SessionLogger.instance_variable_set(:@table_exists, nil)

      output = capture_stdout { instance.ai_name(42, 'new_name') }
      expect(output).to include('named: new_name')
      expect(ConsoleAgent::SessionLogger).to have_received(:update).with(42, name: 'new_name')
    end

    it 'shows error when session not found' do
      allow(mock_session_class).to receive(:find_by).with(id: 999).and_return(nil)

      output = capture_stderr { instance.ai_name(999, 'name') }
      expect(output).to include('Session not found')
    end
  end

  describe '#ai_setup' do
    it 'delegates to ConsoleAgent.setup!' do
      allow(ConsoleAgent).to receive(:setup!)
      instance.ai_setup
      expect(ConsoleAgent).to have_received(:setup!)
    end
  end

  describe '#ai (help text)' do
    it 'includes session management commands in help' do
      output = capture_stderr { instance.ai }
      expect(output).to include('ai_sessions')
      expect(output).to include('ai_resume')
      expect(output).to include('ai_name')
      expect(output).to include('ai_setup')
    end
  end
end

def capture_stdout
  old_stdout = $stdout
  $stdout = StringIO.new
  yield
  $stdout.string
ensure
  $stdout = old_stdout
end

def capture_stderr
  old_stderr = $stderr
  $stderr = StringIO.new
  yield
  $stderr.string
ensure
  $stderr = old_stderr
end
