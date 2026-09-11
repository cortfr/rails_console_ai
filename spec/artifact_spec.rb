require 'spec_helper'
require 'active_record'

begin
  require 'sqlite3'
  SQLITE3_AVAILABLE = true unless defined?(SQLITE3_AVAILABLE)
rescue LoadError
  SQLITE3_AVAILABLE = false unless defined?(SQLITE3_AVAILABLE)
end

RSpec.describe 'RailsConsoleAi::Artifact', if: SQLITE3_AVAILABLE do
  before(:all) do
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    RailsConsoleAi.setup_artifacts_table!(ActiveRecord::Base.connection)
    require_relative '../app/models/rails_console_ai/artifact'
  end

  after(:all) { ActiveRecord::Base.remove_connection }

  before(:each) { RailsConsoleAi::Artifact.delete_all }

  let(:model) { RailsConsoleAi::Artifact }

  def build(**overrides)
    model.new({
      name: 'Q3 churn summary',
      content_type: 'text/html',
      content: '<h1>Churn</h1>'
    }.merge(overrides))
  end

  describe 'addressing' do
    it 'mints an unguessable token so a link cannot be walked to its neighbour' do
      a, b = build, build
      a.save!
      b.save!

      expect(a.token).to match(/\A[0-9a-f]{32}\z/)
      expect(a.token).not_to eq(b.token)
    end

    it 'keeps a token it was given' do
      artifact = build(token: 'preset-token')
      artifact.save!
      expect(artifact.reload.token).to eq('preset-token')
    end

    it 'finds by token' do
      artifact = build.tap(&:save!)
      expect(model.find_by_token!(artifact.token).id).to eq(artifact.id)
    end
  end

  describe 'content type' do
    it 'accepts the types the UI knows how to serve' do
      model::CONTENT_TYPES.each_key do |type|
        expect(build(content_type: type)).to be_valid, "expected #{type} to be allowed"
      end
    end

    # The value reaches a Content-Type header, so the model must not be able to
    # pick one the browser would treat as executable on this origin.
    it 'rejects anything outside the allowlist' do
      %w[application/javascript text/javascript image/svg+xml application/xhtml+xml].each do |type|
        artifact = build(content_type: type)
        expect(artifact).not_to be_valid, "expected #{type} to be rejected"
        expect(artifact.errors[:content_type].join).to include('must be one of')
      end
    end

    it 'marks only HTML as renderable' do
      expect(build(content_type: 'text/html').renderable?).to be true
      expect(build(content_type: 'text/csv').renderable?).to be false
      expect(build(content_type: 'application/json').renderable?).to be false
    end
  end

  describe 'size' do
    it 'records the byte size on save' do
      artifact = build(content: 'a' * 500).tap(&:save!)
      expect(artifact.byte_size).to eq(500)
    end

    it 'measures bytes, not characters' do
      artifact = build(content: '—' * 10).tap(&:save!)
      expect(artifact.byte_size).to eq(30)
    end

    it 'refuses content over the cap' do
      artifact = build(content: 'a' * (model::MAX_BYTES + 1))
      expect(artifact).not_to be_valid
      expect(artifact.errors[:content].join).to include('over the')
    end

    it 'reports a human size' do
      expect(build(content: 'a' * 900).tap(&:save!).human_size).to eq('900 B')
      expect(build(content: 'a' * 2048).tap(&:save!).human_size).to eq('2.0 KB')
    end
  end

  describe 'validation' do
    it 'requires a name and content' do
      expect(build(name: '')).not_to be_valid
      expect(build(content: '')).not_to be_valid
    end
  end

  describe '#filename' do
    it 'slugifies the name and uses the type extension' do
      expect(build(name: 'Q3 Churn Summary!').filename).to eq('q3-churn-summary.html')
      expect(build(name: 'Export', content_type: 'text/csv').filename).to eq('export.csv')
    end

    it 'falls back when the name has nothing usable in it' do
      # '!!!' passes the presence check but slugifies to nothing.
      artifact = build(name: '!!!').tap(&:save!)
      expect(artifact.filename).to eq("artifact-#{artifact.id}.html")
    end
  end

  describe '.available?' do
    it 'is true once the table exists' do
      expect(model.available?).to be true
    end
  end
end
