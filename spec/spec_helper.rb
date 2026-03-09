require 'webmock/rspec'
require 'rails_console_ai'

WebMock.disable_net_connect!

RSpec.configure do |config|
  config.before(:each) do
    RailsConsoleAi.reset_configuration!
  end
end
