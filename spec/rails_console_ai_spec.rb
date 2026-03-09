require 'spec_helper'

RSpec.describe RailsConsoleAi do
  describe '.configuration' do
    it 'returns a Configuration instance' do
      expect(RailsConsoleAi.configuration).to be_a(RailsConsoleAi::Configuration)
    end

    it 'returns the same instance on repeated calls' do
      expect(RailsConsoleAi.configuration).to equal(RailsConsoleAi.configuration)
    end
  end

  describe '.configure' do
    it 'yields the configuration object' do
      RailsConsoleAi.configure do |config|
        config.provider = :openai
        config.max_tokens = 2048
      end

      expect(RailsConsoleAi.configuration.provider).to eq(:openai)
      expect(RailsConsoleAi.configuration.max_tokens).to eq(2048)
    end
  end

  describe '.reset_configuration!' do
    it 'creates a fresh configuration' do
      RailsConsoleAi.configure { |c| c.provider = :openai }
      RailsConsoleAi.reset_configuration!
      expect(RailsConsoleAi.configuration.provider).to eq(:anthropic)
    end
  end
end
