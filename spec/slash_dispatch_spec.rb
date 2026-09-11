require 'spec_helper'
require 'rails_console_ai/context_builder'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/executor'
require 'rails_console_ai/repl'
require 'rails_console_ai/sub_agent'
require 'rails_console_ai/slash_commands'

# Covers what happens when a user types "/something" at the interactive prompt:
# which of skills, agents, built-ins and plain prose each input lands on.
RSpec.describe 'interactive slash commands' do
  let(:test_binding) { binding }
  let(:mock_provider) { instance_double('RailsConsoleAi::Providers::Anthropic') }
  subject(:repl) { RailsConsoleAi::Repl.new(test_binding) }

  let(:the_skill) do
    {
      'name' => 'Restart user trial',
      'description' => "Restart a user's trial",
      'body' => 'Step 1: find the user. Step 2: reset trial_ends_at.',
      'bypass_guards_for_methods' => ['User#save!']
    }
  end

  let(:the_agent) do
    { 'name' => 'Find shard', 'description' => 'Locate a user shard', 'body' => 'You are a shard finder.' }
  end

  before do
    RailsConsoleAi.configure do |c|
      c.api_key = 'test-key'
      c.provider = :anthropic
    end

    allow(RailsConsoleAi::Providers).to receive(:build).and_return(mock_provider)
    allow(RailsConsoleAi::ContextBuilder).to receive(:new).and_return(double(build: 'test context'))
    allow(mock_provider).to receive(:chat_with_tools)
      .and_return(RailsConsoleAi::Providers::ChatResult.new(
        text: 'done', input_tokens: 10, output_tokens: 5, stop_reason: :end_turn
      ))

    allow_any_instance_of(RailsConsoleAi::SkillLoader)
      .to receive(:load_activatable_skills).and_return([the_skill])
    allow_any_instance_of(RailsConsoleAi::AgentLoader)
      .to receive(:load_activatable_agents).and_return([the_agent])
  end

  # Feed the interactive loop a fixed script of typed lines.
  def type(*lines)
    remaining = lines.dup
    allow(Readline).to receive(:respond_to?).with(:parse_and_bind).and_return(false)
    allow(Readline).to receive(:readline) { remaining.shift }
    capture_stdout { repl.interactive }
  end

  def history
    repl.instance_variable_get(:@history)
  end

  describe 'a skill' do
    it 'runs as a normal turn with the recipe and the request in the message' do
      type('/restart-user-trial user 42 please')

      sent = history.find { |h| h[:role] == :user }[:content]
      expect(sent).to include('Restart user trial')
      expect(sent).to include('Step 2: reset trial_ends_at.')
      expect(sent).to include('user 42 please')
    end

    it 'installs the skill guard bypasses on the live executor' do
      executor = repl.instance_variable_get(:@executor)
      expect(executor).to receive(:activate_skill_bypasses).with(['User#save!'])
      type('/restart-user-trial user 42')
    end

    it 'still runs when invoked with no request after the name' do
      type('/restart-user-trial')

      sent = history.find { |h| h[:role] == :user }[:content]
      expect(sent).to include('Step 1: find the user.')
      expect(sent).to include('Follow this skill now.')
    end

    it 'records the typed command in the session log, not the expanded prompt' do
      type('/restart-user-trial user 42')

      log = repl.instance_variable_get(:@channel).console_capture_string
      expect(log).to include('ai> /restart-user-trial user 42')
      expect(log).not_to include('Step 2: reset trial_ends_at.')
    end
  end

  describe 'an agent' do
    it 'runs in a sub-agent and folds only the summary into the conversation' do
      expect(RailsConsoleAi::SubAgent).to receive(:new) do |args|
        expect(args[:task]).to eq('user 42')
        expect(args[:agent_config]).to eq(the_agent)
        double(run: 'User 42 is on shard 3.', input_tokens: 90, output_tokens: 12, model_used: 'claude-sonnet-5')
      end

      type('/find-shard user 42')

      folded = history.find { |h| h[:content].to_s.include?('shard 3') }
      expect(folded).not_to be_nil
      expect(folded[:content]).to include('Find shard')
      expect(folded[:content]).to include('user 42')
    end

    it 'bills the sub-agent tokens to the session' do
      allow(RailsConsoleAi::SubAgent).to receive(:new).and_return(
        double(run: 'ok', input_tokens: 90, output_tokens: 12, model_used: 'claude-sonnet-5')
      )

      type('/find-shard user 42')

      expect(repl.instance_variable_get(:@engine).total_input_tokens).to be >= 90
    end

    it 'asks for a task instead of running empty' do
      expect(RailsConsoleAi::SubAgent).not_to receive(:new)
      output = type('/find-shard')
      expect(output).to include('needs a task')
    end

    it 'does not reach the main provider' do
      allow(RailsConsoleAi::SubAgent).to receive(:new).and_return(
        double(run: 'ok', input_tokens: 1, output_tokens: 1, model_used: 'm')
      )
      type('/find-shard user 42')
      expect(mock_provider).not_to have_received(:chat_with_tools)
    end
  end

  describe 'built-ins still win' do
    it 'treats /compact as the command, never as a skill' do
      expect_any_instance_of(RailsConsoleAi::ConversationEngine).to receive(:compact_history)
      type('/compact')
    end
  end

  describe 'input that only looks like a command' do
    it 'passes a leading file path through to the model untouched' do
      type('/tmp/deploy.log has the stack trace')

      sent = history.find { |h| h[:role] == :user }[:content]
      expect(sent).to include('/tmp/deploy.log has the stack trace')
    end

    it 'flags an unknown command rather than silently asking the model' do
      output = type('/restart-user-trail user 42')

      expect(output).to include('Unknown command: /restart-user-trail')
      expect(output).to include('/restart-user-trial')
      expect(mock_provider).not_to have_received(:chat_with_tools)
    end
  end

  describe 'Tab completion' do
    it 'labels each candidate with what kind of thing it is' do
      registry = RailsConsoleAi::SlashCommands.new
      entries = registry.completion_entries.to_h

      expect(entries['/restart-user-trial']).to eq('skill')
      expect(entries['/find-shard']).to eq('agent')
      expect(entries['/compact']).to eq('command')
    end
  end

  describe 'the / listing' do
    it 'shows skills and agents in separate sections' do
      output = type('/')

      expect(output).to include('Skills:')
      expect(output).to include('/restart-user-trial')
      expect(output).to include("Restart a user's trial")
      expect(output).to include('Agents:')
      expect(output).to include('/find-shard')
    end

    it 'still lists the built-in commands' do
      output = type('/')
      expect(output).to include('/compact')
      expect(output).to include('/usage')
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
