require 'json'

module RailsConsoleAi
  class SkillVersion < ActiveRecord::Base
    self.table_name = 'rails_console_ai_skill_versions'

    belongs_to :skill,
               class_name: 'RailsConsoleAi::Skill',
               foreign_key: :skill_id,
               optional: true

    scope :recent, -> { order(created_at: :desc) }

    def self.connection
      klass = RailsConsoleAi.configuration.connection_class
      if klass
        klass = Object.const_get(klass) if klass.is_a?(String)
        klass.connection
      else
        super
      end
    end

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

    private

    def decode_json_array(raw)
      return [] if raw.nil? || (raw.respond_to?(:empty?) && raw.empty?)
      return raw if raw.is_a?(Array)
      JSON.parse(raw)
    rescue JSON::ParserError
      []
    end

    def encode_json_array(value)
      JSON.dump(Array(value))
    end
  end
end
