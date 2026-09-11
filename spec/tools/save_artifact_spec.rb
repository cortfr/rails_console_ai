require 'spec_helper'
require 'active_record'
require 'rails_console_ai/executor'
require 'rails_console_ai/tools/registry'

begin
  require 'sqlite3'
  SQLITE3_AVAILABLE = true unless defined?(SQLITE3_AVAILABLE)
rescue LoadError
  SQLITE3_AVAILABLE = false unless defined?(SQLITE3_AVAILABLE)
end

RSpec.describe 'save_artifact tool', if: SQLITE3_AVAILABLE do
  before(:all) do
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    RailsConsoleAi.setup_artifacts_table!(ActiveRecord::Base.connection)
    require_relative '../../app/models/rails_console_ai/artifact'
  end

  after(:all) { ActiveRecord::Base.remove_connection }

  let(:channel) { double('channel', display_status: nil) }
  let(:executor) { RailsConsoleAi::Executor.new(binding, channel: channel) }
  let(:registry) { RailsConsoleAi::Tools::Registry.new(executor: executor, channel: channel) }

  before do
    RailsConsoleAi::Artifact.delete_all
    RailsConsoleAi.current_session_id = nil
    RailsConsoleAi.current_user = nil
  end

  after do
    RailsConsoleAi.current_session_id = nil
    RailsConsoleAi.current_user = nil
  end

  # Tool arguments arrive from the provider with string keys.
  def save(**overrides)
    args = {
      'name' => 'Q3 churn summary',
      'content_type' => 'text/html',
      'content' => '<h1>Churn</h1>'
    }.merge(overrides.transform_keys(&:to_s))
    registry.execute('save_artifact', args)
  end

  it 'is offered to the model' do
    expect(registry.definitions.map { |d| d[:name] }).to include('save_artifact')
  end

  it 'persists the artifact, stamped with the current date' do
    save
    artifact = RailsConsoleAi::Artifact.last
    expect(artifact.name).to eq("#{Time.now.strftime('%Y%m%d')}_Q3 churn summary")
    expect(artifact.content).to eq('<h1>Churn</h1>')
  end

  it 'returns a URL for the user, not just a confirmation' do
    result = save
    slug = RailsConsoleAi::Artifact.last.slug
    expect(result).to include("/rails_console_ai/artifacts/#{slug}")
    expect(result).to include('give them that URL')
  end

  it 'ties the artifact to the session and user that produced it' do
    RailsConsoleAi.current_session_id = 4821
    RailsConsoleAi.current_user = 'frank'
    save

    artifact = RailsConsoleAi::Artifact.last
    expect(artifact.session_id).to eq(4821)
    expect(artifact.created_by).to eq('frank')
  end

  it 'tells the console user what was saved' do
    expect(channel).to receive(:display_status).with(/Artifact saved: \d{8}_Q3 churn summary/)
    save
  end

  describe 'when the model sends something unusable' do
    it 'reports a rejected content type instead of raising' do
      result = save(content_type: 'application/javascript')

      expect(result).to start_with('FAILED')
      expect(result).to include('must be one of')
      expect(RailsConsoleAi::Artifact.count).to eq(0)
    end

    it 'reports content over the size cap' do
      result = save(content: 'a' * (RailsConsoleAi::Artifact::MAX_BYTES + 1))

      expect(result).to start_with('FAILED')
      expect(result).to include('over the')
      expect(RailsConsoleAi::Artifact.count).to eq(0)
    end

    # Stamping a blank name would otherwise smuggle it past the presence check.
    it 'reports a missing name' do
      expect(save(name: '')).to start_with('FAILED')
      expect(RailsConsoleAi::Artifact.count).to eq(0)
    end
  end

  describe 'without the table' do
    it 'points the user at ai_db_setup rather than surfacing an AR error' do
      allow(RailsConsoleAi::Artifact).to receive(:available?).and_return(false)

      result = save
      expect(result).to include('does not exist')
      expect(result).to include('ai_db_setup')
    end
  end

  describe 'finding the model' do
    # Rails autoloads app/models on first reference. `defined?` does not count as
    # a reference, so guarding with it reports "no engine" in a healthy app and
    # the tool silently never runs — which is exactly what happened on Rails 5.2.
    it 'resolves the model by referencing the constant, not by asking defined?' do
      expect(registry.send(:artifact_model)).to eq(RailsConsoleAi::Artifact)
    end

    it 'reports no engine only when the constant genuinely is not there' do
      allow(registry).to receive(:artifact_model).and_return(nil)
      expect(save).to include('need the Rails engine loaded')
    end
  end

  describe 'sub-agents' do
    let(:sub_registry) do
      RailsConsoleAi::Tools::Registry.new(executor: executor, mode: :sub_agent, channel: channel)
    end

    # A skill or agent whose whole job is producing a report needs somewhere to
    # put it, so the tool has to reach past the main conversation.
    it 'can save artifacts too' do
      expect(sub_registry.definitions.map { |d| d[:name] }).to include('save_artifact')
    end

    it 'is withheld from an agent that declares a narrower tool list' do
      narrow = RailsConsoleAi::Tools::Registry.new(
        executor: executor, mode: :sub_agent, channel: channel, allowed_tools: ['execute_code']
      )
      expect(narrow.definitions.map { |d| d[:name] }).not_to include('save_artifact')
    end
  end
end
