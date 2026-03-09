require 'spec_helper'
require 'rails_console_ai/providers/base'

RSpec.describe RailsConsoleAi::Providers do
  describe '.build' do
    it 'builds an Anthropic provider for :anthropic' do
      RailsConsoleAi.configure { |c| c.provider = :anthropic }
      provider = described_class.build
      expect(provider).to be_a(RailsConsoleAi::Providers::Anthropic)
    end

    it 'builds an OpenAI provider for :openai' do
      RailsConsoleAi.configure { |c| c.provider = :openai }
      provider = described_class.build
      expect(provider).to be_a(RailsConsoleAi::Providers::OpenAI)
    end

    it 'raises for unknown provider' do
      RailsConsoleAi.configure { |c| c.provider = :unknown }
      expect { described_class.build }.to raise_error(RailsConsoleAi::ConfigurationError)
    end
  end
end
