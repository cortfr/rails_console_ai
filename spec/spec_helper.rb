require 'webmock/rspec'
require 'readline'
require 'rails_console_ai'

WebMock.disable_net_connect!

# The safety guards keep their runtime state in thread-locals: which guards are
# blocking, what has been allowed for this session, whether guards are bypassed.
# That is process-global state, so one example that sets an allowlist and doesn't
# clear it can make a later example's guard silently permit what it asserts is
# blocked. Reset them the same way the configuration is reset.
RAILS_CONSOLE_AI_THREAD_LOCALS = %i[
  rails_console_ai_allowlist
  rails_console_ai_block_all_db
  rails_console_ai_block_http
  rails_console_ai_block_in_process_requests
  rails_console_ai_block_writes
  rails_console_ai_bypass_guards
  rails_console_ai_bypass_methods
  rails_console_ai_guards_disabled
  rails_console_ai_last_safety_error
  rails_console_ai_session_active
].freeze

RSpec.configure do |config|
  config.before(:each) do
    RailsConsoleAi.reset_configuration!
    # The interactive-loop specs drive the REPL by stubbing Readline. Pin the
    # editor so they don't depend on whether Reline is installed; the Reline
    # path has its own coverage in spec/line_editor_spec.rb.
    RailsConsoleAi.configuration.line_editor = :readline
    RAILS_CONSOLE_AI_THREAD_LOCALS.each { |key| Thread.current[key] = nil }
  end
end
