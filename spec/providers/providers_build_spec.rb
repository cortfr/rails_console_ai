require 'spec_helper'
require 'rails_console_ai/providers/base'

RSpec.describe RailsConsoleAi::Providers, '.build' do
  # Stub the AWS SDK so the bedrock provider can load
  before do
    stub_const('Aws::BedrockRuntime::Errors::ServiceError', Class.new(StandardError))
    stub_const('Aws::BedrockRuntime::Client', Class.new {
      def initialize(opts = {}); end
      def converse(params); end
    })
  end

  it 'builds an Anthropic provider' do
    config = RailsConsoleAi::Configuration.new
    config.provider = :anthropic
    config.api_key = 'test-key'
    provider = described_class.build(config)
    expect(provider).to be_a(RailsConsoleAi::Providers::Anthropic)
  end

  it 'builds an OpenAI provider' do
    config = RailsConsoleAi::Configuration.new
    config.provider = :openai
    config.api_key = 'test-key'
    provider = described_class.build(config)
    expect(provider).to be_a(RailsConsoleAi::Providers::OpenAI)
  end

  it 'builds a Local provider' do
    config = RailsConsoleAi::Configuration.new
    config.provider = :local
    provider = described_class.build(config)
    expect(provider).to be_a(RailsConsoleAi::Providers::Local)
  end

  it 'builds a Bedrock provider' do
    config = RailsConsoleAi::Configuration.new
    config.provider = :bedrock
    provider = described_class.build(config)
    expect(provider).to be_a(RailsConsoleAi::Providers::Bedrock)
  end

  it 'raises on unknown provider' do
    config = RailsConsoleAi::Configuration.new
    config.provider = :unknown
    expect { described_class.build(config) }.to raise_error(
      RailsConsoleAi::ConfigurationError, /Unknown provider/
    )
  end
end
