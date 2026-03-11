require 'spec_helper'
require 'rails_console_ai/context_builder'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/executor'
require 'rails_console_ai/repl'

RSpec.describe RailsConsoleAi::Repl do
  let(:test_binding) { binding }
  let(:mock_provider) { instance_double('RailsConsoleAi::Providers::Anthropic') }
  subject(:repl) { described_class.new(test_binding) }

  before do
    RailsConsoleAi.configure do |c|
      c.api_key = 'test-key'
      c.provider = :anthropic
    end

    allow(RailsConsoleAi::Providers).to receive(:build).and_return(mock_provider)
    allow(RailsConsoleAi::ContextBuilder).to receive(:new)
      .and_return(double(build: 'test context'))
  end

  def chat_result(text, input_tokens: 100, output_tokens: 50)
    RailsConsoleAi::Providers::ChatResult.new(
      text: text,
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      stop_reason: :end_turn
    )
  end

  def stub_no_tools(result)
    allow(mock_provider).to receive(:chat_with_tools) { result }
  end

  describe '#one_shot' do
    it 'sends query to provider and displays response' do
      # LLM uses the execute_code tool (not code fences) to run code
      tool_call_result = RailsConsoleAi::Providers::ChatResult.new(
        text: '',
        input_tokens: 50, output_tokens: 20,
        tool_calls: [{ id: 'tc_1', name: 'execute_code', arguments: { 'code' => '1 + 1' } }],
        stop_reason: :tool_use
      )
      final_result = chat_result("The result is 2.")

      call_count = 0
      allow(mock_provider).to receive(:chat_with_tools) do
        call_count += 1
        call_count == 1 ? tool_call_result : final_result
      end
      allow(mock_provider).to receive(:format_assistant_message).and_return({ role: 'assistant', content: [] })
      allow(mock_provider).to receive(:format_tool_result).and_return({ role: 'user', content: [] })
      allow($stdin).to receive(:gets).and_return("y\n")

      repl.one_shot('add numbers')
      expect(call_count).to eq(2)
    end

    it 'returns nil when provider returns no code' do
      stub_no_tools(chat_result('Just an explanation, no code.'))

      result = repl.one_shot('explain something')
      expect(result).to be_nil
    end

    it 'handles provider errors gracefully' do
      allow(mock_provider).to receive(:chat_with_tools)
        .and_raise(RailsConsoleAi::Providers::ProviderError, 'API down')

      expect { repl.one_shot('test') }.not_to raise_error
    end
  end

  describe '#explain' do
    it 'displays response without executing' do
      stub_no_tools(chat_result("Explanation:\n```ruby\nUser.count\n```"))

      expect($stdin).not_to receive(:gets)
      result = repl.explain('what does this do')
      expect(result).to be_nil
    end
  end

  describe 'tool use' do
    it 'runs tool-use loop when LLM requests tools' do
      # First call: LLM wants to call list_tables
      tool_call_result = RailsConsoleAi::Providers::ChatResult.new(
        text: '',
        input_tokens: 50,
        output_tokens: 20,
        tool_calls: [{ id: 'tool_1', name: 'list_tables', arguments: {} }],
        stop_reason: :tool_use
      )

      # Second call: LLM produces final answer (use code that won't error in tests)
      final_result = RailsConsoleAi::Providers::ChatResult.new(
        text: "Here are the tables:\n```ruby\n['users', 'posts']\n```",
        input_tokens: 80,
        output_tokens: 30,
        tool_calls: [],
        stop_reason: :end_turn
      )

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

      allow($stdin).to receive(:gets).and_return("y\n")

      result = repl.one_shot('show tables')
      expect(call_count).to eq(2)
    end

    it 'makes only one call when no tools needed' do
      final_result = RailsConsoleAi::Providers::ChatResult.new(
        text: "Sure:\n```ruby\n1 + 1\n```",
        input_tokens: 50,
        output_tokens: 20,
        tool_calls: [],
        stop_reason: :end_turn
      )

      call_count = 0
      allow(mock_provider).to receive(:chat_with_tools) do
        call_count += 1
        final_result
      end

      allow($stdin).to receive(:gets).and_return("y\n")

      repl.one_shot('add numbers')
      expect(call_count).to eq(1)
    end

    it 'aggregates tokens across tool rounds' do
      tool_result = RailsConsoleAi::Providers::ChatResult.new(
        text: '', input_tokens: 100, output_tokens: 20,
        tool_calls: [{ id: 't1', name: 'list_tables', arguments: {} }],
        stop_reason: :tool_use
      )
      final_result = RailsConsoleAi::Providers::ChatResult.new(
        text: "Done:\n```ruby\n42\n```", input_tokens: 150, output_tokens: 30,
        tool_calls: [], stop_reason: :end_turn
      )

      call_count = 0
      allow(mock_provider).to receive(:chat_with_tools) do
        call_count += 1
        call_count == 1 ? tool_result : final_result
      end
      allow(mock_provider).to receive(:format_assistant_message).and_return({ role: 'assistant', content: [] })
      allow(mock_provider).to receive(:format_tool_result).and_return({ role: 'user', content: [] })
      allow($stdin).to receive(:gets).and_return("y\n")

      # Capture the token display
      output = capture_stdout { repl.one_shot('test') }
      expect(output).to include('in: 250')
      expect(output).to include('out: 50')
    end
  end
  describe 'interrupt handling' do
    it 'raises Interrupt when API call is interrupted' do
      allow(mock_provider).to receive(:chat_with_tools).and_raise(Interrupt)

      expect {
        repl.send(:send_query, 'test')
      }.to raise_error(Interrupt)
    end

    it 'does not interfere with normal non-interrupted flow' do
      tool_call_result = RailsConsoleAi::Providers::ChatResult.new(
        text: '',
        input_tokens: 50, output_tokens: 20,
        tool_calls: [{ id: 'tc_1', name: 'execute_code', arguments: { 'code' => '1 + 1' } }],
        stop_reason: :tool_use
      )
      final_result = chat_result("Result: 2")

      call_count = 0
      allow(mock_provider).to receive(:chat_with_tools) do
        call_count += 1
        call_count == 1 ? tool_call_result : final_result
      end
      allow(mock_provider).to receive(:format_assistant_message).and_return({ role: 'assistant', content: [] })
      allow(mock_provider).to receive(:format_tool_result).and_return({ role: 'user', content: [] })
      allow($stdin).to receive(:gets).and_return("y\n")

      repl.one_shot('add numbers')
      expect(call_count).to eq(2)
    end
  end

  describe 'error handling in interactive mode' do
    it 'adds execution errors to conversation history and auto-retries' do
      allow(Readline).to receive(:respond_to?).with(:parse_and_bind).and_return(false)

      # LLM call 1: uses execute_code tool with code that will error
      error_tool_result = RailsConsoleAi::Providers::ChatResult.new(
        text: '',
        input_tokens: 50, output_tokens: 20,
        tool_calls: [{ id: 'tc_1', name: 'execute_code', arguments: { 'code' => "raise 'something broke'" } }],
        stop_reason: :tool_use
      )
      # LLM call 2: after seeing the error in tool result, returns final text
      fixed_response = chat_result("I see there was an error.")

      llm_call_count = 0
      allow(mock_provider).to receive(:chat_with_tools) do
        llm_call_count += 1
        llm_call_count == 1 ? error_tool_result : fixed_response
      end
      allow(mock_provider).to receive(:format_assistant_message).and_return({ role: 'assistant', content: [] })
      allow(mock_provider).to receive(:format_tool_result) do |_id, result|
        { role: :user, content: result.to_s }
      end
      allow($stdin).to receive(:gets).and_return("y\n")

      readline_count = 0
      allow(Readline).to receive(:readline) do
        readline_count += 1
        readline_count == 1 ? 'do something' : nil
      end

      capture_stdout { repl.interactive }

      # LLM was called twice: once for the original query, once after seeing the execute_code error
      expect(llm_call_count).to eq(2)

      history = repl.instance_variable_get(:@history)
      error_msg = history.find { |h| h[:content].to_s.include?('ERROR:') }
      expect(error_msg).not_to be_nil
      expect(error_msg[:content]).to include('RuntimeError')
      expect(error_msg[:content]).to include('something broke')
    end

    it 'only auto-retries once (does not loop on repeated errors)' do
      allow(Readline).to receive(:respond_to?).with(:parse_and_bind).and_return(false)

      # LLM call 1: uses execute_code tool with code that errors
      error_tool_result = RailsConsoleAi::Providers::ChatResult.new(
        text: '',
        input_tokens: 50, output_tokens: 20,
        tool_calls: [{ id: 'tc_1', name: 'execute_code', arguments: { 'code' => "raise 'still broken'" } }],
        stop_reason: :tool_use
      )
      # LLM call 2: after seeing the error, gives up and returns final text (no infinite loop)
      give_up_response = chat_result("Sorry, I was unable to complete that.")

      llm_call_count = 0
      allow(mock_provider).to receive(:chat_with_tools) do
        llm_call_count += 1
        llm_call_count == 1 ? error_tool_result : give_up_response
      end
      allow(mock_provider).to receive(:format_assistant_message).and_return({ role: 'assistant', content: [] })
      allow(mock_provider).to receive(:format_tool_result).and_return({ role: 'user', content: [] })
      allow($stdin).to receive(:gets).and_return("y\n")

      readline_count = 0
      allow(Readline).to receive(:readline) do
        readline_count += 1
        readline_count == 1 ? 'do something' : nil
      end

      capture_stdout { repl.interactive }

      # Exactly 2 calls: original + one retry after error, no infinite loop
      expect(llm_call_count).to eq(2)
    end
  end

  describe 'direct execution with > prefix' do
    it 'executes code directly and adds result to history' do
      allow(Readline).to receive(:respond_to?).with(:parse_and_bind).and_return(false)

      call_count = 0
      allow(Readline).to receive(:readline) do
        call_count += 1
        call_count == 1 ? '> 1 + 1' : nil
      end

      output = capture_stdout { repl.interactive }

      history = repl.instance_variable_get(:@history)
      expect(history.length).to eq(1)
      expect(history.first[:role]).to eq(:user)
      expect(history.first[:content]).to include('User directly executed code')
      expect(history.first[:content]).to include('1 + 1')
      expect(history.first[:content]).to include('Return value: 2')
    end

    it 'does not call the provider' do
      allow(Readline).to receive(:respond_to?).with(:parse_and_bind).and_return(false)

      call_count = 0
      allow(Readline).to receive(:readline) do
        call_count += 1
        call_count == 1 ? '> 1 + 1' : nil
      end

      expect(mock_provider).not_to receive(:chat_with_tools)

      capture_stdout { repl.interactive }
    end

    it 'works without a space after >' do
      allow(Readline).to receive(:respond_to?).with(:parse_and_bind).and_return(false)

      call_count = 0
      allow(Readline).to receive(:readline) do
        call_count += 1
        call_count == 1 ? '>1 + 1' : nil
      end

      expect(mock_provider).not_to receive(:chat_with_tools)

      capture_stdout { repl.interactive }

      history = repl.instance_variable_get(:@history)
      expect(history.first[:content]).to include('Return value: 2')
    end

    it 'does not treat >= as direct execution' do
      allow(Readline).to receive(:respond_to?).with(:parse_and_bind).and_return(false)

      call_count = 0
      allow(Readline).to receive(:readline) do
        call_count += 1
        call_count == 1 ? '>= 5' : nil
      end

      stub_no_tools(chat_result("Here:\n```ruby\n5\n```"))
      allow($stdin).to receive(:gets).and_return("n\n")

      capture_stdout { repl.interactive }

      expect(mock_provider).to have_received(:chat_with_tools)
    end
  end

  describe '/compact command' do
    before do
      allow(Readline).to receive(:respond_to?).with(:parse_and_bind).and_return(false)
    end

    def build_history(count)
      messages = []
      count.times do |i|
        messages << { role: :user, content: "Question #{i + 1}" }
        messages << { role: :assistant, content: "Answer #{i + 1}" }
      end
      messages
    end

    it 'sends history to LLM and replaces with summary' do
      summary_result = chat_result("User was exploring users table and found 42 records.", input_tokens: 200, output_tokens: 80)
      allow(mock_provider).to receive(:chat).and_return(summary_result)

      readline_count = 0
      allow(Readline).to receive(:readline) do
        readline_count += 1
        case readline_count
        when 1
          # Seed history after init_interactive_state has run
          repl.instance_variable_set(:@history, build_history(4))
          '/compact'
        when 2 then nil
        end
      end

      output = capture_stdout { repl.interactive }

      expect(mock_provider).to have_received(:chat).once
      history = repl.instance_variable_get(:@history)
      expect(history.length).to eq(1)
      expect(history.first[:role]).to eq(:user)
      expect(history.first[:content]).to include('CONVERSATION SUMMARY')
      expect(history.first[:content]).to include('42 records')
      # Summary is displayed to the user
      expect(output).to include('42 records')
    end

    it 'skips compaction when history is too short' do
      readline_count = 0
      allow(Readline).to receive(:readline) do
        readline_count += 1
        case readline_count
        when 1 then '/compact'
        when 2 then nil
        end
      end

      output = capture_stdout { repl.interactive }

      expect(output).to include('too short to compact')
    end

    it 'tracks tokens from the compaction call' do
      summary_result = chat_result("Summary of conversation.", input_tokens: 300, output_tokens: 100)
      allow(mock_provider).to receive(:chat).and_return(summary_result)

      readline_count = 0
      allow(Readline).to receive(:readline) do
        readline_count += 1
        case readline_count
        when 1
          repl.instance_variable_set(:@history, build_history(4))
          '/compact'
        when 2 then '/usage'
        when 3 then nil
        end
      end

      output = capture_stdout { repl.interactive }

      # Token counts should include the compaction call
      expect(output).to include('in: 300')
      expect(output).to include('out: 100')
    end

    it 'warns when history gets large' do
      readline_count = 0
      allow(Readline).to receive(:readline) do
        readline_count += 1
        case readline_count
        when 1
          # Seed history with large content after init
          big_history = (1..20).flat_map do |i|
            [
              { role: :user, content: "Question #{i} " + ("x" * 2000) },
              { role: :assistant, content: "Answer #{i} " + ("y" * 2000) }
            ]
          end
          repl.instance_variable_set(:@history, big_history)
          'tell me more'
        when 2 then nil
        end
      end

      stub_no_tools(chat_result("Sure, here you go."))

      output = capture_stdout { repl.interactive }

      expect(output).to include('Consider running /compact')
    end

    it 'only warns once per session' do
      stub_no_tools(chat_result("Response."))

      readline_count = 0
      allow(Readline).to receive(:readline) do
        readline_count += 1
        case readline_count
        when 1
          big_history = (1..20).flat_map do |i|
            [
              { role: :user, content: "Q#{i} " + ("x" * 2000) },
              { role: :assistant, content: "A#{i} " + ("y" * 2000) }
            ]
          end
          repl.instance_variable_set(:@history, big_history)
          'query one'
        when 2 then 'query two'
        when 3 then nil
        end
      end

      output = capture_stdout { repl.interactive }

      # Should only appear once despite two turns with large history
      expect(output.scan(/Consider running \/compact/).length).to eq(1)
    end

    it 'handles compaction errors gracefully' do
      allow(mock_provider).to receive(:chat).and_raise(StandardError, 'API timeout')

      readline_count = 0
      allow(Readline).to receive(:readline) do
        readline_count += 1
        case readline_count
        when 1
          repl.instance_variable_set(:@history, build_history(4))
          '/compact'
        when 2 then nil
        end
      end

      output = capture_stdout { repl.interactive }

      expect(output).to include('Compaction failed')
      expect(output).to include('API timeout')
      # History should be unchanged
      history = repl.instance_variable_get(:@history)
      expect(history.length).to eq(8)
    end
  end

  describe 'output trimming in conversation' do
    it 'keeps recent outputs in full and trims older ones' do
      # Build history with 4 execution outputs (more than RECENT_OUTPUTS_TO_KEEP=2)
      history = []
      4.times do |i|
        history << { role: :user, content: "Code was executed. Output:\ndata_#{i}", output_id: i + 1 }
        history << { role: :assistant, content: "Response #{i}" }
      end

      repl.instance_variable_set(:@history, history)
      trimmed = repl.send(:trim_old_outputs, history)

      # First 2 outputs should be trimmed (4 - 2 = 2)
      trimmed_user_msgs = trimmed.select { |m| m[:role] == :user }
      expect(trimmed_user_msgs[0][:content]).to include('[Output omitted')
      expect(trimmed_user_msgs[0][:content]).to include('recall_output')
      expect(trimmed_user_msgs[1][:content]).to include('[Output omitted')

      # Last 2 should be kept in full
      expect(trimmed_user_msgs[2][:content]).to include('data_2')
      expect(trimmed_user_msgs[3][:content]).to include('data_3')
    end

    it 'does not trim when outputs are within the limit' do
      history = []
      2.times do |i|
        history << { role: :user, content: "Code was executed. Output:\ndata_#{i}", output_id: i + 1 }
      end

      trimmed = repl.send(:trim_old_outputs, history)
      trimmed.each do |msg|
        expect(msg[:content]).not_to include('[Output omitted')
      end
    end

    it 'strips output_id from messages sent to LLM' do
      history = [{ role: :user, content: "test", output_id: 1 }]
      trimmed = repl.send(:trim_old_outputs, history)
      expect(trimmed.first).not_to have_key(:output_id)
    end

    it 'trims Anthropic tool result messages' do
      history = []
      4.times do |i|
        history << {
          role: 'user',
          content: [{ 'type' => 'tool_result', 'tool_use_id' => "tool_#{i}", 'content' => "big data #{i}" }],
          output_id: i + 1
        }
        history << { role: 'assistant', content: "Response #{i}" }
      end

      trimmed = repl.send(:trim_old_outputs, history)

      # First 2 tool results should be trimmed (4 - 2 = 2)
      trimmed_tool_msgs = trimmed.select { |m| m[:content].is_a?(Array) }
      expect(trimmed_tool_msgs[0][:content][0]['content']).to include('recall_output')
      expect(trimmed_tool_msgs[1][:content][0]['content']).to include('recall_output')
      # Last 2 should keep original content
      expect(trimmed_tool_msgs[2][:content][0]['content']).to eq('big data 2')
      expect(trimmed_tool_msgs[3][:content][0]['content']).to eq('big data 3')
    end

    it 'trims OpenAI tool result messages' do
      history = []
      4.times do |i|
        history << { role: 'tool', tool_call_id: "tc_#{i}", content: "big data #{i}", output_id: i + 1 }
        history << { role: 'assistant', content: "Response #{i}" }
      end

      trimmed = repl.send(:trim_old_outputs, history)
      tool_msgs = trimmed.select { |m| m[:role].to_s == 'tool' }
      expect(tool_msgs[0][:content]).to include('recall_output')
      expect(tool_msgs[1][:content]).to include('recall_output')
      expect(tool_msgs[2][:content]).to eq('big data 2')
    end

    it 'passes through messages without output_id unchanged' do
      history = [
        { role: :user, content: "hello" },
        { role: :assistant, content: "hi" }
      ]
      trimmed = repl.send(:trim_old_outputs, history)
      expect(trimmed[0][:content]).to eq("hello")
      expect(trimmed[1][:content]).to eq("hi")
    end
  end

  describe '/expand command' do
    before do
      allow(Readline).to receive(:respond_to?).with(:parse_and_bind).and_return(false)
    end

    it 'displays full output for a valid expand id' do
      readline_count = 0
      allow(Readline).to receive(:readline) do
        readline_count += 1
        case readline_count
        when 1
          # Set omitted output on the channel (where /expand reads from)
          channel = repl.instance_variable_get(:@channel)
          channel.instance_variable_get(:@omitted_outputs)[1] = "full omitted display"
          '/expand 1'
        when 2 then nil
        end
      end

      output = capture_stdout { repl.interactive }
      expect(output).to include('full omitted display')
    end

    it 'shows error for invalid expand id' do
      readline_count = 0
      allow(Readline).to receive(:readline) do
        readline_count += 1
        case readline_count
        when 1 then '/expand 999'
        when 2 then nil
        end
      end

      output = capture_stdout { repl.interactive }
      expect(output).to include('No omitted output with id 999')
    end
  end

  describe 'direct execution stores output_id in history' do
    it 'tags history entry with output_id' do
      allow(Readline).to receive(:respond_to?).with(:parse_and_bind).and_return(false)

      call_count = 0
      allow(Readline).to receive(:readline) do
        call_count += 1
        call_count == 1 ? '> 1 + 1' : nil
      end

      capture_stdout { repl.interactive }

      history = repl.instance_variable_get(:@history)
      expect(history.first[:output_id]).to be_a(Integer)
    end
  end

  describe '#resume' do
    let(:mock_session) do
      double('Session',
        id: 42,
        query: 'find user 123',
        name: 'sf_user_123',
        conversation: [
          { role: 'user', content: 'find user 123' },
          { role: 'assistant', content: 'Looking up user 123...' }
        ].to_json,
        console_output: "ai> find user 123\nLooking up user 123...\n",
        input_tokens: 100,
        output_tokens: 50,
        duration_ms: 5000,
        model: 'claude-sonnet-4-6'
      )
    end

    it 'replays previous console output' do
      allow(Readline).to receive(:readline).and_return(nil) # immediate Ctrl-D
      allow(Readline).to receive(:respond_to?).with(:parse_and_bind).and_return(false)

      output = capture_stdout { repl.resume(mock_session) }
      expect(output).to include('Replaying previous session output')
      expect(output).to include('find user 123')
      expect(output).to include('End of previous output')
    end

    it 'restores token counts from session' do
      allow(Readline).to receive(:readline).and_return(nil)
      allow(Readline).to receive(:respond_to?).with(:parse_and_bind).and_return(false)

      output = capture_stdout { repl.resume(mock_session) }
      # Session summary should show restored token counts
      expect(output).to include('in: 100')
      expect(output).to include('out: 50')
    end

    it 'continues interactive loop after replay' do
      # After replay, user types a new query then exits
      allow(Readline).to receive(:respond_to?).with(:parse_and_bind).and_return(false)
      call_count = 0
      allow(Readline).to receive(:readline) do
        call_count += 1
        call_count == 1 ? 'exit' : nil
      end

      output = capture_stdout { repl.resume(mock_session) }
      expect(output).to include('Left RailsConsoleAi interactive mode')
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
