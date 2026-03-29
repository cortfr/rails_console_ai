require 'spec_helper'
require 'rails_console_ai/agent_loader'
require 'rails_console_ai/storage/file_storage'
require 'tmpdir'

RSpec.describe RailsConsoleAi::AgentLoader do
  let(:tmpdir) { Dir.mktmpdir('rails_console_ai_test') }
  let(:storage) { RailsConsoleAi::Storage::FileStorage.new(tmpdir) }
  subject(:loader) { described_class.new(storage) }

  before do
    RailsConsoleAi.configure { |c| c.storage_adapter = storage }
  end

  after { FileUtils.rm_rf(tmpdir) }

  let(:agent_content) do
    <<~MD
      ---
      name: Find shard
      description: Given a user ID, determines which database shard they are on
      max_rounds: 5
      tools:
        - execute_code
        - recall_memory
      ---

      You are a shard finder for a sharded Rails application.

      Steps:
      1. Find the user: User.find(id)
      2. Check user.shard
      3. Report the shard value.
    MD
  end

  describe 'built-in agents' do
    it 'loads built-in agents from the gem' do
      agents = loader.load_all_agents
      names = agents.map { |a| a['name'] }
      expect(names).to include('Investigate code')
      expect(names).to include('Explore data')
    end

    it 'marks built-in agents with builtin flag' do
      agents = loader.load_all_agents
      builtin = agents.find { |a| a['name'] == 'Investigate code' }
      expect(builtin['builtin']).to be true
    end

    it 'allows app agents to override built-ins with the same name' do
      storage.write('agents/investigate-code.md', <<~MD)
        ---
        name: Investigate code
        description: Custom override
        ---

        Custom body.
      MD

      agent = loader.find_agent('Investigate code')
      expect(agent['description']).to eq('Custom override')
      expect(agent['builtin']).to be_nil
    end
  end

  describe '#load_all_agents' do
    it 'includes app agents alongside built-ins' do
      storage.write('agents/find-shard.md', agent_content)

      agents = loader.load_all_agents
      names = agents.map { |a| a['name'] }
      expect(names).to include('Find shard')
      expect(names).to include('Investigate code')
      expect(names).to include('Explore data')
    end

    it 'parses app agent files correctly' do
      storage.write('agents/find-shard.md', agent_content)

      agent = loader.find_agent('Find shard')
      expect(agent['description']).to eq('Given a user ID, determines which database shard they are on')
      expect(agent['max_rounds']).to eq(5)
      expect(agent['tools']).to eq(['execute_code', 'recall_memory'])
      expect(agent['body']).to include('shard finder')
      expect(agent['body']).to include('User.find(id)')
    end

    it 'skips empty app agent files' do
      storage.write('agents/empty.md', '   ')
      agents = loader.load_all_agents
      names = agents.map { |a| a['name'] }
      expect(names).not_to include(nil)
    end

    it 'skips app agent files with invalid frontmatter' do
      storage.write('agents/bad.md', 'no frontmatter here')
      # Should still load built-ins without error
      expect { loader.load_all_agents }.not_to raise_error
    end
  end

  describe '#agent_summaries' do
    it 'includes built-in agent summaries' do
      summaries = loader.agent_summaries
      expect(summaries).not_to be_nil
      expect(summaries.any? { |s| s.include?('Investigate code') }).to be true
      expect(summaries.any? { |s| s.include?('Explore data') }).to be true
    end

    it 'includes app agent summaries' do
      storage.write('agents/find-shard.md', agent_content)

      summaries = loader.agent_summaries
      expect(summaries.any? { |s| s.include?('Find shard') }).to be true
    end
  end

  describe '#find_agent' do
    it 'finds a built-in agent by name' do
      agent = loader.find_agent('Investigate code')
      expect(agent).not_to be_nil
      expect(agent['name']).to eq('Investigate code')
    end

    it 'finds an app agent by name (case-insensitive)' do
      storage.write('agents/find-shard.md', agent_content)

      agent = loader.find_agent('find shard')
      expect(agent).not_to be_nil
      expect(agent['name']).to eq('Find shard')
    end

    it 'returns nil for unknown agent name' do
      expect(loader.find_agent('nonexistent')).to be_nil
    end
  end

  describe '#save_agent' do
    it 'creates a new agent file' do
      result = loader.save_agent(
        name: 'Diagnose sync',
        description: 'Diagnose calendar sync issues',
        body: "Steps:\n1. Check calendar\n2. Check sync status",
        max_rounds: 10
      )

      expect(result).to start_with('Agent created:')
      agent = loader.find_agent('Diagnose sync')
      expect(agent).not_to be_nil
      expect(agent['name']).to eq('Diagnose sync')
      expect(agent['max_rounds']).to eq(10)
    end

    it 'updates an existing agent' do
      loader.save_agent(name: 'Test Agent', description: 'v1', body: 'original')
      result = loader.save_agent(name: 'Test Agent', description: 'v2', body: 'updated')

      expect(result).to start_with('Agent updated:')
      agent = loader.find_agent('Test Agent')
      expect(agent['description']).to eq('v2')
      expect(agent['body']).to eq('updated')
    end

    it 'includes optional fields only when provided' do
      loader.save_agent(name: 'Simple', description: 'test', body: 'body')

      content = storage.read('agents/simple.md')
      expect(content).not_to include('max_rounds')
      expect(content).not_to include('model')
      expect(content).not_to include('tools')
    end

    it 'includes model and tools when provided' do
      loader.save_agent(
        name: 'Custom',
        description: 'test',
        body: 'body',
        model: 'claude-haiku-4-5-20251001',
        tools: ['execute_code', 'describe_model']
      )

      agent = loader.find_agent('Custom')
      expect(agent['model']).to eq('claude-haiku-4-5-20251001')
      expect(agent['tools']).to eq(['execute_code', 'describe_model'])
    end
  end

  describe '#delete_agent' do
    it 'deletes an existing app agent' do
      loader.save_agent(name: 'To Delete', description: 'test', body: 'body')
      result = loader.delete_agent(name: 'To Delete')

      expect(result).to start_with('Agent deleted:')
      expect(loader.find_agent('To Delete')).to be_nil
    end

    it 'returns error for nonexistent agent' do
      result = loader.delete_agent(name: 'Nonexistent')
      expect(result).to include('No agent found')
    end
  end
end
