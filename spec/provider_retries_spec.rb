require 'spec_helper'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/providers/anthropic'

# A failed provider request is not free: the turn is lost, the user re-asks, and
# the retry pays for the whole prompt again from a cold cache. These cover which
# failures are worth another attempt and which are not.
RSpec.describe 'provider request retries' do
  let(:config) do
    RailsConsoleAi::Configuration.new.tap do |c|
      c.provider = :anthropic
      c.api_key = 'test-key'
      c.model = 'claude-sonnet-5'
      c.max_retries = 2
    end
  end
  subject(:provider) { RailsConsoleAi::Providers::Anthropic.new(config) }

  let(:messages) { [{ role: :user, content: 'hello' }] }

  let(:success) do
    {
      status: 200,
      body: {
        content: [{ type: 'text', text: 'ok' }],
        usage: { input_tokens: 5, output_tokens: 5 },
        stop_reason: 'end_turn'
      }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    }
  end

  before do
    # Don't actually wait out the backoff.
    allow(provider).to receive(:sleep)
    allow(RailsConsoleAi.logger).to receive(:warn)
  end

  it 'retries a 429 and returns the eventual success' do
    stub_request(:post, 'https://api.anthropic.com/v1/messages')
      .to_return({ status: 429, body: '{"error":{"message":"rate limited"}}' }, success)

    result = provider.chat(messages, system_prompt: 'p')

    expect(result.text).to eq('ok')
    expect(a_request(:post, 'https://api.anthropic.com/v1/messages')).to have_been_made.twice
  end

  it 'retries an overloaded 529' do
    stub_request(:post, 'https://api.anthropic.com/v1/messages')
      .to_return({ status: 529, body: '{"error":{"message":"overloaded"}}' }, success)

    expect(provider.chat(messages, system_prompt: 'p').text).to eq('ok')
  end

  it 'gives up after max_retries and surfaces the provider error' do
    stub_request(:post, 'https://api.anthropic.com/v1/messages')
      .to_return(status: 503, body: '{"error":{"message":"unavailable"}}')

    expect { provider.chat(messages, system_prompt: 'p') }
      .to raise_error(RailsConsoleAi::Providers::ProviderError, /503/)
    # The initial attempt plus two retries.
    expect(a_request(:post, 'https://api.anthropic.com/v1/messages')).to have_been_made.times(3)
  end

  # A malformed request stays malformed; retrying it just spends the wall clock.
  it 'does not retry a 400' do
    stub_request(:post, 'https://api.anthropic.com/v1/messages')
      .to_return(status: 400, body: '{"error":{"message":"bad request"}}')

    expect { provider.chat(messages, system_prompt: 'p') }
      .to raise_error(RailsConsoleAi::Providers::ProviderError, /400/)
    expect(a_request(:post, 'https://api.anthropic.com/v1/messages')).to have_been_made.once
  end

  # A request that burned its whole read budget is not obviously going to do
  # better on a second try, and each retry pays again for a generation nobody
  # reads. The error names the knob instead.
  # Faraday distinguishes the two, and so does the retry policy: Net::ReadTimeout
  # becomes Faraday::TimeoutError (the full read budget was spent — don't retry),
  # while Net::OpenTimeout becomes Faraday::ConnectionFailed (failed in ~10s
  # without reaching the model — retry).
  it 'does not retry a read timeout, and says how to raise the budget' do
    stub_request(:post, 'https://api.anthropic.com/v1/messages')
      .to_raise(Faraday::TimeoutError.new('execution expired'))

    expect { provider.chat(messages, system_prompt: 'p') }
      .to raise_error(RailsConsoleAi::Providers::ProviderError, /timed out after 300s.*c\.timeout = 600/m)
    expect(a_request(:post, 'https://api.anthropic.com/v1/messages')).to have_been_made.once
  end

  it 'retries a connect timeout' do
    stub_request(:post, 'https://api.anthropic.com/v1/messages').to_timeout.then.to_return(success)

    expect(provider.chat(messages, system_prompt: 'p').text).to eq('ok')
    expect(a_request(:post, 'https://api.anthropic.com/v1/messages')).to have_been_made.twice
  end

  it 'retries a connection failure, then reports it if it persists' do
    stub_request(:post, 'https://api.anthropic.com/v1/messages')
      .to_raise(Faraday::ConnectionFailed.new('connection refused'))

    expect { provider.chat(messages, system_prompt: 'p') }
      .to raise_error(RailsConsoleAi::Providers::ProviderError, /Could not reach the provider/)
    expect(a_request(:post, 'https://api.anthropic.com/v1/messages')).to have_been_made.times(3)
  end

  it 'honours Retry-After over exponential backoff' do
    stub_request(:post, 'https://api.anthropic.com/v1/messages')
      .to_return({ status: 429, body: '{}', headers: { 'Retry-After' => '7' } }, success)

    provider.chat(messages, system_prompt: 'p')

    expect(provider).to have_received(:sleep).with(7.0)
  end

  it 'can be turned off with max_retries = 0' do
    config.max_retries = 0
    stub_request(:post, 'https://api.anthropic.com/v1/messages')
      .to_return(status: 503, body: '{}')

    expect { provider.chat(messages, system_prompt: 'p') }
      .to raise_error(RailsConsoleAi::Providers::ProviderError)
    expect(a_request(:post, 'https://api.anthropic.com/v1/messages')).to have_been_made.once
  end

  describe 'connection timeouts' do
    it 'gives the read and connect phases separate budgets' do
      config.timeout = 300
      config.open_timeout = 10

      conn = provider.send(:build_connection, 'https://example.test')

      expect(conn.options.timeout).to eq(300)
      expect(conn.options.open_timeout).to eq(10)
    end
  end
end
