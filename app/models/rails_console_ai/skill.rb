require 'rails_console_ai/skill_loader'

module RailsConsoleAi
  class Skill < ActiveRecord::Base
    self.table_name = 'rails_console_ai_skills'

    STATUS_PROPOSED = 'proposed'.freeze
    STATUS_APPROVED = 'approved'.freeze
    STATUSES = [STATUS_PROPOSED, STATUS_APPROVED].freeze

    has_many :versions,
             -> { order(created_at: :desc) },
             class_name: 'RailsConsoleAi::SkillVersion',
             foreign_key: :skill_id,
             dependent: :nullify

    validates :content, presence: true
    validates :name, presence: true, uniqueness: { case_sensitive: false }
    validates :status, inclusion: { in: STATUSES }
    validate  :content_parses

    before_validation :sync_name_from_content

    scope :alphabetical, -> { order(Arel.sql('LOWER(name)')) }
    scope :approved, -> { where(status: STATUS_APPROVED) }
    scope :proposed, -> { where(status: STATUS_PROPOSED) }

    def self.connection
      klass = RailsConsoleAi.configuration.connection_class
      if klass
        klass = Object.const_get(klass) if klass.is_a?(String)
        klass.connection
      else
        super
      end
    end

    # Parsed view of the raw markdown content. Memoized per-instance and cleared
    # on assignment. Returns {} for invalid content so callers don't need to nil-guard.
    def parsed
      @parsed ||= (RailsConsoleAi::SkillLoader.parse(content.to_s) || {})
    end

    def content=(value)
      @parsed = nil
      super
    end

    def description; parsed['description']; end
    def body;        parsed['body']; end
    def tags;        Array(parsed['tags']); end
    def bypass_guards_for_methods; Array(parsed['bypass_guards_for_methods']); end

    def proposed?; status.to_s == STATUS_PROPOSED; end
    def approved?; status.to_s == STATUS_APPROVED; end

    # Atomically bump use_count + last_used_at without firing callbacks /
    # validations / updated_at. Safe to call from concurrent AI tool calls.
    def self.record_use!(id)
      where(id: id).update_all([
        'use_count = COALESCE(use_count, 0) + 1, last_used_at = ?',
        Time.now.utc
      ])
      true
    rescue ::ActiveRecord::ActiveRecordError => e
      RailsConsoleAi.logger.warn("RailsConsoleAi::Skill.record_use!(#{id.inspect}) failed: #{e.message}")
      false
    end

    def to_hash
      {
        'id'                        => id,
        'name'                      => name,
        'description'               => description,
        'body'                      => body,
        'tags'                      => tags,
        'bypass_guards_for_methods' => bypass_guards_for_methods,
        'content'                   => content,
        'status'                    => status,
        'approved_by'               => approved_by,
        'approved_at'               => approved_at,
        'use_count'                 => use_count,
        'last_used_at'              => last_used_at,
        'source'                    => :db,
        'updated_at'                => updated_at
      }
    end

    # Assigns attrs, saves, and records one SkillVersion snapshot.
    # Any change to `content` reverts approval back to "proposed" unless
    # `preserve_approval: true` is passed (approve! does this).
    def update_with_version!(attrs, edited_by: nil, change_note: nil, preserve_approval: false)
      transaction do
        assign_attributes(attrs)

        if !preserve_approval && approved? && changes.key?('content')
          self.status      = STATUS_PROPOSED
          self.approved_by = nil
          self.approved_at = nil
        end

        save!
        RailsConsoleAi::SkillVersion.create!(
          skill_id:    id,
          name:        name,
          content:     content,
          status:      status,
          edited_by:   edited_by,
          change_note: change_note
        )
      end
      self
    end

    def approve!(approved_by:)
      raise ArgumentError, 'approved_by is required' if approved_by.to_s.strip.empty?

      update_with_version!(
        {
          status:      STATUS_APPROVED,
          approved_by: approved_by,
          approved_at: Time.now.utc
        },
        edited_by: approved_by,
        change_note: "Approved by #{approved_by}",
        preserve_approval: true
      )
    end

    private

    def sync_name_from_content
      return if content.to_s.strip.empty?
      parsed_name = parsed['name'].to_s.strip
      self.name = parsed_name unless parsed_name.empty?
    end

    def content_parses
      return if content.to_s.strip.empty?  # presence validator handles blank
      hash = RailsConsoleAi::SkillLoader.parse(content.to_s)
      if hash.nil?
        errors.add(:content, "could not be parsed — expected YAML frontmatter between `---` lines followed by a markdown body")
      elsif hash['name'].to_s.strip.empty?
        errors.add(:content, "frontmatter is missing a `name:` field")
      end
    end
  end
end
