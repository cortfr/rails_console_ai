require 'spec_helper'
require 'rails_console_ai/tools/registry'
require 'rails_console_ai/executor'

RSpec.describe RailsConsoleAi::Tools::Registry do
  subject(:registry) { described_class.new }

  describe '#definitions' do
    it 'registers all expected tools' do
      names = registry.definitions.map { |d| d[:name] }
      expect(names).to include('list_tables', 'describe_table', 'list_models', 'describe_model',
                               'list_files', 'read_file', 'search_code', 'ask_user',
                               'save_memory', 'delete_memory', 'recall_memories')
    end
  end

  describe '#to_anthropic_format' do
    it 'returns tools in Anthropic format' do
      tools = registry.to_anthropic_format
      expect(tools).to all(include('name', 'description', 'input_schema'))
    end
  end

  describe '#to_openai_format' do
    it 'returns tools in OpenAI format' do
      tools = registry.to_openai_format
      expect(tools).to all(include('type' => 'function'))
      tools.each do |t|
        expect(t['function']).to include('name', 'description', 'parameters')
      end
    end
  end

  describe 'init mode' do
    subject(:init_registry) { described_class.new(mode: :init) }

    it 'registers only introspection tools' do
      names = init_registry.definitions.map { |d| d[:name] }
      expect(names).to include('list_tables', 'describe_table', 'list_models', 'describe_model',
                               'list_files', 'read_file', 'search_code')
    end

    it 'excludes ask_user, memory, and execute_plan tools' do
      names = init_registry.definitions.map { |d| d[:name] }
      expect(names).not_to include('ask_user', 'save_memory', 'delete_memory',
                                   'recall_memories', 'execute_plan')
    end
  end

  describe 'recall_output tool' do
    it 'is registered when executor is provided' do
      executor = RailsConsoleAi::Executor.new(binding)
      reg = described_class.new(executor: executor)
      names = reg.definitions.map { |d| d[:name] }
      expect(names).to include('recall_output')
    end

    it 'is not registered without an executor' do
      names = registry.definitions.map { |d| d[:name] }
      expect(names).not_to include('recall_output')
    end

    it 'retrieves stored output' do
      executor = RailsConsoleAi::Executor.new(binding)
      id = executor.store_output("stored data")
      reg = described_class.new(executor: executor)
      result = reg.execute('recall_output', { 'id' => id })
      expect(result).to eq("stored data")
    end

    it 'returns error for unknown id' do
      executor = RailsConsoleAi::Executor.new(binding)
      reg = described_class.new(executor: executor)
      result = reg.execute('recall_output', { 'id' => 999 })
      expect(result).to include('No output found')
    end
  end

  describe 'recall_outputs tool' do
    it 'is registered when executor is provided' do
      executor = RailsConsoleAi::Executor.new(binding)
      reg = described_class.new(executor: executor)
      names = reg.definitions.map { |d| d[:name] }
      expect(names).to include('recall_outputs')
    end

    it 'is not registered without an executor' do
      names = registry.definitions.map { |d| d[:name] }
      expect(names).not_to include('recall_outputs')
    end

    it 'has ids parameter as required array of integers' do
      executor = RailsConsoleAi::Executor.new(binding)
      reg = described_class.new(executor: executor)
      defn = reg.definitions.find { |d| d[:name] == 'recall_outputs' }
      expect(defn[:parameters]['required']).to eq(['ids'])
      expect(defn[:parameters]['properties']['ids']['type']).to eq('array')
      expect(defn[:parameters]['properties']['ids']['items']['type']).to eq('integer')
    end
  end

  describe 'activate_skill tool' do
    let(:tmpdir) { Dir.mktmpdir('rails_console_ai_test') }
    let(:storage) { RailsConsoleAi::Storage::FileStorage.new(tmpdir) }
    let(:executor) { RailsConsoleAi::Executor.new(binding) }

    before do
      RailsConsoleAi.configure { |c| c.storage_adapter = storage }
      storage.write('skills/test-skill.md', <<~MD)
        ---
        name: Test Skill
        description: A test skill
        bypass_guards_for_methods:
          - "SomeClass#some_method"
        ---

        ## Recipe
        Do the thing.
      MD
    end

    after { FileUtils.rm_rf(tmpdir) }

    it 'is registered when executor is provided' do
      reg = described_class.new(executor: executor)
      names = reg.definitions.map { |d| d[:name] }
      expect(names).to include('activate_skill')
    end

    it 'is not registered without an executor' do
      names = registry.definitions.map { |d| d[:name] }
      expect(names).not_to include('activate_skill')
    end

    it 'returns skill body on activation' do
      reg = described_class.new(executor: executor)
      result = reg.execute('activate_skill', { 'name' => 'Test Skill' })
      expect(result).to include('## Recipe')
      expect(result).to include('Do the thing.')
    end

    it 'returns error for unknown skill' do
      reg = described_class.new(executor: executor)
      result = reg.execute('activate_skill', { 'name' => 'Nonexistent' })
      expect(result).to include('Skill not found')
    end
  end

  describe '#execute' do
    it 'returns error for unknown tool' do
      result = registry.execute('nonexistent', {})
      expect(result).to include('unknown tool')
    end

    it 'handles string arguments (JSON)' do
      # list_tables doesn't need args, so calling with string '{}' should work
      result = registry.execute('list_tables', '{}')
      # May return "ActiveRecord is not connected." or table list
      expect(result).to be_a(String)
    end
  end
end
