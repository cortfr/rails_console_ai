require 'spec_helper'
require 'active_record'
require 'rails_console_ai/storage/database_storage'

begin
  require 'sqlite3'
  SQLITE3_AVAILABLE = true
rescue LoadError
  SQLITE3_AVAILABLE = false
end

# Real, in-memory SQLite tests for the DB-backed skill/memory store + versioning.
RSpec.describe RailsConsoleAi::Storage::DatabaseStorage, if: SQLITE3_AVAILABLE do
  before(:all) do
    ActiveRecord::Base.establish_connection(adapter: 'sqlite3', database: ':memory:')
    conn = ActiveRecord::Base.connection
    RailsConsoleAi.setup_skills_tables!(conn)
    RailsConsoleAi.setup_memories_tables!(conn)
    # Load the AR models — they live in app/models and aren't autoloaded in the spec env.
    require_relative '../../app/models/rails_console_ai/skill'
    require_relative '../../app/models/rails_console_ai/skill_version'
    require_relative '../../app/models/rails_console_ai/memory'
    require_relative '../../app/models/rails_console_ai/memory_version'
  end

  # Disconnect after the suite so other specs (which assume DatabaseStorage.available?
  # is false) don't accidentally route their writes through this in-memory DB.
  after(:all) do
    ActiveRecord::Base.remove_connection
  end

  before(:each) do
    RailsConsoleAi::Skill.delete_all
    RailsConsoleAi::SkillVersion.delete_all
    RailsConsoleAi::Memory.delete_all
    RailsConsoleAi::MemoryVersion.delete_all
  end

  describe 'skills' do
    it 'reports available? when the table exists' do
      expect(described_class.available?).to be(true)
    end

    it 'creates a skill and a version row on first save' do
      record, was_new = described_class.save_skill(
        name: 'Test', description: 'd', body: 'body v1',
        tags: ['a'], bypass_guards_for_methods: ['Foo#bar'],
        edited_by: 'alice', change_note: 'init'
      )

      expect(was_new).to be(true)
      expect(record.name).to eq('Test')
      expect(record.body).to eq('body v1')
      expect(record.versions.count).to eq(1)
      v = record.versions.first
      expect(v.body).to eq('body v1')
      expect(v.edited_by).to eq('alice')
      expect(v.change_note).to eq('init')
    end

    it 'creates a new version row on every update, preserving history' do
      described_class.save_skill(name: 'Test', description: 'd', body: 'v1', edited_by: 'alice')
      described_class.save_skill(name: 'Test', description: 'd', body: 'v2', edited_by: 'bob')
      described_class.save_skill(name: 'Test', description: 'd', body: 'v3', edited_by: 'carol')

      record = RailsConsoleAi::Skill.first
      expect(record.body).to eq('v3')
      bodies = record.versions.reorder(:id).pluck(:body)
      expect(bodies).to eq(['v1', 'v2', 'v3'])
      authors = record.versions.reorder(:id).pluck(:edited_by)
      expect(authors).to eq(['alice', 'bob', 'carol'])
    end

    it 'matches existing skills case-insensitively' do
      described_class.save_skill(name: 'Resurrect Booking', description: '', body: '')
      _, was_new = described_class.save_skill(name: 'resurrect booking', description: '', body: 'updated')
      expect(was_new).to be(false)
      expect(RailsConsoleAi::Skill.count).to eq(1)
      expect(RailsConsoleAi::Skill.first.body).to eq('updated')
    end

    it 'returns all skills sorted alphabetically' do
      described_class.save_skill(name: 'Charlie', description: '', body: '')
      described_class.save_skill(name: 'alpha', description: '', body: '')
      described_class.save_skill(name: 'Bravo', description: '', body: '')

      names = described_class.all_skills.map { |s| s['name'] }
      expect(names).to eq(['alpha', 'Bravo', 'Charlie'])
    end

    it 'tags loaded skills with source: :db' do
      described_class.save_skill(name: 'X', description: '', body: '')
      expect(described_class.all_skills.first['source']).to eq(:db)
    end

    it 'deletes by name (case-insensitive)' do
      described_class.save_skill(name: 'GoneSkill', description: '', body: '')
      expect(described_class.delete_skill_by_name('goneskill')).to be(true)
      expect(RailsConsoleAi::Skill.count).to eq(0)
      # Versions remain orphaned (dependent: :nullify) so the audit trail survives.
      expect(RailsConsoleAi::SkillVersion.count).to eq(1)
      expect(RailsConsoleAi::SkillVersion.first.skill_id).to be_nil
    end

    it 'returns false on delete of unknown name' do
      expect(described_class.delete_skill_by_name('does-not-exist')).to be(false)
    end
  end

  describe 'memories' do
    it 'creates and versions memories the same way skills do' do
      r, was_new = described_class.save_memory(name: 'Shard', description: 'v1', edited_by: 'a')
      expect(was_new).to be(true)
      expect(r.versions.count).to eq(1)

      described_class.save_memory(name: 'Shard', description: 'v2', edited_by: 'b')
      described_class.save_memory(name: 'Shard', description: 'v3', edited_by: 'c')

      record = RailsConsoleAi::Memory.first
      expect(record.description).to eq('v3')
      expect(record.versions.reorder(:id).pluck(:description)).to eq(['v1', 'v2', 'v3'])
    end

    it 'roundtrips tags through JSON serialization' do
      described_class.save_memory(name: 'Tagged', description: 'd', tags: ['a', 'b', 'c'])
      expect(RailsConsoleAi::Memory.first.tags).to eq(['a', 'b', 'c'])
    end
  end

  describe 'approval workflow' do
    it 'creates new skills in the proposed state' do
      r, _ = described_class.save_skill(name: 'NeedApproval', description: 'd', body: 'b')
      expect(r.status).to eq('proposed')
      expect(r.proposed?).to be(true)
      expect(r.approved?).to be(false)
      expect(r.approved_by).to be_nil
      expect(r.approved_at).to be_nil
    end

    it 'marks the version row with the post-save status' do
      r, _ = described_class.save_skill(name: 'WithStatus', description: 'd', body: 'b')
      expect(r.versions.first.status).to eq('proposed')
    end

    it 'flips to approved via approve!, recording approver + timestamp' do
      r, _ = described_class.save_skill(name: 'ToApprove', description: 'd', body: 'b')
      r.approve!(approved_by: 'alice')
      r.reload
      expect(r.approved?).to be(true)
      expect(r.approved_by).to eq('alice')
      expect(r.approved_at).not_to be_nil
      expect(r.versions.first.status).to eq('approved')
      expect(r.versions.first.change_note).to include('Approved by alice')
    end

    it 'reverts to proposed when an approved skill is edited' do
      r, _ = described_class.save_skill(name: 'Editable', description: 'd', body: 'v1')
      r.approve!(approved_by: 'alice')
      described_class.save_skill(name: 'Editable', description: 'd', body: 'v2')
      r.reload
      expect(r.proposed?).to be(true)
      expect(r.approved_by).to be_nil
      expect(r.approved_at).to be_nil
    end

    it 'keeps approval when assign_attributes does not touch content fields' do
      r, _ = described_class.save_skill(name: 'StaysApproved', description: 'd', body: 'b')
      r.approve!(approved_by: 'alice')
      # Approving again is a no-op on content; status should stay approved.
      r.approve!(approved_by: 'bob')
      r.reload
      expect(r.approved?).to be(true)
      expect(r.approved_by).to eq('bob')
    end

    it 'approve! refuses empty approver names' do
      r, _ = described_class.save_skill(name: 'Whoever', description: 'd', body: 'b')
      expect { r.approve!(approved_by: '') }.to raise_error(ArgumentError)
      expect { r.approve!(approved_by: '   ') }.to raise_error(ArgumentError)
    end
  end

  describe 'restore (via Skill#update_with_version!)' do
    it 'overwrites current state from a chosen version and records a new version row' do
      r, _ = described_class.save_skill(name: 'R', description: 'd', body: 'old')
      original_version = r.versions.first
      described_class.save_skill(name: 'R', description: 'd', body: 'new')
      r.reload

      r.update_with_version!(
        { body: original_version.body },
        edited_by: 'web',
        change_note: "Restored from version ##{original_version.id}"
      )
      r.reload

      expect(r.body).to eq('old')
      expect(r.versions.count).to eq(3)
      expect(r.versions.first.change_note).to start_with('Restored from version')
    end
  end
end
