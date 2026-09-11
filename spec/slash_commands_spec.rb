require 'spec_helper'
require 'rails_console_ai/slash_commands'

RSpec.describe RailsConsoleAi::SlashCommands do
  def skill(name, description: 'a skill')
    { 'name' => name, 'description' => description, 'body' => 'do the thing' }
  end

  def agent(name, description: 'an agent')
    { 'name' => name, 'description' => description, 'body' => 'investigate' }
  end

  let(:skill_loader) { double(load_activatable_skills: []) }
  let(:agent_loader) { double(load_activatable_agents: []) }

  subject(:registry) { described_class.new(skill_loader: skill_loader, agent_loader: agent_loader) }

  describe '.slugify' do
    it 'dashes plain prose names' do
      expect(described_class.slugify('Restart user trial')).to eq('restart-user-trial')
      expect(described_class.slugify('Find shard')).to eq('find-shard')
    end

    it 'strips punctuation and collapses separators' do
      expect(described_class.slugify("Sync user  with Chargify!")).to eq('sync-user-with-chargify')
      expect(described_class.slugify('  -Leading & trailing-  ')).to eq('leading-trailing')
    end

    it 'breaks on slashes and underscores rather than swallowing them' do
      expect(described_class.slugify('Approve/Reject ChangeApprovals'))
        .to eq('approve-reject-change-approvals')
      expect(described_class.slugify('snake_case name')).to eq('snake-case-name')
    end

    it 'breaks camelCase, keeping acronyms intact' do
      expect(described_class.slugify('Resurrect deleted BookingPage'))
        .to eq('resurrect-deleted-booking-page')
      expect(described_class.slugify('HTTPToken refresh')).to eq('http-token-refresh')
    end

    it 'yields an empty slug for a name with nothing typeable in it' do
      expect(described_class.slugify('!!!')).to eq('')
      expect(described_class.slugify(nil)).to eq('')
    end
  end

  describe '#commands' do
    let(:skill_loader) { double(load_activatable_skills: [skill('Restart user trial')]) }
    let(:agent_loader) { double(load_activatable_agents: [agent('Find shard')]) }

    it 'exposes builtins, skills and agents under slugs' do
      expect(registry.find('restart-user-trial').kind).to eq(:skill)
      expect(registry.find('find-shard').kind).to eq(:agent)
      expect(registry.find('compact').kind).to eq(:builtin)
    end

    it 'accepts a leading slash and is case-insensitive' do
      expect(registry.find('/Find-Shard').name).to eq('Find shard')
    end

    it 'offers slash-prefixed completion candidates' do
      expect(registry.candidates).to include('/restart-user-trial', '/find-shard', '/auto')
    end

    it 'pairs each completion candidate with its kind' do
      expect(registry.completion_entries).to include(
        ['/restart-user-trial', 'skill'],
        ['/find-shard', 'agent'],
        ['/auto', 'command']
      )
    end

    it 'keeps the record so the caller can run it' do
      expect(registry.find('restart-user-trial').record['body']).to eq('do the thing')
    end
  end

  describe 'name collisions' do
    let(:skill_loader) { double(load_activatable_skills: [skill('Compact'), skill('Overlap')]) }
    let(:agent_loader) { double(load_activatable_agents: [agent('Overlap')]) }

    it 'never lets a skill shadow a built-in command' do
      expect(registry.find('compact').kind).to eq(:builtin)
      expect(registry.skills.map(&:slug)).not_to include('compact')
    end

    it 'gives a skill precedence over an agent with the same name' do
      expect(registry.find('overlap').kind).to eq(:skill)
      expect(registry.agents.map(&:slug)).not_to include('overlap')
    end

    it 'lists each slug exactly once' do
      expect(registry.candidates.uniq.length).to eq(registry.candidates.length)
    end
  end

  describe 'resilience' do
    let(:skill_loader) { double }
    let(:agent_loader) { double(load_activatable_agents: [agent('Find shard')]) }

    it 'still offers builtins and agents when skill loading blows up' do
      allow(skill_loader).to receive(:load_activatable_skills).and_raise(StandardError, 'no such table')
      allow(RailsConsoleAi.logger).to receive(:warn)

      expect(registry.candidates).to include('/auto', '/find-shard')
      expect(registry.skills).to be_empty
    end

    it 'skips entries whose name yields an empty slug' do
      allow(skill_loader).to receive(:load_activatable_skills).and_return([skill('!!!')])
      expect(registry.skills).to be_empty
    end
  end

  describe '#refresh!' do
    let(:skill_loader) { double }

    it 'memoizes until refreshed, so completion does not hit the DB per keystroke' do
      allow(skill_loader).to receive(:load_activatable_skills).and_return([])

      3.times { registry.candidates }
      expect(skill_loader).to have_received(:load_activatable_skills).once

      allow(skill_loader).to receive(:load_activatable_skills).and_return([skill('Brand new')])
      registry.refresh!

      expect(registry.candidates).to include('/brand-new')
    end
  end
end
