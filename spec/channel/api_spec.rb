require 'spec_helper'
require 'rails_console_ai/channel/api'

RSpec.describe RailsConsoleAi::Channel::Api do
  subject(:channel) { described_class.new(user_name: 'alice') }

  it 'reports mode as api' do
    expect(channel.mode).to eq('api')
  end

  it 'exposes the user_name passed in' do
    expect(channel.user_identity).to eq('alice')
  end

  it 'never reports cancelled' do
    expect(channel.cancelled?).to be false
  end

  it 'does not allow danger or editing' do
    expect(channel.supports_danger?).to be false
    expect(channel.supports_editing?).to be false
  end

  it 'returns empty string for prompt (no user to ask)' do
    expect(channel.prompt('what?')).to eq('')
  end

  it 'auto-confirms (no user to ask; safety comes from guards + supports_danger? = false)' do
    expect(channel.confirm('Run code?')).to eq('y')
  end

  it 'wrap_llm_call yields' do
    expect(channel.wrap_llm_call { 42 }).to eq(42)
  end

  describe 'output capture' do
    it 'accumulates display into captured_output' do
      channel.display('hello')
      channel.display('world')
      expect(channel.captured_output).to eq("hello\nworld\n")
    end

    it 'accumulates display_result into captured_output' do
      channel.display_result('the answer is 42')
      expect(channel.captured_output).to include('the answer is 42')
    end

    it 'accumulates display_result_output into captured_output' do
      channel.display_result_output('stdout chunk')
      expect(channel.captured_output).to include('stdout chunk')
    end

    it 'swallows display_code (raw code lives on the session row)' do
      expect { channel.display_code('User.count') }.not_to raise_error
      expect(channel.captured_output).to eq('')
    end
  end

  describe 'status log' do
    it 'routes thinking, status, and tool_call into status_log' do
      channel.display_thinking('thinking out loud')
      channel.display_status('working on it')
      channel.display_tool_call('describe_model(User)')

      expect(channel.status_log).to include('thinking out loud', 'working on it', 'describe_model(User)')
    end

    it 'tags warnings and errors in status_log' do
      channel.display_warning('watch out')
      channel.display_error('something broke')

      expect(channel.status_log).to include('WARN: watch out', 'ERROR: something broke')
    end

    it 'keeps status log out of captured_output' do
      channel.display_thinking('thinking')
      channel.display_error('oops')
      expect(channel.captured_output).to eq('')
    end
  end

  describe 'STDOUT logging' do
    let(:buffer) { StringIO.new }

    around do |example|
      original = $stdout
      $stdout = buffer
      example.run
    ensure
      $stdout = original
    end

    it 'tags display calls with >> for the rake task log' do
      channel.display('hello world')
      expect(buffer.string).to include('>> hello world')
    end

    it 'tags tool calls with -> for the rake task log' do
      channel.display_tool_call('describe_model(User)')
      expect(buffer.string).to include('-> describe_model(User)')
    end

    it 'tags status, thinking, warn, and error distinctly' do
      channel.display_status('thinking about it')
      channel.display_thinking('inner monologue')
      channel.display_warning('careful')
      channel.display_error('boom')
      expect(buffer.string).to include('(status) thinking about it')
      expect(buffer.string).to include('(thinking) inner monologue')
      expect(buffer.string).to include('(warn) careful')
      expect(buffer.string).to include('(error) boom')
    end

    it 'prints each line of generated code under (code)' do
      channel.display_code("User.where(active: true)\n  .count")
      expect(buffer.string).to include('(code) User.where(active: true)')
      expect(buffer.string).to include('(code)   .count')
    end

    it 'goes through $stdout so PrefixedIO wrapping can tag with the thread prefix' do
      # Confirms log_prefixed uses $stdout (not STDOUT), which is the
      # contract AgentRunner relies on for [agent/<id>] @<user> prefixes.
      channel.display('hi')
      expect(buffer.string).to include('hi')
    end
  end
end
