require 'spec_helper'
require 'rails_console_ai/skill_loader'
require 'rails_console_ai/storage/file_storage'
require 'tmpdir'

RSpec.describe RailsConsoleAi::SkillLoader do
  let(:tmpdir) { Dir.mktmpdir('rails_console_ai_test') }
  let(:storage) { RailsConsoleAi::Storage::FileStorage.new(tmpdir) }
  subject(:loader) { described_class.new(storage) }

  before do
    RailsConsoleAi.configure { |c| c.storage_adapter = storage }
  end

  after { FileUtils.rm_rf(tmpdir) }

  let(:skill_content) do
    <<~MD
      ---
      name: Approve Changes
      description: Approve or reject change approval records
      tags:
        - change-approval
        - admin
      bypass_guards_for_methods:
        - "ChangeApproval#approve_by!"
        - "ChangeApproval#reject_by!"
      ---

      ## When to use
      Use when user asks to approve or reject a change approval.

      ## Recipe
      1. Find the ChangeApproval
      2. Call approve_by! or reject_by!
    MD
  end

  describe '#load_all_skills' do
    it 'returns empty array when skills directory does not exist' do
      expect(loader.load_all_skills).to eq([])
    end

    it 'loads and parses skill files' do
      storage.write('skills/approve-changes.md', skill_content)

      skills = loader.load_all_skills
      expect(skills.length).to eq(1)
      expect(skills.first['name']).to eq('Approve Changes')
      expect(skills.first['description']).to eq('Approve or reject change approval records')
      expect(skills.first['tags']).to eq(['change-approval', 'admin'])
      expect(skills.first['bypass_guards_for_methods']).to eq([
        'ChangeApproval#approve_by!',
        'ChangeApproval#reject_by!'
      ])
      expect(skills.first['body']).to include('## When to use')
      expect(skills.first['body']).to include('## Recipe')
    end

    it 'skips empty files' do
      storage.write('skills/empty.md', '   ')
      expect(loader.load_all_skills).to eq([])
    end

    it 'skips files with invalid frontmatter' do
      storage.write('skills/bad.md', 'no frontmatter here')
      expect(loader.load_all_skills).to eq([])
    end
  end

  describe '#skill_summaries' do
    it 'returns nil when no skills exist' do
      expect(loader.skill_summaries).to be_nil
    end

    it 'returns formatted summaries' do
      storage.write('skills/approve-changes.md', skill_content)

      summaries = loader.skill_summaries
      expect(summaries.length).to eq(1)
      expect(summaries.first).to include('Approve Changes')
      expect(summaries.first).to include('change-approval')
      expect(summaries.first).to include('Approve or reject change approval records')
    end
  end

  describe '#find_skill' do
    before do
      storage.write('skills/approve-changes.md', skill_content)
    end

    it 'finds a skill by exact name (case-insensitive)' do
      skill = loader.find_skill('approve changes')
      expect(skill).not_to be_nil
      expect(skill['name']).to eq('Approve Changes')
    end

    it 'returns nil for unknown skill name' do
      expect(loader.find_skill('nonexistent')).to be_nil
    end
  end

  describe '#save_skill' do
    it 'creates a new skill file' do
      result = loader.save_skill(
        name: 'Resurrect BookingPage',
        description: 'Undelete a deleted booking page and restore its subdomain',
        body: "## When to use\nUse when a booking page needs to be undeleted.\n\n## Recipe\n1. Find the booking page\n2. Set deleted = false\n3. Call ensure_subdomain_set!",
        tags: ['booking-page', 'admin']
      )

      expect(result).to start_with('Skill created:')
      skill = loader.find_skill('Resurrect BookingPage')
      expect(skill).not_to be_nil
      expect(skill['name']).to eq('Resurrect BookingPage')
      expect(skill['description']).to eq('Undelete a deleted booking page and restore its subdomain')
      expect(skill['tags']).to eq(['booking-page', 'admin'])
      expect(skill['body']).to include('ensure_subdomain_set!')
    end

    it 'updates an existing skill' do
      loader.save_skill(name: 'Test Skill', description: 'v1', body: 'original body', tags: ['test'])
      result = loader.save_skill(name: 'Test Skill', description: 'v2', body: 'updated body', tags: ['test'])

      expect(result).to start_with('Skill updated:')
      skill = loader.find_skill('Test Skill')
      expect(skill['description']).to eq('v2')
      expect(skill['body']).to eq('updated body')
    end

    it 'includes bypass_guards_for_methods when provided' do
      loader.save_skill(
        name: 'Guard Skill',
        description: 'test',
        body: 'test body',
        bypass_guards_for_methods: ['BookingPage#save!']
      )

      skill = loader.find_skill('Guard Skill')
      expect(skill['bypass_guards_for_methods']).to eq(['BookingPage#save!'])
    end

    it 'omits bypass_guards_for_methods when empty' do
      loader.save_skill(name: 'No Guards', description: 'test', body: 'test body')

      content = storage.read('skills/no-guards.md')
      expect(content).not_to include('bypass_guards_for_methods')
    end
  end

  describe '#delete_skill' do
    it 'deletes an existing skill' do
      loader.save_skill(name: 'To Delete', description: 'test', body: 'test body')
      result = loader.delete_skill(name: 'To Delete')

      expect(result).to start_with('Skill deleted:')
      expect(loader.find_skill('To Delete')).to be_nil
    end

    it 'returns error for nonexistent skill' do
      result = loader.delete_skill(name: 'Nonexistent')
      expect(result).to include('No skill found')
    end
  end

  describe 'DB + file union (DatabaseStorage stubbed)' do
    let(:db_skill) do
      {
        'id'                        => 42,
        'name'                      => 'DB-only skill',
        'description'               => 'lives in the database',
        'body'                      => '## Recipe\n1. do thing',
        'tags'                      => ['db'],
        'bypass_guards_for_methods' => [],
        'source'                    => :db
      }
    end

    before do
      allow(RailsConsoleAi::Storage::DatabaseStorage).to receive(:available?).and_return(true)
      allow(RailsConsoleAi::Storage::DatabaseStorage).to receive(:all_skills).and_return([db_skill])
      storage.write('skills/file-only.md', skill_content)
    end

    it 'returns the union of DB and file skills, alphabetized' do
      names = loader.load_all_skills.map { |s| s['name'] }
      expect(names).to include('DB-only skill')
      expect(names).to include('Approve Changes')
    end

    it 'tags each skill with its source' do
      sources = loader.load_all_skills.each_with_object({}) { |s, h| h[s['name']] = s['source'] }
      expect(sources['DB-only skill']).to eq(:db)
      expect(sources['Approve Changes']).to eq(:file)
    end

    it 'shadows file skills with same-named DB skills (DB wins)' do
      storage.write('skills/db-only-skill.md', "---\nname: DB-only skill\ndescription: shadowed\ntags: []\n---\n\nshadowed body")
      results = loader.load_all_skills.select { |s| s['name'] == 'DB-only skill' }
      expect(results.length).to eq(1)
      expect(results.first['source']).to eq(:db)
    end

    it 'routes save_skill to DB by default' do
      record = double('Skill', id: 99, name: 'DB-only skill')
      expect(RailsConsoleAi::Storage::DatabaseStorage).to receive(:save_skill)
        .with(hash_including(name: 'New', description: 'd', body: 'b'))
        .and_return([record, true])
      result = loader.save_skill(name: 'New', description: 'd', body: 'b')
      expect(result).to include('Skill created (db)')
    end

    it 'routes save_skill to file when target: :file' do
      expect(RailsConsoleAi::Storage::DatabaseStorage).not_to receive(:save_skill)
      result = loader.save_skill(name: 'FileSkill', description: 'd', body: 'b', target: :file)
      expect(result).to start_with('Skill created:')
      expect(storage.read('skills/fileskill.md')).to include('FileSkill')
    end

    it 'falls back to file when DB target is requested but tables are missing' do
      allow(RailsConsoleAi::Storage::DatabaseStorage).to receive(:available?).and_return(false)
      expect(RailsConsoleAi::Storage::DatabaseStorage).not_to receive(:save_skill)
      result = loader.save_skill(name: 'FallbackSkill', description: 'd', body: 'b', target: :db)
      expect(result).to start_with('Skill created:')
    end
  end
end
