require 'json'

module RailsConsoleAi
  class Skill < ActiveRecord::Base
    self.table_name = 'rails_console_ai_skills'

    STATUS_PROPOSED = 'proposed'.freeze
    STATUS_APPROVED = 'approved'.freeze
    STATUSES = [STATUS_PROPOSED, STATUS_APPROVED].freeze

    # Attributes that, if changed, invalidate the current approval and revert
    # the skill back to "proposed". Status / approver columns are excluded so
    # that an explicit approve! call doesn't reset its own approval.
    CONTENT_ATTRIBUTES = %w[name description body tags bypass_guards_for_methods].freeze

    has_many :versions,
             -> { order(created_at: :desc) },
             class_name: 'RailsConsoleAi::SkillVersion',
             foreign_key: :skill_id,
             dependent: :nullify

    validates :name, presence: true, uniqueness: { case_sensitive: false }
    validates :status, inclusion: { in: STATUSES }

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

    # Manual JSON accessors keep us off Rails-version-specific `serialize` syntax
    # (positional coder in Rails 5–6, keyword coder in Rails 7+).
    def tags
      decode_json_array(read_attribute(:tags))
    end

    def tags=(value)
      write_attribute(:tags, encode_json_array(value))
    end

    def bypass_guards_for_methods
      decode_json_array(read_attribute(:bypass_guards_for_methods))
    end

    def bypass_guards_for_methods=(value)
      write_attribute(:bypass_guards_for_methods, encode_json_array(value))
    end

    def proposed?; status.to_s == STATUS_PROPOSED; end
    def approved?; status.to_s == STATUS_APPROVED; end

    def to_hash
      {
        'id'                        => id,
        'name'                      => name,
        'description'               => description,
        'body'                      => body,
        'tags'                      => tags,
        'bypass_guards_for_methods' => bypass_guards_for_methods,
        'status'                    => status,
        'approved_by'               => approved_by,
        'approved_at'               => approved_at,
        'source'                    => :db,
        'updated_at'                => updated_at
      }
    end

    def self.decode_json_array(raw)
      return [] if raw.nil? || (raw.respond_to?(:empty?) && raw.empty?)
      return raw if raw.is_a?(Array)
      JSON.parse(raw)
    rescue JSON::ParserError
      []
    end

    def self.encode_json_array(value)
      JSON.dump(Array(value))
    end

    def decode_json_array(raw)
      self.class.decode_json_array(raw)
    end

    def encode_json_array(value)
      self.class.encode_json_array(value)
    end

    # Assigns attrs, saves, and records one SkillVersion snapshot of the post-save state.
    # Every save produces exactly one version row, so the version log is a complete history
    # including the current state (the most recent version mirrors `self`).
    #
    # If `preserve_approval` is false (the default), any change to a content attribute
    # reverts the skill back to "proposed" and clears the approver. Pass true from the
    # approve! flow so approval doesn't reset itself.
    def update_with_version!(attrs, edited_by: nil, change_note: nil, preserve_approval: false)
      transaction do
        assign_attributes(attrs)

        if !preserve_approval && approved? && content_dirty?
          self.status      = STATUS_PROPOSED
          self.approved_by = nil
          self.approved_at = nil
        end

        save!
        RailsConsoleAi::SkillVersion.create!(
          skill_id:                   id,
          name:                       name,
          description:                description,
          body:                       body,
          tags:                       tags,
          bypass_guards_for_methods:  bypass_guards_for_methods,
          status:                     status,
          edited_by:                  edited_by,
          change_note:                change_note
        )
      end
      self
    end

    # Marks the current head as approved. Logs a version row with the approver name
    # so the audit trail captures the approval moment.
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

    # Did any content-bearing attribute change in this assign_attributes pass?
    def content_dirty?
      CONTENT_ATTRIBUTES.any? { |a| changes.key?(a) }
    end
  end
end
