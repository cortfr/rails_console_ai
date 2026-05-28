require 'json'

module RailsConsoleAi
  class Agent < ActiveRecord::Base
    self.table_name = 'rails_console_ai_agents'

    STATUS_PROPOSED = 'proposed'.freeze
    STATUS_APPROVED = 'approved'.freeze
    STATUSES = [STATUS_PROPOSED, STATUS_APPROVED].freeze

    # Attributes that, if changed, invalidate the current approval and revert
    # the agent back to "proposed". Status / approver columns are excluded so
    # that an explicit approve! call doesn't reset its own approval.
    CONTENT_ATTRIBUTES = %w[name description body max_rounds model tools].freeze

    has_many :versions,
             -> { order(created_at: :desc) },
             class_name: 'RailsConsoleAi::AgentVersion',
             foreign_key: :agent_id,
             dependent: :nullify

    validates :name, presence: true, uniqueness: { case_sensitive: false }
    validates :status, inclusion: { in: STATUSES }, if: :has_attribute_status?

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

    # Manual JSON accessor for `tools` — same approach we use for skill tags,
    # avoids Rails-version-specific `serialize` API.
    def tools
      decode_json_array(read_attribute(:tools))
    end

    def tools=(value)
      write_attribute(:tools, encode_json_array(value))
    end

    # Defensive accessors — if `ai_db_migrate` hasn't been run yet, the status
    # / approval columns may be missing on an older table.
    def status
      has_attribute_status? ? read_attribute(:status) : STATUS_PROPOSED
    end

    def approved_by
      has_attribute?(:approved_by) ? read_attribute(:approved_by) : nil
    end

    def approved_at
      has_attribute?(:approved_at) ? read_attribute(:approved_at) : nil
    end

    def proposed?; status.to_s == STATUS_PROPOSED; end
    def approved?; status.to_s == STATUS_APPROVED; end

    def to_hash
      {
        'id'          => id,
        'name'        => name,
        'description' => description,
        'body'        => body,
        'max_rounds'  => max_rounds,
        'model'       => model,
        'tools'       => tools,
        'status'      => status,
        'approved_by' => approved_by,
        'approved_at' => approved_at,
        'source'      => :db,
        'updated_at'  => updated_at
      }
    end

    def has_attribute_status?
      has_attribute?(:status)
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

    def decode_json_array(raw); self.class.decode_json_array(raw); end
    def encode_json_array(value); self.class.encode_json_array(value); end

    # Assigns attrs, saves, and records one AgentVersion snapshot of the post-save state.
    # If `preserve_approval` is false (the default), any change to a content attribute
    # reverts the agent back to "proposed" and clears the approver.
    def update_with_version!(attrs, edited_by: nil, change_note: nil, preserve_approval: false)
      transaction do
        assign_attributes(attrs)

        if !preserve_approval && approved? && content_dirty?
          self.status      = STATUS_PROPOSED
          self.approved_by = nil
          self.approved_at = nil
        end

        save!
        RailsConsoleAi::AgentVersion.create!(
          agent_id:    id,
          name:        name,
          description: description,
          body:        body,
          max_rounds:  max_rounds,
          model:       model,
          tools:       tools,
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

    def content_dirty?
      CONTENT_ATTRIBUTES.any? { |a| changes.key?(a) }
    end
  end
end
