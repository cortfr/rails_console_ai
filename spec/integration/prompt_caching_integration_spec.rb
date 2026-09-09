require_relative 'spec_helper'
require 'rails_console_ai/tools/registry'

# The cache probe: the only ground truth that prompt caching actually engages.
# spec/prompt_caching_spec.rb asserts the request is SHAPED for caching; this
# asserts the API actually served a cached read. Both are needed — a request can
# be perfectly shaped and still never hit (prefix below the model's cacheable
# minimum, an entry expired, a workspace split).
#
# Run with:  ANTHROPIC_API_KEY=sk-... bundle exec rspec spec/integration/prompt_caching_integration_spec.rb
RSpec.describe 'prompt caching (real API)' do
  include IntegrationHelpers

  before(:each) do
    skip 'ANTHROPIC_API_KEY not set — run with ANTHROPIC_API_KEY=sk-... to enable' unless ENV['ANTHROPIC_API_KEY']
    RailsConsoleAi.reset_configuration!
  end

  let(:tmpdir) { Dir.mktmpdir('rails_console_ai_cache_test') }
  let(:storage) { RailsConsoleAi::Storage::FileStorage.new(tmpdir) }

  after { FileUtils.rm_rf(tmpdir) }

  # The minimum cacheable prefix is model-dependent (512 tokens on Opus 5, 1024 on
  # Sonnet 5) and a shorter prefix silently writes nothing — no error, no marker in
  # usage. The real tool set plus system prompt clears it; a toy prompt would not,
  # and this spec would then fail for the wrong reason.
  it 'serves a cached read on an identical second request', :slow do
    engine = build_engine(storage: storage)
    provider = engine.send(:provider)
    tools = RailsConsoleAi::Tools::Registry.new(executor: engine.instance_variable_get(:@executor))
    system_prompt = engine.context
    messages = [{ role: :user, content: 'Reply with the single word: ok' }]

    first = provider.chat_with_tools(messages, tools: tools, system_prompt: system_prompt)
    second = provider.chat_with_tools(messages, tools: tools, system_prompt: system_prompt)

    expect(first.cache_write_input_tokens.to_i).to be > 0,
      "nothing was written to cache — prefix is probably below the model's cacheable minimum " \
      "(system #{system_prompt.length} chars). usage: #{first.to_h}"
    expect(second.cache_read_input_tokens.to_i).to be > 0,
      "second identical request did not read from cache. usage: #{second.to_h}"
  end

  # The healthy-loop signature: in a warmed-up multi-round loop, reads should
  # dominate full-price input, and writes should be about one round's worth rather
  # than the whole conversation. Writes near the full conversation size on every
  # round means something upstream is rewriting the prefix.
  it 'reads more than it re-bills once a tool loop is warm', :slow do
    channel = IntegrationHelpers::CaptureChannel.new
    engine = build_engine(storage: storage, channel: channel)

    engine.process_message(
      'List the models in this app, then describe two of them, then tell me how many you found.'
    )

    usage = engine.instance_variable_get(:@token_usage).values.first
    skip 'model made no tool calls — nothing to measure' if channel.tool_calls.empty?

    expect(usage[:cache_read]).to be > 0,
      "no cache reads across the loop. usage: #{usage.inspect}"
    expect(usage[:cache_read]).to be > usage[:input],
      "full-price input (#{usage[:input]}) exceeded cache reads (#{usage[:cache_read]}) — " \
      'the prefix is being rewritten between rounds'
  end
end
