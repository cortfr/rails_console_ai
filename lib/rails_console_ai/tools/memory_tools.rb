require 'yaml'
require 'rails_console_ai/storage/database_storage'

module RailsConsoleAi
  module Tools
    class MemoryTools
      MEMORIES_DIR = 'memories'

      def initialize(storage = nil)
        @storage = storage || RailsConsoleAi.storage
      end

      # target: :db (default) | :file
      # Falls back to :file (with a notice in the return string) if DB tables aren't set up.
      def save_memory(name:, description:, tags: [], target: :db, edited_by: nil, change_note: nil)
        target = (target || :db).to_sym
        db_fell_back = false
        if target == :db && !Storage::DatabaseStorage.memories_available?
          target = :file
          db_fell_back = true
        end

        if target == :file
          result = save_memory_to_file(name: name, description: description, tags: tags)
          if db_fell_back
            result += "\nNOTE: DB storage was requested but the rails_console_ai_memories table does not exist. " \
                      "Run `ai_db_setup` in your Rails console to enable the versioned DB store. " \
                      "Saved to a file instead."
          end
          result
        else
          record, was_new = Storage::DatabaseStorage.save_memory(
            name: name, description: description, tags: tags,
            edited_by: edited_by || 'ai', change_note: change_note
          )
          if was_new
            "Memory saved (db): \"#{record.name}\" (id=#{record.id})"
          else
            "Memory updated (db): \"#{record.name}\" (id=#{record.id})"
          end
        end
      rescue Storage::StorageError => e
        if target == :file
          # Preserve the original behaviour: include a hint with the raw frontmatter
          # so the user (or AI) can paste it manually when the filesystem is read-only.
          "FAILED to save (#{e.message}). Add this manually to .rails_console_ai/#{memory_key(name)}:\n" \
          "---\nname: #{name}\ntags: #{Array(tags).inspect}\n---\n\n#{description}"
        else
          "FAILED to save (#{e.message})."
        end
      rescue ::ActiveRecord::RecordInvalid => e
        "FAILED to save (#{e.message})."
      end

      def delete_memory(name:)
        if Storage::DatabaseStorage.delete_memory_by_name(name)
          return "Memory deleted (db): \"#{name}\""
        end

        key = memory_key(name)
        unless @storage.exists?(key)
          found_key = find_memory_key_by_name(name)
          return "No memory found: \"#{name}\"" unless found_key
          key = found_key
        end

        memory = load_memory_file(key)
        @storage.delete(key)
        "Memory deleted: \"#{memory ? memory['name'] : name}\""
      rescue Storage::StorageError => e
        "FAILED to delete memory (#{e.message})."
      end

      def recall_memory(name:)
        memory = load_all_memories.find { |m| m['name'].to_s.downcase == name.to_s.downcase }
        return "No memory found: \"#{name}\"" unless memory

        line = "**#{memory['name']}**\n#{memory['description']}"
        line += "\nTags: #{memory['tags'].join(', ')}" if memory['tags'] && !memory['tags'].empty?
        line
      end

      def recall_memories(query: nil, tag: nil)
        memories = load_all_memories
        return "No memories stored yet." if memories.empty?

        results = memories
        if tag && !tag.empty?
          results = results.select { |m|
            Array(m['tags']).any? { |t| t.downcase.include?(tag.downcase) }
          }
        end
        if query && !query.empty?
          words = query.downcase.split(/\s+/)
          results = results.select { |m|
            searchable = [
              m['name'].to_s.downcase,
              m['description'].to_s.downcase,
              Array(m['tags']).map(&:downcase).join(' ')
            ].join(' ')
            words.all? { |w| searchable.include?(w) }
          }
        end

        return "No memories matching your search." if results.empty?

        results.map { |m|
          line = "**#{m['name']}**\n#{m['description']}"
          line += "\nTags: #{m['tags'].join(', ')}" if m['tags'] && !m['tags'].empty?
          line
        }.join("\n\n---\n\n")
      end

      def memory_summaries
        memories = load_all_memories
        return nil if memories.empty?

        memories.map { |m|
          tags = Array(m['tags'])
          tag_str = tags.empty? ? '' : " [#{tags.join(', ')}]"
          "- #{m['name']}#{tag_str}"
        }
      end

      def load_all_memories
        db = Storage::DatabaseStorage.all_memories
        file = load_all_file_memories
        names = db.map { |m| m['name'].to_s.downcase }
        file.reject! { |m| names.include?(m['name'].to_s.downcase) }
        (db + file).sort_by { |m| m['name'].to_s.downcase }
      end

      private

      def save_memory_to_file(name:, description:, tags:)
        key = memory_key(name)
        existing = load_memory_file(key)

        frontmatter = {
          'name' => name,
          'tags' => Array(tags).empty? && existing ? (existing['tags'] || []) : Array(tags),
          'created_at' => existing ? existing['created_at'] : Time.now.utc.iso8601
        }
        frontmatter['updated_at'] = Time.now.utc.iso8601 if existing

        content = "---\n#{YAML.dump(frontmatter).sub("---\n", '').strip}\n---\n\n#{description}\n"
        @storage.write(key, content)

        path = @storage.respond_to?(:root_path) ? File.join(@storage.root_path, key) : key
        if existing
          "Memory updated: \"#{name}\" (#{path})"
        else
          "Memory saved: \"#{name}\" (#{path})"
        end
      end

      def memory_key(name)
        slug = name.downcase.strip
          .gsub(/[^a-z0-9\s-]/, '')
          .gsub(/[\s]+/, '-')
          .gsub(/-+/, '-')
          .sub(/^-/, '').sub(/-$/, '')
        "#{MEMORIES_DIR}/#{slug}.md"
      end

      def load_memory_file(key)
        content = @storage.read(key)
        return nil if content.nil? || content.strip.empty?
        parse_memory(content)
      rescue => e
        RailsConsoleAi.logger.warn("RailsConsoleAi: failed to load memory #{key}: #{e.message}")
        nil
      end

      def load_all_file_memories
        keys = @storage.list("#{MEMORIES_DIR}/*.md")
        keys.filter_map { |key|
          memory = load_memory_file(key)
          next nil unless memory
          memory.merge('source' => :file, 'file_key' => key)
        }
      rescue => e
        RailsConsoleAi.logger.warn("RailsConsoleAi: failed to load memories: #{e.message}")
        []
      end

      def parse_memory(content)
        return nil unless content =~ /\A---\s*\n(.*?\n)---\s*\n(.*)/m
        frontmatter = YAML.safe_load($1, permitted_classes: [Time, Date]) || {}
        description = $2.strip
        frontmatter.merge('description' => description)
      end

      def find_memory_key_by_name(name)
        keys = @storage.list("#{MEMORIES_DIR}/*.md")
        keys.find do |key|
          memory = load_memory_file(key)
          memory && memory['name'].to_s.downcase == name.to_s.downcase
        end
      end
    end
  end
end
