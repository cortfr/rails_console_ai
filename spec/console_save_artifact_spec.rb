require 'spec_helper'
require 'active_record'
require 'rails_console_ai/safety_guards'

begin
  require 'sqlite3'
  SQLITE3_AVAILABLE = true unless defined?(SQLITE3_AVAILABLE)
rescue LoadError
  SQLITE3_AVAILABLE = false unless defined?(SQLITE3_AVAILABLE)
end

# The way out of the output-token cap: content that already exists as a Ruby
# value goes straight from the console into the artifact, without passing
# through the model's response. See spec/conversation_engine_truncation_spec.rb
# for the failure this exists to avoid.
RSpec.describe 'RailsConsoleAi.save_artifact', if: SQLITE3_AVAILABLE do
  before(:all) do
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    RailsConsoleAi.setup_artifacts_table!(ActiveRecord::Base.connection)
    require_relative '../app/models/rails_console_ai/artifact'
  end

  after(:all) { ActiveRecord::Base.remove_connection }

  let(:model) { RailsConsoleAi::Artifact }

  before do
    model.delete_all
    RailsConsoleAi.configure { |c| c.base_url = 'https://secure.example.com' }
    RailsConsoleAi.current_session_id = nil
    RailsConsoleAi.current_user = nil
  end

  after do
    RailsConsoleAi.configure { |c| c.base_url = nil }
    RailsConsoleAi.current_session_id = nil
    RailsConsoleAi.current_user = nil
  end

  it 'stores the string byte for byte' do
    html = "<!DOCTYPE html>\n<html>\n<body>“smart quotes” & \\n literals</body>\n</html>\n"
    RailsConsoleAi.save_artifact(name: 'Migration plan', content: html)
    expect(model.last.content).to eq(html)
  end

  it 'returns a URL the user can open' do
    url = RailsConsoleAi.save_artifact(name: 'Migration plan', content: '<h1>hi</h1>')
    expect(url).to eq("https://secure.example.com/rails_console_ai/artifacts/#{model.last.slug}")
  end

  it 'date-stamps the name the same way the tool does' do
    RailsConsoleAi.save_artifact(name: 'Migration plan', content: '<h1>hi</h1>')
    expect(model.last.name).to match(/\A\d{8}_Migration plan\z/)
  end

  it 'replaces an artifact saved under the same name and bumps its revision' do
    RailsConsoleAi.save_artifact(name: 'Migration plan', content: 'first')
    RailsConsoleAi.save_artifact(name: 'Migration plan', content: 'second')

    expect(model.count).to eq(1)
    expect(model.last.content).to eq('second')
    expect(model.last.revision).to eq(2)
  end

  it 'ties the artifact to the session and user that produced it' do
    RailsConsoleAi.current_session_id = 1618
    RailsConsoleAi.current_user = 'frank'
    RailsConsoleAi.save_artifact(name: 'Migration plan', content: '<h1>hi</h1>')

    expect(model.last.session_id).to eq(1618)
    expect(model.last.created_by).to eq('frank')
  end

  describe 'content type' do
    it 'takes the one it is given' do
      RailsConsoleAi.save_artifact(name: 'Extract', content: 'a,b\n1,2', content_type: 'text/csv')
      expect(model.last.content_type).to eq('text/csv')
    end

    it 'recognises HTML' do
      RailsConsoleAi.save_artifact(name: 'Plan', content: "<!DOCTYPE html>\n<html></html>")
      expect(model.last.content_type).to eq('text/html')
    end

    it 'recognises JSON' do
      RailsConsoleAi.save_artifact(name: 'Dump', content: '[{"id":1}]')
      expect(model.last.content_type).to eq('application/json')
    end

    # The value becomes a Content-Type header, so an unrecognised shape has to
    # land somewhere inert rather than being guessed into something executable.
    it 'falls back to text/plain rather than guessing' do
      RailsConsoleAi.save_artifact(name: 'Notes', content: 'just some text')
      expect(model.last.content_type).to eq('text/plain')
    end
  end

  # The documented way to save a large file is `RailsConsoleAi.save_artifact`
  # inside execute_code — which runs with the database_writes guard active. The
  # guard has to let the gem's own artifacts table through, or the escape hatch
  # from the output-token cap is blocked in the default configuration.
  it 'writes through the database_writes guard, as the save_artifact tool does' do
    RailsConsoleAi::BuiltinGuards.ensure_write_blocker_installed!
    RailsConsoleAi::GuardState[:block_writes] = true
    begin
      expect {
        RailsConsoleAi.save_artifact(name: 'Migration plan', content: '<h1>hi</h1>')
      }.not_to raise_error
      expect(model.count).to eq(1)
    ensure
      RailsConsoleAi::GuardState[:block_writes] = false
    end
  end

  # Second time this has bitten: `Artifact` written bare inside `class << self`
  # resolves fine once the model is loaded, so the whole suite passes — and then
  # fails in a real app, where Rails is the one resolving it. The enclosing scope
  # there is the singleton class, which is anonymous, so the classic autoloader
  # has no namespace to work from and goes looking for a top-level Artifact.
  # Reproducing that needs Rails' dependency machinery, so guard the shape.
  describe 'model resolution' do
    it 'reaches the model by its full path' do
      expect(RailsConsoleAi.send(:artifact_model)).to eq(model)
    end

    it 'never names the constant unqualified' do
      code = File.readlines(File.expand_path('../lib/rails_console_ai.rb', __dir__))
                 .reject { |line| line.strip.start_with?('#') }
      offenders = code.grep(/(?<!RailsConsoleAi::)\bArtifact\b(?!s)/)
      expect(offenders).to be_empty
    end

    it 'says so plainly when the engine is not loaded at all' do
      allow(RailsConsoleAi).to receive(:artifact_model).and_return(nil)
      expect {
        RailsConsoleAi.save_artifact(name: 'Plan', content: 'x')
      }.to raise_error(/Rails engine loaded/)
    end
  end

  describe 'when it cannot save' do
    it 'raises rather than returning a URL to nothing' do
      expect {
        RailsConsoleAi.save_artifact(name: '', content: '<h1>hi</h1>')
      }.to raise_error(ArgumentError, /Could not save artifact/)
    end

    it 'reports content over the size cap' do
      expect {
        RailsConsoleAi.save_artifact(name: 'Huge', content: 'x' * (model::MAX_BYTES + 1))
      }.to raise_error(ArgumentError, /over the/)
    end
  end
end
