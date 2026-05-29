require 'rails_console_ai/skill_loader'

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

    def parsed
      @parsed ||= (RailsConsoleAi::SkillLoader.parse(content.to_s) || {})
    end

    def description; parsed['description']; end
    def body;        parsed['body']; end
    def tags;        Array(parsed['tags']); end
    def bypass_guards_for_methods; Array(parsed['bypass_guards_for_methods']); end
  end
end
