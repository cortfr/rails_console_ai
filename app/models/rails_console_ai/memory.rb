require 'rails_console_ai/tools/memory_tools'

module RailsConsoleAi
  class Memory < ActiveRecord::Base
    self.table_name = 'rails_console_ai_memories'

    has_many :versions,
             -> { order(created_at: :desc) },
             class_name: 'RailsConsoleAi::MemoryVersion',
             foreign_key: :memory_id,
             dependent: :nullify

    validates :content, presence: true
    validates :name, presence: true, uniqueness: { case_sensitive: false }
    validate  :content_parses

    before_validation :sync_name_from_content

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

    def parsed
      @parsed ||= (RailsConsoleAi::Tools::MemoryTools.parse(content.to_s) || {})
    end

    def content=(value)
      @parsed = nil
      super
    end

    # Memories don't have a separate description vs body — the markdown body
    # IS the memory. Parser exposes it under 'description'.
    def description; parsed['description']; end
    def tags;        Array(parsed['tags']); end

    def self.record_use!(id)
      where(id: id).update_all([
        'use_count = COALESCE(use_count, 0) + 1, last_used_at = ?',
        Time.now.utc
      ])
      true
    rescue ::ActiveRecord::ActiveRecordError => e
      RailsConsoleAi.logger.warn("RailsConsoleAi::Memory.record_use!(#{id.inspect}) failed: #{e.message}")
      false
    end

    def to_hash
      {
        'id'           => id,
        'name'         => name,
        'description'  => description,
        'tags'         => tags,
        'content'      => content,
        'use_count'    => use_count,
        'last_used_at' => last_used_at,
        'source'       => :db,
        'updated_at'   => updated_at
      }
    end

    def update_with_version!(attrs, edited_by: nil, change_note: nil)
      transaction do
        assign_attributes(attrs)
        save!
        RailsConsoleAi::MemoryVersion.create!(
          memory_id:   id,
          name:        name,
          content:     content,
          edited_by:   edited_by,
          change_note: change_note
        )
      end
      self
    end

    private

    def sync_name_from_content
      return if content.to_s.strip.empty?
      parsed_name = parsed['name'].to_s.strip
      self.name = parsed_name unless parsed_name.empty?
    end

    def content_parses
      return if content.to_s.strip.empty?
      hash = RailsConsoleAi::Tools::MemoryTools.parse(content.to_s)
      if hash.nil?
        errors.add(:content, "could not be parsed — expected YAML frontmatter between `---` lines followed by a markdown body")
      elsif hash['name'].to_s.strip.empty?
        errors.add(:content, "frontmatter is missing a `name:` field")
      end
    end
  end
end
