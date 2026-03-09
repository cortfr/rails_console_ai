namespace :rails_console_ai do
  desc "Start the RailsConsoleAi Slack bot (Socket Mode)"
  task slack: :environment do
    require 'rails_console_ai/slack_bot'
    RailsConsoleAi::SlackBot.new.start
  end
end
