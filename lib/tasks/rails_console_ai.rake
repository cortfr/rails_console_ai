namespace :rails_console_ai do
  desc "Start the RailsConsoleAi Slack bot (Socket Mode)"
  task slack: :environment do
    require 'rails_console_ai/slack_bot'
    RailsConsoleAi::SlackBot.new.start
  end

  desc "Run the RailsConsoleAi agent runner (polls DB for queued agent runs)"
  task agents: :environment do
    require 'rails_console_ai/agent_runner'
    concurrency = Integer(ENV['AGENT_CONCURRENCY'] || RailsConsoleAi::AgentRunner::DEFAULT_CONCURRENCY)
    RailsConsoleAi::AgentRunner.new(concurrency: concurrency).start
  end
end
