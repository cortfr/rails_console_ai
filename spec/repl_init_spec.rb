require 'spec_helper'
require 'rails_console_ai/context_builder'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/executor'
require 'rails_console_ai/repl'
require 'rails_console_ai/storage/file_storage'
require 'tmpdir'

RSpec.describe RailsConsoleAi::Repl, '#init_guide' do
  let(:test_binding) { binding }
  let(:mock_provider) { instance_double('RailsConsoleAi::Providers::Anthropic') }
  let(:tmpdir) { Dir.mktmpdir('rails_console_ai_test') }
  let(:storage) { RailsConsoleAi::Storage::FileStorage.new(tmpdir) }
  subject(:repl) { described_class.new(test_binding) }

  before do
    RailsConsoleAi.configure do |c|
      c.api_key = 'test-key'
      c.provider = :anthropic
      c.storage_adapter = storage
    end

    allow(RailsConsoleAi::Providers).to receive(:build).and_return(mock_provider)
    allow(RailsConsoleAi::ContextBuilder).to receive(:new)
      .and_return(double(build: 'test context', environment_context: '## Environment'))
  end

  after { FileUtils.rm_rf(tmpdir) }

  def chat_result(text, input_tokens: 100, output_tokens: 50)
    RailsConsoleAi::Providers::ChatResult.new(
      text: text,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      stop_reason: :end_turn
    )
  end

  it 'generates guide and saves to storage' do
    allow(mock_provider).to receive(:chat_with_tools)
      .and_return(chat_result("# My App\nA Rails application for managing widgets."))

    output = capture_stdout { repl.init_guide }

    expect(output).to include('No existing guide')
    expect(output).to include('Guide saved')

    saved = storage.read(RailsConsoleAi::GUIDE_KEY)
    expect(saved).to include('My App')
    expect(saved).to include('managing widgets')
  end

  it 'passes existing guide to system prompt on re-run' do
    storage.write(RailsConsoleAi::GUIDE_KEY, '# Old Guide')

    captured_opts = nil
    allow(mock_provider).to receive(:chat_with_tools) do |_messages, **opts|
      captured_opts = opts
      chat_result("# Updated Guide\nBetter content.")
    end

    output = capture_stdout { repl.init_guide }

    expect(output).to include('Existing guide found')
    expect(captured_opts[:system_prompt]).to include('Old Guide')
  end

  it 'strips markdown code fences' do
    allow(mock_provider).to receive(:chat_with_tools)
      .and_return(chat_result("```markdown\n# My App\nContent here.\n```"))

    capture_stdout { repl.init_guide }

    saved = storage.read(RailsConsoleAi::GUIDE_KEY)
    expect(saved).to eq("# My App\nContent here.")
    expect(saved).not_to include('```')
  end

  it 'strips LLM preamble before the first markdown header' do
    allow(mock_provider).to receive(:chat_with_tools)
      .and_return(chat_result("Now I have enough information. Let me compile everything.\n\n# My App\nContent here."))

    capture_stdout { repl.init_guide }

    saved = storage.read(RailsConsoleAi::GUIDE_KEY)
    expect(saved).to start_with('# My App')
    expect(saved).not_to include('enough information')
  end

  it 'does not save on empty response' do
    allow(mock_provider).to receive(:chat_with_tools)
      .and_return(chat_result(''))

    output = capture_stdout { repl.init_guide }

    expect(output).to include('No guide content generated')
    expect(storage.read(RailsConsoleAi::GUIDE_KEY)).to be_nil
  end

  it 'handles interrupts gracefully' do
    allow(mock_provider).to receive(:chat_with_tools).and_raise(Interrupt)

    output = capture_stdout { repl.init_guide }
    expect(output).to include('Interrupted')
  end

  it 'runs tool-use loop when LLM requests tools' do
    tool_call_result = RailsConsoleAi::Providers::ChatResult.new(
      text: '',
      input_tokens: 50,
      output_tokens: 20,
      tool_calls: [{ id: 'tool_1', name: 'list_tables', arguments: {} }],
      stop_reason: :tool_use
    )

    final_result = chat_result("# App Guide\nContent from exploration.")

    call_count = 0
    allow(mock_provider).to receive(:chat_with_tools) do
      call_count += 1
      call_count == 1 ? tool_call_result : final_result
    end

    allow(mock_provider).to receive(:format_assistant_message).and_return(
      { role: 'assistant', content: [{ 'type' => 'tool_use', 'id' => 'tool_1', 'name' => 'list_tables', 'input' => {} }] }
    )
    allow(mock_provider).to receive(:format_tool_result).and_return(
      { role: 'user', content: [{ 'type' => 'tool_result', 'tool_use_id' => 'tool_1', 'content' => 'users, posts' }] }
    )

    capture_stdout { repl.init_guide }

    expect(call_count).to eq(2)
    saved = storage.read(RailsConsoleAi::GUIDE_KEY)
    expect(saved).to include('App Guide')
  end

  it 'uses init mode registry without ask_user or memory tools' do
    captured_tools = nil
    allow(mock_provider).to receive(:chat_with_tools) do |_messages, **opts|
      captured_tools = opts[:tools]
      chat_result("# Guide")
    end

    capture_stdout { repl.init_guide }

    tool_names = captured_tools.definitions.map { |d| d[:name] }
    expect(tool_names).to include('list_tables', 'describe_table', 'list_models', 'describe_model',
                                  'list_files', 'read_file', 'search_code')
    expect(tool_names).not_to include('ask_user', 'save_memory', 'delete_memory',
                                      'recall_memories', 'execute_plan')
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
