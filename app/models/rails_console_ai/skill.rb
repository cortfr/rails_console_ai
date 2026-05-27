require 'json'

module RailsConsoleAi
  class Skill < ActiveRecord::Base
    self.table_name = 'rails_console_ai_skills'

    has_many :versions,
             -> { order(created_at: :desc) },
             class_name: 'RailsConsoleAi::SkillVersion',
             foreign_key: :skill_id,
             dependent: :nullify

    validates :name, presence: true, uniqueness: { case_sensitive: false }

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

    scope :alphabetical, -> { order(Arel.sql('LOWER(name)')) }

    def self.connection
      klass = RailsConsoleAi.configuration.connection_class
      if klass
        klass = Object.const_get(klass) if klass.is_a?(String)
        klass.connection
      else
        super
      end
    end

    def to_hash
      {
        'id'                        => id,
        'name'                      => name,
        'description'               => description,
        'body'                      => body,
        'tags'                      => Array(tags),
        'bypass_guards_for_methods' => Array(bypass_guards_for_methods),
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
    def update_with_version!(attrs, edited_by: nil, change_note: nil)
      transaction do
        assign_attributes(attrs)
        save!
        RailsConsoleAi::SkillVersion.create!(
          skill_id:                   id,
          name:                       name,
          description:                description,
          body:                       body,
          tags:                       Array(tags),
          bypass_guards_for_methods:  Array(bypass_guards_for_methods),
          edited_by:                  edited_by,
          change_note:                change_note
        )
      end
      self
    end
  end
end
