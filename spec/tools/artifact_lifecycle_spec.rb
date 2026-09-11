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

# Naming an artifact, then coming back to it: the flow where a user says
# "update the churn report" in a session that knows nothing about the first one.
RSpec.describe 'artifact lifecycle', if: SQLITE3_AVAILABLE do
  before(:all) do
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    RailsConsoleAi.setup_artifacts_table!(ActiveRecord::Base.connection)
    require_relative '../../app/models/rails_console_ai/artifact'
  end

  after(:all) { ActiveRecord::Base.remove_connection }

  let(:channel) { double('channel', display_status: nil) }
  let(:executor) { RailsConsoleAi::Executor.new(binding, channel: channel) }
  let(:registry) { RailsConsoleAi::Tools::Registry.new(executor: executor, channel: channel) }
  let(:model) { RailsConsoleAi::Artifact }

  before { model.delete_all }

  # New names are stamped with the day they were made; the slug mirrors the name.
  let(:today)      { Time.now.strftime('%Y%m%d') }
  let(:name_stamp) { "#{today}_" }
  let(:slug_stamp) { "#{today}-" }

  def save(name, content, type: 'text/html', description: nil)
    args = { 'name' => name, 'content_type' => type, 'content' => content }
    args['description'] = description if description
    registry.execute('save_artifact', args)
  end

  def call(tool, args = {})
    registry.execute(tool, args)
  end

  describe 'naming' do
    it 'gives the artifact a handle derived from its name' do
      save('Q3 Churn Summary', '<h1>a</h1>')
      expect(model.last.slug).to eq("#{slug_stamp}q3-churn-summary")
    end

    it 'stamps the name with the day it was made' do
      save('Q3 Churn Summary', '<h1>a</h1>')
      expect(model.last.name).to eq("#{name_stamp}Q3 Churn Summary")
    end

    it 'keeps name and handle in step' do
      save('Q3 Churn Summary', '<h1>a</h1>')
      artifact = model.last
      expect(artifact.slug).to eq(described_slug(artifact.name))
    end

    it 'does not stamp a name that already carries a date' do
      save('20240101_Old report', '<h1>a</h1>')
      expect(model.last.name).to eq('20240101_Old report')
      expect(model.last.slug).to eq('20240101-old-report')
    end

    it 'tells the model the handle so it can pass it on' do
      result = save('Q3 churn summary', '<h1>a</h1>')
      expect(result).to include("handle: #{slug_stamp}q3-churn-summary")
      expect(result).to include("Refer to it later as #{slug_stamp}q3-churn-summary")
    end

    it 'still produces a handle when the name has nothing sluggable in it' do
      save('!!!', 'x')
      expect(model.last.slug).to match(/\A#{today}-artifact-[0-9a-f]+\z/)
    end

    it 'can be turned off' do
      RailsConsoleAi.configure { |c| c.artifact_date_prefix = false }
      save('Q3 churn summary', '<h1>a</h1>')
      expect(model.last.name).to eq('Q3 churn summary')
      expect(model.last.slug).to eq('q3-churn-summary')
    end
  end

  describe 'saving under an existing name' do
    before { save('Churn report', '<h1>first</h1>', description: 'original note') }

    it 'replaces the content rather than making a second copy' do
      save('Churn report', '<h1>second</h1>')

      expect(model.count).to eq(1)
      expect(model.last.content).to eq('<h1>second</h1>')
    end

    it 'bumps the revision and says so' do
      result = save('Churn report', '<h1>second</h1>')

      expect(model.last.revision).to eq(2)
      expect(result).to include('Artifact updated')
      expect(result).to include('revision 2')
    end

    it 'keeps the same handle, so a link already shared still works' do
      slug = model.last.slug
      save('Churn report', '<h1>second</h1>')
      expect(model.last.slug).to eq(slug)
    end

    it 'updates when given the full stamped handle back' do
      save("#{name_stamp}Churn report", '<h1>second</h1>')
      expect(model.count).to eq(1)
      expect(model.last.revision).to eq(2)
    end

    it 'matches the name however the user capitalised it' do
      save('churn REPORT', '<h1>second</h1>')
      expect(model.count).to eq(1)
    end

    it 'keeps the existing description when the update omits one' do
      save('Churn report', '<h1>second</h1>')
      expect(model.last.description).to eq('original note')
    end

    it 'replaces the description when the update supplies one' do
      save('Churn report', '<h1>second</h1>', description: 'now with October')
      expect(model.last.description).to eq('now with October')
    end

    it 'treats a different name as a different artifact' do
      save('Churn report 2024', '<h1>other</h1>')
      expect(model.count).to eq(2)
    end
  end

  describe 'list_artifacts' do
    before do
      save('Churn report', '<h1>a</h1>', description: 'monthly churn')
      save('User export', 'id,email', type: 'text/csv')
    end

    it 'lists handles so the model can address them' do
      result = call('list_artifacts')
      expect(result).to include('churn-report')
      expect(result).to include('user-export')
    end

    it 'filters on name and description' do
      expect(call('list_artifacts', 'search' => 'churn')).to include('churn-report')
      expect(call('list_artifacts', 'search' => 'churn')).not_to include('user-export')
      expect(call('list_artifacts', 'search' => 'monthly')).to include('churn-report')
    end

    it 'says so when nothing matches' do
      expect(call('list_artifacts', 'search' => 'nope')).to include('No artifacts match')
    end

    it 'says so when there are none at all' do
      model.delete_all
      expect(call('list_artifacts')).to include('No artifacts saved yet')
    end
  end

  describe 'read_artifact' do
    before { save('Churn report', '<h1>the original</h1>') }

    it 'returns the content so the model can revise it' do
      result = call('read_artifact', 'handle' => 'churn-report')
      expect(result).to include('<h1>the original</h1>')
      expect(result).to include('revision 1')
    end

    it 'accepts the name or the token as well as the handle' do
      expect(call('read_artifact', 'handle' => 'Churn report')).to include('the original')
      expect(call('read_artifact', 'handle' => model.last.token)).to include('the original')
    end

    it 'truncates a large artifact instead of flooding the context' do
      limit = RailsConsoleAi::Tools::Registry::ARTIFACT_READ_LIMIT
      save('Churn report', 'x' * (limit + 500))

      result = call('read_artifact', 'handle' => 'churn-report')
      expect(result).to include('Truncated at')
      expect(result).to include('explore_output')
      expect(result.length).to be < limit + 2_000
    end

    it 'lists what is available when the handle is wrong' do
      result = call('read_artifact', 'handle' => 'no-such-thing')
      expect(result).to include('No artifact found')
      expect(result).to include('churn-report')
    end
  end

  describe 'delete_artifact' do
    before { save('Churn report', '<h1>a</h1>') }

    it 'removes it' do
      result = call('delete_artifact', 'handle' => 'churn-report')
      expect(model.count).to eq(0)
      expect(result).to include('Artifact deleted')
    end

    it 'reports a miss without deleting anything' do
      result = call('delete_artifact', 'handle' => 'nope')
      expect(model.count).to eq(1)
      expect(result).to include('No artifact found')
    end
  end

  describe 'the URL handed to the user' do
    it 'names the artifact in the link rather than an opaque token' do
      result = save('Dog on a bike', '<h1>a</h1>')

      expect(result).to include("/rails_console_ai/artifacts/#{slug_stamp}dog-on-a-bike")
      expect(result).not_to include(model.last.token)
    end

    it 'is absolute when the app declares its base URL' do
      RailsConsoleAi.configure { |c| c.base_url = 'https://secure.apptoto.com' }
      result = save('Dog on a bike', '<h1>a</h1>')

      expect(result).to include("https://secure.apptoto.com/rails_console_ai/artifacts/#{slug_stamp}dog-on-a-bike")
    end

    it 'stays a bare path when no base URL is known' do
      result = save('Dog on a bike', '<h1>a</h1>')
      expect(result).to include("/rails_console_ai/artifacts/#{slug_stamp}dog-on-a-bike")
      expect(result).not_to include('http')
    end
  end

  describe 'addressing without the date' do
    before { save('Churn report', '<h1>a</h1>') }

    # The user says "the churn report", not "the 11th of September churn report".
    it 'resolves an undated handle for reading' do
      expect(call('read_artifact', 'handle' => 'churn-report')).to include('<h1>a</h1>')
    end

    it 'resolves an undated handle for deleting' do
      call('delete_artifact', 'handle' => 'churn-report')
      expect(model.count).to eq(0)
    end

    it 'picks the most recent when several days share a name' do
      model.create!(name: '20200101_Churn report', content_type: 'text/html',
                    content: '<h1>ancient</h1>', created_at: Time.now - (60 * 60 * 24 * 365))
      expect(call('read_artifact', 'handle' => 'churn-report')).to include('<h1>a</h1>')
    end
  end

  describe 'the tools on offer' do
    it 'includes all four' do
      names = registry.definitions.map { |d| d[:name] }
      expect(names).to include('save_artifact', 'list_artifacts', 'read_artifact', 'delete_artifact')
    end
  end

  def described_slug(name)
    RailsConsoleAi::SlashCommands.slugify(name)
  end
end
