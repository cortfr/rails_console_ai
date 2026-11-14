require_relative 'spec_helper'
require 'rails_console_ai/tools/registry'

# The ground truth for thinking replay. spec/thinking_replay_spec.rb asserts the
# requests are SHAPED so replayed thinking stays valid; this asserts the API
# actually accepts them — including under the history-editing check, which
# rejects a replayed thinking block if anything before it has changed.
#
# Needs a model that thinks without being asked to (Claude Sonnet 5.5 by
# default). THINKING_REPLAY_MODEL overrides it.
#
# Run with:  ANTHROPIC_API_KEY=sk-... bundle exec rspec spec/integration/thinking_replay_integration_spec.rb
RSpec.describe 'thinking replay (real API)' do
  include IntegrationHelpers

  MODEL = ENV['THINKING_REPLAY_MODEL'] ||
          (IntegrationHelpers::PROVIDER == :bedrock ? 'global.anthropic.claude-sonnet-5-5' : 'claude-sonnet-5-5')

  # Adaptive thinking skips trivial requests, so the task has to need a plan.
  TASK = 'Three warehouses hold 120, 75 and 210 units. Each day warehouse A ships 5% of its stock to B, ' \
         'B ships 11% of its stock to C, and C ships 9% of its stock to A, all computed from start-of-day ' \
         'stock. Work out how to find the first day on which C holds less than A, compute it with ' \
         'execute_code, then check your answer with a SEPARATE second execute_code call that prints the ' \
         'stock of A and C on that day and the day before. Reply with only the day number.'.freeze
  FOLLOW_UP = 'Now find the first day on which B holds more than C, again with execute_code. ' \
              'Reply with only the day number.'.freeze

  before(:each) do
    skip_unless_llm_configured
    RailsConsoleAi.reset_configuration!
  end

  let(:tmpdir) { Dir.mktmpdir('rails_console_ai_thinking_test') }
  let(:storage) { RailsConsoleAi::Storage::FileStorage.new(tmpdir) }
  let(:channel) { IntegrationHelpers::CaptureChannel.new }

  after { FileUtils.rm_rf(tmpdir) }

  def thinking_engine
    engine = build_engine(storage: storage, channel: channel)
    RailsConsoleAi.configuration.model = MODEL
    RailsConsoleAi.configuration.temperature = nil
    RailsConsoleAi.configuration.effort = 'high'
    engine
  end

  def thinking_blocks(history)
    history.flat_map { |m| m[:content].is_a?(Array) ? m[:content] : [] }
           .select { |b| b['type'] == 'thinking' || b['type'] == 'redacted_thinking' || b.key?(:reasoning_content) }
  end

  def skip_if_model_did_not_think(history)
    skip "#{MODEL} returned no thinking blocks on this run — nothing to verify" if thinking_blocks(history).empty?
  end

  it 'completes a multi-round tool loop while replaying thinking', :slow do
    engine = thinking_engine

    engine.process_message(TASK)

    history = engine.history
    skip_if_model_did_not_think(history)
    expect(channel.messages.grep(/\[error\]/)).to be_empty
    expect(channel.messages.grep(/rejected the replayed thinking/)).to be_empty
    expect(tool_names_called(channel).count('execute_code')).to be >= 2
    expect(history.last[:content].to_s).to match(/\d/)
  end

  # Opting a request into `prefix_mismatch_behavior: "error"` enforces the
  # history-editing check whatever the account's age, so this fails the moment
  # the harness rewrites something a replayed block is bound to.
  context 'with the history-editing check enforced', if: IntegrationHelpers::PROVIDER == :anthropic do
    before do
      allow_any_instance_of(Faraday::Connection).to receive(:post).and_wrap_original do |original, path, body, headers|
        payload = JSON.parse(body)
        payload['thinking'] = { 'type' => 'adaptive', 'block_binding' => { 'prefix_mismatch_behavior' => 'error' } }
        original.call(path, JSON.generate(payload),
                      (headers || {}).merge('anthropic-beta' => 'thinking-binding-controls-2026-08-01'))
      end
    end

    it 'gets through a tool loop and a second turn, and the check does reject an edited history', :slow do
      engine = thinking_engine

      engine.process_message(TASK)
      skip_if_model_did_not_think(engine.history)
      engine.process_message(FOLLOW_UP)

      expect(channel.messages.grep(/\[error\]/)).to be_empty
      expect(channel.messages.grep(/rejected the replayed thinking/)).to be_empty
      expect(engine.history.last[:content].to_s).to match(/\d/)

      # The control: the same conversation with its opening message altered must
      # be refused, or the assertions above prove nothing. Every thinking block
      # is bound to that message, however few of them this run produced.
      history = Marshal.load(Marshal.dump(engine.history))
      history.first[:content] = "#{history.first[:content]} (edited after the fact)"

      provider = engine.send(:provider)
      tools = RailsConsoleAi::Tools::Registry.new(executor: engine.instance_variable_get(:@executor), channel: channel)
      expect {
        provider.chat_with_tools(history + [{ role: :user, content: 'thanks' }], tools: tools, system_prompt: engine.context)
      }.to raise_error(RailsConsoleAi::Providers::ProviderError, /thinking/)
    end
  end
end
