require 'json'

module RailsConsoleAi
  class AgentVersion < ActiveRecord::Base
    self.table_name = 'rails_console_ai_agent_versions'

    belongs_to :agent,
               class_name: 'RailsConsoleAi::Agent',
               foreign_key: :agent_id,
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

    def tools
      decode_json_array(read_attribute(:tools))
    end

    def tools=(value)
      write_attribute(:tools, encode_json_array(value))
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
