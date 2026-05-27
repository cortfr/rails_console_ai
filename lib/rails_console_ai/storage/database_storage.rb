module RailsConsoleAi
  module Storage
    # Thin facade over the AR-backed Skill / Memory tables.
    #
    # Not a drop-in Storage::Base adapter: the loaders read & write structured
    # records, not opaque Markdown blobs, so we expose a small typed API instead.
    # All methods are safe to call before `ai_db_setup` has run — they detect
    # missing tables and return empty results / nil rather than raising.
    module DatabaseStorage
      module_function

      def available?
        table_exists?('rails_console_ai_skills')
      end

      def memories_available?
        table_exists?('rails_console_ai_memories')
      end

      # Ask the connection directly so we don't depend on the AR model being
      # autoloaded yet. In a Rails console, the models in app/models are
      # autoloaded lazily — the constant is `defined?`-false until first
      # reference. Going through the connection avoids that timing trap.
      def table_exists?(table_name)
        return false unless defined?(::ActiveRecord)
        conn = active_record_connection
        return false unless conn
        conn.table_exists?(table_name)
      rescue ::ActiveRecord::ActiveRecordError, ::ActiveRecord::NoDatabaseError, NoMethodError
        false
      end

      def active_record_connection
        klass = RailsConsoleAi.configuration.connection_class
        if klass
          klass = Object.const_get(klass) if klass.is_a?(String)
          klass.connection
        else
          ::ActiveRecord::Base.connection
        end
      end

      # --- Skills ---

      def all_skills
        return [] unless available?
        RailsConsoleAi::Skill.alphabetical.map(&:to_hash)
      rescue => e
        warn_failure(:all_skills, e)
        []
      end

      def find_skill_by_name(name)
        return nil unless available?
        record = RailsConsoleAi::Skill.where('LOWER(name) = ?', name.to_s.downcase).first
        record&.to_hash
      rescue => e
        warn_failure(:find_skill_by_name, e)
        nil
      end

      def save_skill(name:, description:, body:, tags: [], bypass_guards_for_methods: [], edited_by: nil, change_note: nil)
        ensure_tables!(:skills)
        record = RailsConsoleAi::Skill.where('LOWER(name) = ?', name.to_s.downcase).first
        record ||= RailsConsoleAi::Skill.new
        was_new = record.new_record?
        record.update_with_version!(
          {
            name:                      name,
            description:               description,
            body:                      body,
            tags:                      Array(tags),
            bypass_guards_for_methods: Array(bypass_guards_for_methods)
          },
          edited_by: edited_by,
          change_note: change_note
        )
        [record, was_new]
      end

      def delete_skill_by_name(name)
        return false unless available?
        record = RailsConsoleAi::Skill.where('LOWER(name) = ?', name.to_s.downcase).first
        return false unless record
        record.destroy
        true
      end

      # --- Memories ---

      def all_memories
        return [] unless memories_available?
        RailsConsoleAi::Memory.alphabetical.map(&:to_hash)
      rescue => e
        warn_failure(:all_memories, e)
        []
      end

      def find_memory_by_name(name)
        return nil unless memories_available?
        record = RailsConsoleAi::Memory.where('LOWER(name) = ?', name.to_s.downcase).first
        record&.to_hash
      rescue => e
        warn_failure(:find_memory_by_name, e)
        nil
      end

      def save_memory(name:, description:, tags: [], edited_by: nil, change_note: nil)
        ensure_tables!(:memories)
        record = RailsConsoleAi::Memory.where('LOWER(name) = ?', name.to_s.downcase).first
        record ||= RailsConsoleAi::Memory.new
        was_new = record.new_record?
        record.update_with_version!(
          {
            name:        name,
            description: description,
            tags:        Array(tags)
          },
          edited_by: edited_by,
          change_note: change_note
        )
        [record, was_new]
      end

      def delete_memory_by_name(name)
        return false unless memories_available?
        record = RailsConsoleAi::Memory.where('LOWER(name) = ?', name.to_s.downcase).first
        return false unless record
        record.destroy
        true
      end

      def ensure_tables!(kind)
        ready = kind == :skills ? available? : memories_available?
        return if ready
        raise StorageError, "rails_console_ai_#{kind} table does not exist. Run `ai_db_setup` in your console."
      end

      def warn_failure(method, error)
        return unless defined?(RailsConsoleAi.logger) && RailsConsoleAi.logger
        RailsConsoleAi.logger.warn("RailsConsoleAi::Storage::DatabaseStorage##{method} failed: #{error.class}: #{error.message}")
      end
    end
  end
end
