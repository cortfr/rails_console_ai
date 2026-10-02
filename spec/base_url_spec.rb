require 'spec_helper'

# An artifact URL is read in a terminal, pasted into Slack and opened on a phone,
# so it has to carry a host. This is where that host comes from.
RSpec.describe 'RailsConsoleAi.base_url' do
  def configure(value)
    RailsConsoleAi.configure { |c| c.base_url = value }
  end

  describe 'when configured explicitly' do
    it 'uses the configured value' do
      configure('https://secure.apptoto.com')
      expect(RailsConsoleAi.base_url).to eq('https://secure.apptoto.com')
    end

    it 'drops a trailing slash so paths join cleanly' do
      configure('https://secure.apptoto.com/')
      expect(RailsConsoleAi.base_url).to eq('https://secure.apptoto.com')
    end

    it 'assumes https when given a bare host' do
      configure('secure.apptoto.com')
      expect(RailsConsoleAi.base_url).to eq('https://secure.apptoto.com')
    end

    it 'leaves a non-https scheme alone' do
      configure('http://localhost:3000')
      expect(RailsConsoleAi.base_url).to eq('http://localhost:3000')
    end

    it 'ignores blank values' do
      configure('   ')
      expect(RailsConsoleAi.base_url).to eq('')
    end
  end

  describe 'without configuration' do
    it 'falls back to a relative path when Rails offers no host' do
      expect(RailsConsoleAi.base_url).to eq('')
    end
  end

  describe 'falling back to the app url options' do
    before { allow(RailsConsoleAi).to receive(:rails_default_url_base).and_call_original }

    def with_url_options(opts)
      routes = double(default_url_options: opts)
      mailer = double(default_url_options: {})
      config = double(action_mailer: mailer)
      app = double(routes: routes, config: config)
      stub_const('Rails', double(application: app))
      allow(Rails).to receive(:respond_to?).with(:application).and_return(true)
    end

    it 'builds from host and protocol' do
      with_url_options(host: 'secure.apptoto.com', protocol: 'https')
      expect(RailsConsoleAi.base_url).to eq('https://secure.apptoto.com')
    end

    it 'assumes https when only a host is declared' do
      with_url_options(host: 'secure.apptoto.com')
      expect(RailsConsoleAi.base_url).to eq('https://secure.apptoto.com')
    end

    it 'keeps a non-standard port' do
      with_url_options(host: 'localhost', protocol: 'http', port: 3000)
      expect(RailsConsoleAi.base_url).to eq('http://localhost:3000')
    end

    it 'omits the port when it is the default for the scheme' do
      with_url_options(host: 'secure.apptoto.com', protocol: 'https', port: 443)
      expect(RailsConsoleAi.base_url).to eq('https://secure.apptoto.com')
    end

    it 'stays relative when the host is blank' do
      with_url_options(host: '')
      expect(RailsConsoleAi.base_url).to eq('')
    end

    it 'is overridden by an explicit setting' do
      with_url_options(host: 'wrong.example.com')
      configure('https://secure.apptoto.com')
      expect(RailsConsoleAi.base_url).to eq('https://secure.apptoto.com')
    end
  end
end

RSpec.describe 'RailsConsoleAi.session_url' do
  before { allow(RailsConsoleAi).to receive(:engine_mount_path).and_return('/rails_console_ai') }

  it 'points at the session page under the engine mount' do
    RailsConsoleAi.configure { |c| c.base_url = 'https://apptoto.com' }
    expect(RailsConsoleAi.session_url(1819)).to eq('https://apptoto.com/rails_console_ai/sessions/1819')
  end

  it 'is relative when no host is known' do
    expect(RailsConsoleAi.session_url(1819)).to eq('/rails_console_ai/sessions/1819')
  end
end
