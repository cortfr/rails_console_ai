require 'rails_console_ai/agent_loader'

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

    def parsed
      @parsed ||= (RailsConsoleAi::AgentLoader.parse(content.to_s) || {})
    end

    def description; parsed['description']; end
    def body;        parsed['body']; end
    def max_rounds;  parsed['max_rounds']; end
    def model;       parsed['model']; end
    def tools;       Array(parsed['tools']); end
  end
end
