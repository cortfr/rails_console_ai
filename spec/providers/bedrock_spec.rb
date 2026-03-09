require 'spec_helper'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/providers/bedrock'

# Stub the AWS SDK module structure for tests
module Aws
  module BedrockRuntime
    module Errors
      class ServiceError < StandardError; end
    end
    class Client
      def initialize(opts = {}); end
      def converse(params); end
    end
  end
end

RSpec.describe RailsConsoleAi::Providers::Bedrock do
  let(:config) do
    RailsConsoleAi::Configuration.new.tap do |c|
      c.provider = :bedrock
      c.model = 'anthropic.claude-3-5-sonnet-20241022-v2:0'
      c.max_tokens = 1024
      c.temperature = 0.5
      c.bedrock_region = 'us-east-1'
    end
  end

  subject(:provider) { described_class.new(config) }

  let(:mock_client) { instance_double(Aws::BedrockRuntime::Client) }

  before do
    allow(Aws::BedrockRuntime::Client).to receive(:new).and_return(mock_client)
  end

  def build_response(content_blocks, stop_reason: 'end_turn', input_tokens: 10, output_tokens: 5)
    usage = double('usage', input_tokens: input_tokens, output_tokens: output_tokens)
    message = double('message', content: content_blocks)
    output = double('output', message: message)
    double('response', output: output, usage: usage, stop_reason: stop_reason)
  end

  def text_block(text)
    double('text_block', text: text, tool_use: nil).tap do |b|
      allow(b).to receive(:respond_to?).with(:text).and_return(true)
      allow(b).to receive(:respond_to?).with(:tool_use).and_return(false)
    end
  end

  def tool_use_block(id:, name:, input: {})
    tu = double('tool_use', tool_use_id: id, name: name, input: input)
    double('tool_use_block', text: nil, tool_use: tu).tap do |b|
      allow(b).to receive(:respond_to?).with(:text).and_return(false)
      allow(b).to receive(:respond_to?).with(:tool_use).and_return(true)
    end
  end

  describe '#chat' do
    let(:messages) { [{ role: :user, content: 'Hello' }] }

    it 'returns a ChatResult with token usage' do
      response = build_response([text_block('Hello back!')])
      allow(mock_client).to receive(:converse).and_return(response)

      result = provider.chat(messages, system_prompt: 'Be helpful')
      expect(result.text).to eq('Hello back!')
      expect(result.input_tokens).to eq(10)
      expect(result.output_tokens).to eq(5)
      expect(result.stop_reason).to eq(:end_turn)
    end

    it 'raises ProviderError on AWS errors' do
      allow(mock_client).to receive(:converse)
        .and_raise(Aws::BedrockRuntime::Errors::ServiceError.new('Access denied'))

      expect { provider.chat(messages) }.to raise_error(
        RailsConsoleAi::Providers::ProviderError, /AWS Bedrock error.*Access denied/
      )
    end
  end

  describe '#chat_with_tools' do
    let(:messages) { [{ role: :user, content: 'List tables' }] }
    let(:mock_tools) do
      tools = double('tools')
      allow(tools).to receive(:to_bedrock_format).and_return([
        { tool_spec: { name: 'list_tables', description: 'List tables', input_schema: { json: { 'type' => 'object', 'properties' => {} } } } }
      ])
      tools
    end

    it 'includes tool_config and parses tool_use responses' do
      response = build_response(
        [text_block('Let me check.'), tool_use_block(id: 'tool_123', name: 'list_tables')],
        stop_reason: 'tool_use',
        input_tokens: 50,
        output_tokens: 20
      )
      allow(mock_client).to receive(:converse).and_return(response)

      result = provider.chat_with_tools(messages, tools: mock_tools)
      expect(result.stop_reason).to eq(:tool_use)
      expect(result.tool_use?).to be true
      expect(result.tool_calls.length).to eq(1)
      expect(result.tool_calls[0][:name]).to eq('list_tables')
      expect(result.tool_calls[0][:id]).to eq('tool_123')
      expect(result.text).to eq('Let me check.')
    end

    it 'passes tool_config in the converse call' do
      response = build_response([text_block('Done.')])
      expect(mock_client).to receive(:converse).with(hash_including(:tool_config)).and_return(response)

      provider.chat_with_tools(messages, tools: mock_tools)
    end
  end

  describe '#format_assistant_message' do
    it 'builds a Bedrock-format assistant message with tool calls' do
      result = RailsConsoleAi::Providers::ChatResult.new(
        text: 'Checking...',
        tool_calls: [{ id: 'tool_1', name: 'list_tables', arguments: {} }]
      )
      msg = provider.format_assistant_message(result)
      expect(msg[:role]).to eq('assistant')
      expect(msg[:content].length).to eq(2)
      expect(msg[:content][0]).to eq({ text: 'Checking...' })
      expect(msg[:content][1][:tool_use][:tool_use_id]).to eq('tool_1')
      expect(msg[:content][1][:tool_use][:name]).to eq('list_tables')
    end
  end

  describe '#format_tool_result' do
    it 'builds a Bedrock-format tool result message' do
      msg = provider.format_tool_result('tool_1', 'users, posts')
      expect(msg[:role]).to eq('user')
      expect(msg[:content][0][:tool_result][:tool_use_id]).to eq('tool_1')
      expect(msg[:content][0][:tool_result][:content]).to eq([{ text: 'users, posts' }])
    end
  end
end
