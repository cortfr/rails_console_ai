require 'webmock/rspec'
require 'readline'
require 'rails_console_ai'

WebMock.disable_net_connect!

# The safety guards keep runtime state per thread (RailsConsoleAi::GuardState):
# which guards are blocking, what has been allowed for this session, whether
# guards are bypassed. One example that sets an allowlist and doesn't clear it
# can make a later example's guard silently permit what it asserts is blocked.
# Reset it the same way the configuration is reset — and again afterwards, so
# nothing is left set for a before(:all) hook in the next file.
RSpec.configure do |config|
  config.before(:each) do
    RailsConsoleAi.reset_configuration!
    # The interactive-loop specs drive the REPL by stubbing Readline. Pin the
    # editor so they don't depend on whether Reline is installed; the Reline
    # path has its own coverage in spec/line_editor_spec.rb.
    RailsConsoleAi.configuration.line_editor = :readline
    RailsConsoleAi::GuardState.reset!
  end

  config.after(:each) do
    RailsConsoleAi::GuardState.reset!
  end
end
