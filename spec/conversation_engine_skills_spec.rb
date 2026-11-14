require 'spec_helper'
require 'rails_console_ai/executor'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/conversation_engine'
require 'rails_console_ai/session_logger'
require 'rails_console_ai/skill_loader'

# Skills named up front by RailsConsoleAi.run_agent(skills:) are activated
# before the first turn, and one_shot keeps its tool rounds in the logged
# conversation so a background run's session shows what the agent did.
RSpec.describe RailsConsoleAi::ConversationEngine, 'background-run skills' do
  let(:channel) do
    double('channel', mode: 'api', user_identity: 'cron', system_instructions: nil,
           cancelled?: false, display_status: nil)
  end
  let(:test_binding) { Object.new.instance_eval { binding } }
  let(:loader) { instance_double(RailsConsoleAi::SkillLoader) }
  let(:slack_skill) do
    { 'name' => 'Send Slack message', 'body' => 'Use Slack.send_message.',
      'bypass_guards_for_methods' => ['Slack.send_message'], 'source' => :file }
  end
  subject(:engine) { described_class.new(binding_context: test_binding, channel: channel) }

  before do
    RailsConsoleAi.configure do |c|
      c.provider = :anthropic
      c.api_key = 'test-key'
      c.session_logging = true
    end
    allow(RailsConsoleAi::SkillLoader).to receive(:new).and_return(loader)
  end

  describe '#activate_skills!' do
    it 'activates each skill\'s guard bypasses and returns the records' do
      allow(loader).to receive(:find_skill).with('Send Slack message').and_return(slack_skill)
      executor = engine.instance_variable_get(:@executor)
      expect(executor).to receive(:activate_skill_bypasses).with(['Slack.send_message'])

      expect(engine.activate_skills!(['Send Slack message'])).to eq([slack_skill])
      expect(channel).to have_received(:display_status).with('  Activated skill: Send Slack message')
    end

    it 'raises for an unknown skill' do
      allow(loader).to receive(:find_skill).and_return(nil)
      allow(loader).to receive(:find_any_skill).and_return(nil)

      expect { engine.activate_skills!(['nope']) }
        .to raise_error(RailsConsoleAi::SkillUnavailableError, /Skill not found: "nope"/)
    end

    it 'raises for a proposed (unapproved) DB skill' do
      allow(loader).to receive(:find_skill).and_return(nil)
      allow(loader).to receive(:find_any_skill)
        .and_return('name' => 'draft', 'source' => :db, 'status' => 'proposed')

      expect { engine.activate_skills!(['draft']) }
        .to raise_error(RailsConsoleAi::SkillUnavailableError, /awaiting approval/)
    end
  end

  describe '#one_shot' do
    let(:final) do
      RailsConsoleAi::Providers::ChatResult.new(text: 'Sent.', input_tokens: 1, output_tokens: 1,
                                                stop_reason: :end_turn)
    end
    let(:tool_round) do
      [{ role: :assistant, content: [{ 'type' => 'tool_use', 'name' => 'activate_skill' }] },
       { role: :user, content: [{ 'type' => 'tool_result', 'content' => 'recipe' }] }]
    end
    let(:logged) { [] }

    before do
      allow(engine).to receive(:send_query) do |_q, conversation:|
        @sent_turn = conversation.first[:content]
        [final, tool_round, nil]
      end
      allow(engine).to receive(:track_usage)
      allow(engine).to receive(:display_usage)
      allow(engine.instance_variable_get(:@executor)).to receive(:display_response).and_return(nil)
      allow(RailsConsoleAi::SessionLogger).to receive(:update) { |_id, attrs| logged << attrs }
    end

    it 'logs the tool rounds and the final answer in the conversation' do
      engine.one_shot('how many users?', existing_session_id: 7)

      conversation = logged.first[:conversation]
      expect(conversation[1..2]).to eq(tool_round)
      expect(conversation.last).to include(role: :assistant, content: 'Sent.')
    end

    it 'prepends the preactivated skill recipes but logs the original query' do
      engine.one_shot('Slack frank the total', existing_session_id: 7, skills: [slack_skill])

      expect(@sent_turn).to include('already activated for this run', '--- SKILL: Send Slack message ---',
                                    'Use Slack.send_message.', 'The request: Slack frank the total')
      expect(logged.first[:query]).to eq('Slack frank the total')
    end
  end
end
