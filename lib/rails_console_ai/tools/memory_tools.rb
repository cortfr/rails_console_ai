require 'yaml'

module RailsConsoleAi
  module Tools
    class MemoryTools
      MEMORIES_DIR = 'memories'

      def initialize(storage = nil)
        @storage = storage || RailsConsoleAi.storage
      end

      def save_memory(name:, description:, tags: [])
        key = memory_key(name)
        existing = load_memory(key)

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
      rescue Storage::StorageError => e
        "FAILED to save (#{e.message}). Add this manually to .rails_console_ai/#{key}:\n" \
        "---\nname: #{name}\ntags: #{Array(tags).inspect}\n---\n\n#{description}"
      end

      def delete_memory(name:)
        key = memory_key(name)
        unless @storage.exists?(key)
          # Try to find by name match across all memory files
          found_key = find_memory_key_by_name(name)
          return "No memory found: \"#{name}\"" unless found_key
          key = found_key
        end

        memory = load_memory(key)
        @storage.delete(key)
        "Memory deleted: \"#{memory ? memory['name'] : name}\""
      rescue Storage::StorageError => e
        "FAILED to delete memory (#{e.message})."
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
          q = query.downcase
          results = results.select { |m|
            m['name'].to_s.downcase.include?(q) ||
            m['description'].to_s.downcase.include?(q) ||
            Array(m['tags']).any? { |t| t.downcase.include?(q) }
          }
        end

        return "No memories matching your search." if results.empty?

        results.map { |m|
          line = "**#{m['name']}**\n#{m['description']}"
          line += "\nTags: #{m['tags'].join(', ')}" if m['tags'] && !m['tags'].empty?
          line
        }.join("\n\n")
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

      private

      def memory_key(name)
        slug = name.downcase.strip
          .gsub(/[^a-z0-9\s-]/, '')
          .gsub(/[\s]+/, '-')
          .gsub(/-+/, '-')
          .sub(/^-/, '').sub(/-$/, '')
        "#{MEMORIES_DIR}/#{slug}.md"
      end

      def load_memory(key)
        content = @storage.read(key)
        return nil if content.nil? || content.strip.empty?
        parse_memory(content)
      rescue => e
        RailsConsoleAi.logger.warn("RailsConsoleAi: failed to load memory #{key}: #{e.message}")
        nil
      end

      def load_all_memories
        keys = @storage.list("#{MEMORIES_DIR}/*.md")
        keys.map { |key| load_memory(key) }.compact
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
          memory = load_memory(key)
          memory && memory['name'].to_s.downcase == name.downcase
        end
      end
    end
  end
end
