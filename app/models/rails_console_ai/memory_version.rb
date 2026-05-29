require 'rails_console_ai/tools/memory_tools'

module RailsConsoleAi
  class MemoryVersion < ActiveRecord::Base
    self.table_name = 'rails_console_ai_memory_versions'

    belongs_to :memory,
               class_name: 'RailsConsoleAi::Memory',
               foreign_key: :memory_id,
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
      @parsed ||= (RailsConsoleAi::Tools::MemoryTools.parse(content.to_s) || {})
    end

    def description; parsed['description']; end
    def tags;        Array(parsed['tags']); end
  end
end
