# Integration tests hit a real LLM API. They are:
# - Opt-in: require ANTHROPIC_API_KEY env var
# - Expensive: each test makes real API calls
# - Non-deterministic: LLM responses vary
#
# Run with:  ANTHROPIC_API_KEY=sk-... bundle exec rspec spec/integration/
# Skip:      bundle exec rspec --exclude-pattern 'spec/integration/**/*'
#            (or just run: bundle exec rspec spec/ --exclude-pattern 'spec/integration/**/*')
#
# These tests verify that the LLM makes correct behavioral choices:
# - Does it call the right tools?
# - Does it delegate to sub-agents when appropriate?
# - Does it follow agent instructions?

require 'dotenv'
Dotenv.load('.env.test.local')

require 'webmock/rspec'
WebMock.allow_net_connect!

require 'rails_console_ai'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/conversation_engine'
require 'rails_console_ai/executor'
require 'rails_console_ai/context_builder'
require 'rails_console_ai/sub_agent'
require 'rails_console_ai/agent_loader'
require 'rails_console_ai/storage/file_storage'
require 'tmpdir'

module IntegrationHelpers
  # A channel that captures all output for assertions
  class CaptureChannel < RailsConsoleAi::Channel::Base
    attr_reader :messages, :tool_calls, :statuses

    def initialize
      @messages = []
      @tool_calls = []
      @statuses = []
    end

    def display(text);          @messages << text; end
    def display_thinking(text);  @statuses << text; end
    def display_status(text);    @statuses << text; end
    def display_warning(text);   @messages << "[warn] #{text}"; end
    def display_error(text);     @messages << "[error] #{text}"; end
    def display_tool_call(text); @tool_calls << text; end
    def display_code(code);      end
    def display_result_output(text); end
    def display_result(result);  end
    def prompt(text);            '(no answer provided)'; end
    def confirm(text);           'y'; end
    def user_identity;           'test_user'; end
    def mode;                    'slack'; end  # auto-execute like slack
    def cancelled?;              false; end
    def supports_danger?;        false; end
    def supports_editing?;       false; end
    def wrap_llm_call(&block);   yield; end
    def system_instructions;     nil; end
  end

  # Build a ConversationEngine with a real LLM provider.
  # Tool handlers use real code execution (in a sandboxed binding).
  def build_engine(storage:, channel: nil)
    RailsConsoleAi.configure do |c|
      c.provider = :anthropic
      c.api_key = ENV['ANTHROPIC_API_KEY']
      c.model = 'claude-sonnet-4-6'
      c.temperature = 0.0
      c.max_tool_rounds = 20
      c.storage_adapter = storage
      c.memories_enabled = true
      c.sub_agent_max_rounds = 10
    end

    channel ||= CaptureChannel.new
    binding_context = Object.new.instance_eval { binding }
    engine = RailsConsoleAi::ConversationEngine.new(
      binding_context: binding_context,
      channel: channel
    )
    engine.init_interactive
    engine
  end

  # Collect which tool names were called during engine.process_message
  def tool_names_called(channel)
    channel.tool_calls.map { |tc| tc.split('(').first }
  end
end
