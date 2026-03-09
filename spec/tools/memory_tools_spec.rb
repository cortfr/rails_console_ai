require 'spec_helper'
require 'rails_console_ai/storage/file_storage'
require 'rails_console_ai/tools/memory_tools'
require 'tmpdir'

RSpec.describe RailsConsoleAi::Tools::MemoryTools do
  let(:tmpdir) { Dir.mktmpdir('rails_console_ai_test') }
  let(:storage) { RailsConsoleAi::Storage::FileStorage.new(tmpdir) }
  subject(:tools) { described_class.new(storage) }

  after { FileUtils.rm_rf(tmpdir) }

  describe '#save_memory' do
    it 'saves a memory as a markdown file' do
      result = tools.save_memory(name: 'Test fact', description: 'A useful fact', tags: ['test'])
      expect(result).to include('Memory saved')

      content = storage.read('memories/test-fact.md')
      expect(content).to include('name: Test fact')
      expect(content).to include('A useful fact')
      expect(content).to include('test')
    end

    it 'creates separate files for different memories' do
      tools.save_memory(name: 'First', description: 'First fact')
      tools.save_memory(name: 'Second', description: 'Second fact')

      keys = storage.list('memories/*.md')
      expect(keys.length).to eq(2)
    end

    it 'updates existing memory with the same name' do
      tools.save_memory(name: 'Sharding', description: 'Original description', tags: ['database'])
      result = tools.save_memory(name: 'Sharding', description: 'Updated description', tags: ['database', 'updated'])

      expect(result).to include('Memory updated')
      expect(result).to include('Sharding')

      keys = storage.list('memories/*.md')
      expect(keys.length).to eq(1)

      content = storage.read('memories/sharding.md')
      expect(content).to include('Updated description')
      expect(content).to include('updated_at')
    end

    it 'updates case-insensitively by name' do
      tools.save_memory(name: 'Sharding Architecture', description: 'Original')
      tools.save_memory(name: 'sharding architecture', description: 'Updated')

      keys = storage.list('memories/*.md')
      expect(keys.length).to eq(1)

      content = storage.read('memories/sharding-architecture.md')
      expect(content).to include('Updated')
    end

    it 'keeps original tags when updating with empty tags' do
      tools.save_memory(name: 'Sharding', description: 'Original', tags: ['database'])
      tools.save_memory(name: 'Sharding', description: 'Updated')

      content = storage.read('memories/sharding.md')
      expect(content).to include('database')
    end

    it 'returns fallback text on storage error' do
      failing_storage = instance_double(RailsConsoleAi::Storage::FileStorage)
      allow(failing_storage).to receive(:read).and_return(nil)
      allow(failing_storage).to receive(:exists?).and_return(false)
      allow(failing_storage).to receive(:list).and_return([])
      allow(failing_storage).to receive(:write).and_raise(
        RailsConsoleAi::Storage::StorageError, 'Read-only filesystem'
      )

      tools_with_bad_storage = described_class.new(failing_storage)
      result = tools_with_bad_storage.save_memory(name: 'Test', description: 'Desc')
      expect(result).to include('FAILED to save')
      expect(result).to include('Test')
      expect(result).to include('Desc')
    end
  end

  describe '#delete_memory' do
    it 'deletes a memory by name' do
      tools.save_memory(name: 'First', description: 'First fact')
      tools.save_memory(name: 'Second', description: 'Second fact')

      result = tools.delete_memory(name: 'First')
      expect(result).to include('Memory deleted')
      expect(result).to include('First')

      keys = storage.list('memories/*.md')
      expect(keys.length).to eq(1)
    end

    it 'returns error for unknown name' do
      result = tools.delete_memory(name: 'nonexistent')
      expect(result).to include('No memory found')
    end
  end

  describe '#recall_memories' do
    before do
      tools.save_memory(name: 'Sharding', description: 'Uses separate databases', tags: ['database'])
      tools.save_memory(name: 'Auth', description: 'Uses Devise for authentication', tags: ['auth', 'users'])
    end

    it 'returns all memories with no filter' do
      result = tools.recall_memories
      expect(result).to include('Sharding')
      expect(result).to include('Auth')
    end

    it 'filters by query' do
      result = tools.recall_memories(query: 'devise')
      expect(result).to include('Auth')
      expect(result).not_to include('Sharding')
    end

    it 'filters by tag' do
      result = tools.recall_memories(tag: 'database')
      expect(result).to include('Sharding')
      expect(result).not_to include('Auth')
    end

    it 'returns message when no memories exist' do
      empty_tools = described_class.new(RailsConsoleAi::Storage::FileStorage.new(Dir.mktmpdir))
      expect(empty_tools.recall_memories).to eq('No memories stored yet.')
    end

    it 'returns message when no matches found' do
      result = tools.recall_memories(query: 'nonexistent')
      expect(result).to eq('No memories matching your search.')
    end
  end

  describe '#memory_summaries' do
    it 'returns nil when no memories exist' do
      expect(tools.memory_summaries).to be_nil
    end

    it 'returns name and tags for each memory' do
      tools.save_memory(name: 'Sharding', description: 'Separate DBs per shard', tags: ['database'])
      tools.save_memory(name: 'Auth', description: 'Uses Devise')

      summaries = tools.memory_summaries
      expect(summaries.length).to eq(2)
      expect(summaries).to include('- Sharding [database]')
      expect(summaries).to include('- Auth')
    end
  end
end
