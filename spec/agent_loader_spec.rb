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

    it 'refuses to delete a built-in agent' do
      result = loader.delete_agent(name: 'Investigate code')
      expect(result).to include('Cannot delete built-in agent')
    end
  end

  describe 'DB + file + built-in union (DatabaseStorage stubbed)' do
    let(:db_agent) do
      { 'id' => 42, 'name' => 'DB-only agent', 'description' => 'lives in DB',
        'body' => 'persona', 'max_rounds' => 8, 'model' => nil, 'tools' => [],
        'status' => 'approved', 'approved_by' => 'alice', 'approved_at' => Time.now.utc,
        'source' => :db }
    end
    let(:proposed_db_agent) do
      { 'id' => 43, 'name' => 'Proposed agent', 'description' => 'awaiting',
        'body' => 'persona', 'max_rounds' => 5, 'model' => nil, 'tools' => [],
        'status' => 'proposed', 'source' => :db }
    end

    before do
      allow(RailsConsoleAi::Storage::DatabaseStorage).to receive(:agents_available?).and_return(true)
      allow(RailsConsoleAi::Storage::DatabaseStorage).to receive(:all_agents)
        .and_return([db_agent, proposed_db_agent])
      storage.write('agents/find-shard.md', agent_content)
    end

    it 'load_all_agents returns DB + file + built-in records' do
      names = loader.load_all_agents.map { |a| a['name'] }
      # DB
      expect(names).to include('DB-only agent', 'Proposed agent')
      # File
      expect(names).to include('Find shard')
      # Built-in (gem-shipped)
      expect(names).to include('Investigate code', 'Explore data')
    end

    it 'tags every loaded record with its source' do
      sources = loader.load_all_agents.each_with_object({}) { |a, h| h[a['name']] = a['source'] }
      expect(sources['DB-only agent']).to eq(:db)
      expect(sources['Find shard']).to eq(:file)
      expect(sources['Investigate code']).to eq(:builtin)
    end

    it 'load_activatable_agents hides proposed DB agents' do
      names = loader.load_activatable_agents.map { |a| a['name'] }
      expect(names).to include('DB-only agent')        # approved DB
      expect(names).to include('Find shard')           # file
      expect(names).to include('Investigate code')     # built-in
      expect(names).not_to include('Proposed agent')   # gated
    end

    it 'find_agent (AI-facing) refuses proposed DB agents' do
      expect(loader.find_agent('Proposed agent')).to be_nil
      expect(loader.find_agent('DB-only agent')).not_to be_nil
    end

    it 'find_any_agent (UI-facing) still resolves proposed DB agents' do
      result = loader.find_any_agent('Proposed agent')
      expect(result).not_to be_nil
      expect(result['source']).to eq(:db)
      expect(result['status']).to eq('proposed')
    end

    it 'agent_summaries omits proposed DB agents' do
      summary = loader.agent_summaries.join("\n")
      expect(summary).to include('DB-only agent', 'Find shard', 'Investigate code')
      expect(summary).not_to include('Proposed agent')
    end

    it 'DB wins on name collision with file' do
      # file agent named the same as a DB agent — DB should win
      colliding_file = agent_content.sub('name: Find shard', 'name: DB-only agent')
      storage.write('agents/db-only-agent.md', colliding_file)
      results = loader.load_all_agents.select { |a| a['name'] == 'DB-only agent' }
      expect(results.length).to eq(1)
      expect(results.first['source']).to eq(:db)
    end

    it 'DB wins on name collision with built-in (override)' do
      override_db = db_agent.merge('name' => 'Investigate code', 'description' => 'app override')
      allow(RailsConsoleAi::Storage::DatabaseStorage).to receive(:all_agents)
        .and_return([override_db])
      results = loader.load_all_agents.select { |a| a['name'].to_s.downcase == 'investigate code' }
      expect(results.length).to eq(1)
      expect(results.first['source']).to eq(:db)
      expect(results.first['description']).to eq('app override')
    end
  end

  describe 'save_agent target routing (DatabaseStorage stubbed)' do
    before do
      allow(RailsConsoleAi::Storage::DatabaseStorage).to receive(:agents_available?).and_return(true)
      allow(RailsConsoleAi::Storage::DatabaseStorage).to receive(:all_agents).and_return([])
    end

    it 'routes save_agent to DB by default and reports PROPOSED state' do
      record = double('Agent', id: 99, name: 'X', proposed?: true)
      expect(RailsConsoleAi::Storage::DatabaseStorage).to receive(:save_agent)
        .with(hash_including(name: 'X', description: 'd', body: 'b'))
        .and_return([record, true])
      result = loader.save_agent(name: 'X', description: 'd', body: 'b')
      expect(result).to include('Agent created (db)')
      expect(result).to include('PROPOSED')
      expect(result).to include('/rails_console_ai/agents')
    end

    it 'routes save_agent to file when target: :file' do
      expect(RailsConsoleAi::Storage::DatabaseStorage).not_to receive(:save_agent)
      result = loader.save_agent(name: 'FileOnly', description: 'd', body: 'b', target: :file)
      expect(result).to start_with('Agent created:')
      expect(storage.read('agents/fileonly.md')).to include('FileOnly')
    end

    it 'falls back to file when DB target is requested but tables are missing' do
      allow(RailsConsoleAi::Storage::DatabaseStorage).to receive(:agents_available?).and_return(false)
      expect(RailsConsoleAi::Storage::DatabaseStorage).not_to receive(:save_agent)
      result = loader.save_agent(name: 'Fb', description: 'd', body: 'b', target: :db)
      expect(result).to start_with('Agent created:')
      expect(result).to include('NOTE: DB storage was requested')
    end
  end
end
