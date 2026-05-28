require 'json'

module RailsConsoleAi
  class Memory < ActiveRecord::Base
    self.table_name = 'rails_console_ai_memories'

    has_many :versions,
             -> { order(created_at: :desc) },
             class_name: 'RailsConsoleAi::MemoryVersion',
             foreign_key: :memory_id,
             dependent: :nullify

    validates :name, presence: true, uniqueness: { case_sensitive: false }

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

    def tags
      decode_json_array(read_attribute(:tags))
    end

    def tags=(value)
      write_attribute(:tags, encode_json_array(value))
    end

    def use_count
      has_attribute?(:use_count) ? (read_attribute(:use_count) || 0) : 0
    end

    def last_used_at
      has_attribute?(:last_used_at) ? read_attribute(:last_used_at) : nil
    end

    def self.record_use!(id)
      return false unless connection.column_exists?(table_name, :use_count)
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
          description: description,
          tags:        tags,
          edited_by:   edited_by,
          change_note: change_note
        )
      end
      self
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
