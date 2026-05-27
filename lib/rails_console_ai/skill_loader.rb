require 'yaml'
require 'rails_console_ai/storage/database_storage'

module RailsConsoleAi
  class SkillLoader
    SKILLS_DIR = 'skills'

    def initialize(storage = nil)
      @storage = storage || RailsConsoleAi.storage
    end

    # Returns the union of DB-backed skills and file-backed skills.
    # When the same name appears in both, the DB record wins and the file
    # record is shadowed (but the file isn't touched).
    def load_all_skills
      db = safe_load_db_skills
      file = safe_load_file_skills

      names = db.map { |s| s['name'].to_s.downcase }
      file.reject! { |s| names.include?(s['name'].to_s.downcase) }

      (db + file).sort_by { |s| s['name'].to_s.downcase }
    end

    def skill_summaries
      skills = load_all_skills
      return nil if skills.empty?

      skills.map { |s|
        tags = Array(s['tags'])
        tag_str = tags.empty? ? '' : " [#{tags.join(', ')}]"
        "- **#{s['name']}**#{tag_str}: #{s['description']}"
      }
    end

    def find_skill(name)
      load_all_skills.find { |s| s['name'].to_s.downcase == name.to_s.downcase }
    end

    # target: :db (default) | :file
    # Falls back to :file (with a notice in the return string) if DB tables aren't set up.
    def save_skill(name:, description:, body:, tags: [], bypass_guards_for_methods: [], target: :db, edited_by: nil, change_note: nil)
      target = (target || :db).to_sym
      db_fell_back = false
      if target == :db && !Storage::DatabaseStorage.available?
        target = :file
        db_fell_back = true
      end

      if target == :file
        result = save_skill_to_file(
          name: name, description: description, body: body,
          tags: tags, bypass_guards_for_methods: bypass_guards_for_methods
        )
        if db_fell_back
          result += "\nNOTE: DB storage was requested but the rails_console_ai_skills table does not exist. " \
                    "Run `ai_db_setup` in your Rails console to enable the versioned DB store. " \
                    "Saved to a file instead."
        end
        result
      else
        record, was_new = Storage::DatabaseStorage.save_skill(
          name: name, description: description, body: body,
          tags: tags, bypass_guards_for_methods: bypass_guards_for_methods,
          edited_by: edited_by || 'ai', change_note: change_note
        )
        if was_new
          "Skill created (db): \"#{record.name}\" (id=#{record.id})"
        else
          "Skill updated (db): \"#{record.name}\" (id=#{record.id})"
        end
      end
    rescue Storage::StorageError, ::ActiveRecord::RecordInvalid => e
      "FAILED to save skill (#{e.message})."
    end

    # Tries DB first, falls back to file. Reports which source it removed from.
    def delete_skill(name:)
      if Storage::DatabaseStorage.delete_skill_by_name(name)
        return "Skill deleted (db): \"#{name}\""
      end

      key = skill_key(name)
      unless @storage.exists?(key)
        found = safe_load_file_skills.find { |s| s['name'].to_s.downcase == name.to_s.downcase }
        return "No skill found: \"#{name}\"" unless found
        key = skill_key(found['name'])
      end

      skill = load_skill_file(key)
      @storage.delete(key)
      "Skill deleted: \"#{skill ? skill['name'] : name}\""
    rescue Storage::StorageError => e
      "FAILED to delete skill (#{e.message})."
    end

    private

    def save_skill_to_file(name:, description:, body:, tags:, bypass_guards_for_methods:)
      key = skill_key(name)
      existing = load_skill_file(key)

      frontmatter = {
        'name' => name,
        'description' => description,
        'tags' => Array(tags)
      }
      bypasses = Array(bypass_guards_for_methods)
      frontmatter['bypass_guards_for_methods'] = bypasses unless bypasses.empty?

      content = "---\n#{YAML.dump(frontmatter).sub("---\n", '').strip}\n---\n\n#{body}\n"
      @storage.write(key, content)

      path = @storage.respond_to?(:root_path) ? File.join(@storage.root_path, key) : key
      if existing
        "Skill updated: \"#{name}\" (#{path})"
      else
        "Skill created: \"#{name}\" (#{path})"
      end
    end

    def safe_load_db_skills
      Storage::DatabaseStorage.all_skills
    end

    def safe_load_file_skills
      keys = @storage.list("#{SKILLS_DIR}/*.md")
      keys.filter_map { |key|
        skill = load_skill_file(key)
        next nil unless skill
        skill.merge('source' => :file, 'file_key' => key)
      }
    rescue => e
      RailsConsoleAi.logger.warn("RailsConsoleAi: failed to load file skills: #{e.message}")
      []
    end

    def skill_key(name)
      slug = name.downcase.strip
        .gsub(/[^a-z0-9\s-]/, '')
        .gsub(/[\s]+/, '-')
        .gsub(/-+/, '-')
        .sub(/^-/, '').sub(/-$/, '')
      "#{SKILLS_DIR}/#{slug}.md"
    end

    def load_skill_file(key)
      content = @storage.read(key)
      return nil if content.nil? || content.strip.empty?
      parse_skill(content)
    rescue => e
      RailsConsoleAi.logger.warn("RailsConsoleAi: failed to load skill #{key}: #{e.message}")
      nil
    end

    def parse_skill(content)
      return nil unless content =~ /\A---\s*\n(.*?\n)---\s*\n(.*)/m
      frontmatter = YAML.safe_load($1, permitted_classes: [Time, Date]) || {}
      body = $2.strip
      frontmatter.merge('body' => body)
    end
  end
end
