require 'yaml'
require 'rails_console_ai/storage/database_storage'

module RailsConsoleAi
  class AgentLoader
    AGENTS_DIR = 'agents'
    BUILTIN_DIR = File.expand_path('../agents', __FILE__)

    def initialize(storage = nil)
      @storage = storage || RailsConsoleAi.storage
    end

    # Three-source union: DB > file > built-in.
    # Each record is tagged with `source: :db | :file | :builtin`. DB records
    # also carry `status`, `approved_by`, `approved_at`. Proposed (unapproved)
    # DB agents are surfaced here so the admin UI can render them — use
    # #load_activatable_agents on AI-facing paths to filter them out.
    def load_all_agents
      db      = safe_load_db_agents
      file    = safe_load_file_agents
      builtin = safe_load_builtin_agents

      db_names = db.map { |a| a['name'].to_s.downcase }
      file.reject! { |a| db_names.include?(a['name'].to_s.downcase) }

      file_names = file.map { |a| a['name'].to_s.downcase }
      builtin.reject! { |a| db_names.include?(a['name'].to_s.downcase) || file_names.include?(a['name'].to_s.downcase) }

      (db + file + builtin).sort_by { |a| a['name'].to_s.downcase }
    end

    # AI-facing: hides proposed DB agents. File + built-in are pre-approved.
    def load_activatable_agents
      load_all_agents.reject { |a| a['source'] == :db && a['status'] != 'approved' }
    end

    def agent_summaries
      agents = load_activatable_agents
      return nil if agents.empty?

      agents.map { |a|
        "- **#{a['name']}**: #{a['description']}"
      }
    end

    # AI-facing — returns nil for proposed DB agents so delegate_task can't reach them.
    def find_agent(name)
      load_activatable_agents.find { |a| a['name'].to_s.downcase == name.to_s.downcase }
    end

    # UI-facing — includes proposed DB agents.
    def find_any_agent(name)
      load_all_agents.find { |a| a['name'].to_s.downcase == name.to_s.downcase }
    end

    # target: :db (default) | :file
    # Falls back to :file (with a notice in the return string) if DB tables aren't set up.
    def save_agent(name:, description:, body:, max_rounds: nil, model: nil, tools: nil, target: :db, edited_by: nil, change_note: nil)
      target = (target || :db).to_sym
      db_fell_back = false
      if target == :db && !Storage::DatabaseStorage.agents_available?
        target = :file
        db_fell_back = true
      end

      if target == :file
        result = save_agent_to_file(
          name: name, description: description, body: body,
          max_rounds: max_rounds, model: model, tools: tools
        )
        if db_fell_back
          result += "\nNOTE: DB storage was requested but the rails_console_ai_agents table does not exist. " \
                    "Run `ai_db_setup` in your Rails console to enable the versioned DB store. " \
                    "Saved to a file instead."
        end
        result
      else
        record, was_new = Storage::DatabaseStorage.save_agent(
          name: name, description: description, body: body,
          max_rounds: max_rounds, model: model, tools: Array(tools),
          edited_by: edited_by || 'ai', change_note: change_note
        )
        status_note = if record.respond_to?(:proposed?) && record.proposed?
                        ' — status: PROPOSED. A human must approve it at /rails_console_ai/agents before delegate_task can invoke it.'
                      else
                        ''
                      end
        if was_new
          "Agent created (db): \"#{record.name}\" (id=#{record.id})#{status_note}"
        else
          "Agent updated (db): \"#{record.name}\" (id=#{record.id})#{status_note}"
        end
      end
    rescue Storage::StorageError, ::ActiveRecord::RecordInvalid => e
      "FAILED to save agent (#{e.message})."
    end

    # Tries DB first, then file. Built-in agents can't be deleted.
    def delete_agent(name:)
      if Storage::DatabaseStorage.delete_agent_by_name(name)
        return "Agent deleted (db): \"#{name}\""
      end

      # Built-in agents are gem-shipped and not deletable.
      builtin = safe_load_builtin_agents.find { |a| a['name'].to_s.downcase == name.to_s.downcase }
      if builtin
        return "Cannot delete built-in agent \"#{builtin['name']}\". Built-in agents ship with the gem. " \
               "Create a same-named DB agent to override it instead."
      end

      key = agent_key(name)
      unless @storage.exists?(key)
        found = safe_load_file_agents.find { |a| a['name'].to_s.downcase == name.to_s.downcase }
        return "No agent found: \"#{name}\"" unless found
        key = agent_key(found['name'])
      end

      agent = load_agent_file(key)
      @storage.delete(key)
      "Agent deleted: \"#{agent ? agent['name'] : name}\""
    rescue Storage::StorageError => e
      "FAILED to delete agent (#{e.message})."
    end

    private

    def safe_load_db_agents
      Storage::DatabaseStorage.all_agents
    end

    def safe_load_file_agents
      keys = @storage.list("#{AGENTS_DIR}/*.md")
      keys.filter_map { |key|
        agent = load_agent_file(key)
        next nil unless agent
        agent.merge('source' => :file, 'file_key' => key)
      }
    rescue => e
      RailsConsoleAi.logger.warn("RailsConsoleAi: failed to load file agents: #{e.message}")
      []
    end

    def safe_load_builtin_agents
      return [] unless File.directory?(BUILTIN_DIR)
      Dir.glob(File.join(BUILTIN_DIR, '*.md')).sort.filter_map do |path|
        # Explicit UTF-8 — File.read defaults to the locale encoding, which on
        # some CI / spec setups is US-ASCII and chokes on em-dashes etc.
        content = File.read(path, encoding: 'UTF-8')
        agent = parse_agent(content)
        next nil unless agent
        agent.merge('source' => :builtin, 'builtin' => true, 'file_key' => path)
      end
    rescue => e
      RailsConsoleAi.logger.debug("RailsConsoleAi: failed to load built-in agents: #{e.message}")
      []
    end

    def save_agent_to_file(name:, description:, body:, max_rounds:, model:, tools:)
      key = agent_key(name)
      existing = load_agent_file(key)

      frontmatter = {
        'name' => name,
        'description' => description
      }
      frontmatter['max_rounds'] = max_rounds if max_rounds
      frontmatter['model'] = model if model
      tool_list = Array(tools)
      frontmatter['tools'] = tool_list unless tool_list.empty?

      content = "---\n#{YAML.dump(frontmatter).sub("---\n", '').strip}\n---\n\n#{body}\n"
      @storage.write(key, content)

      path = @storage.respond_to?(:root_path) ? File.join(@storage.root_path, key) : key
      if existing
        "Agent updated: \"#{name}\" (#{path})"
      else
        "Agent created: \"#{name}\" (#{path})"
      end
    end

    def agent_key(name)
      slug = name.downcase.strip
        .gsub(/[^a-z0-9\s-]/, '')
        .gsub(/[\s]+/, '-')
        .gsub(/-+/, '-')
        .sub(/^-/, '').sub(/-$/, '')
      "#{AGENTS_DIR}/#{slug}.md"
    end

    def load_agent_file(key)
      content = @storage.read(key)
      return nil if content.nil? || content.strip.empty?
      parse_agent(content)
    rescue => e
      RailsConsoleAi.logger.warn("RailsConsoleAi: failed to load agent #{key}: #{e.message}")
      nil
    end

    def parse_agent(content)
      return nil unless content =~ /\A---\s*\n(.*?\n)---\s*\n(.*)/m
      frontmatter = YAML.safe_load($1, permitted_classes: [Time, Date]) || {}
      body = $2.strip
      frontmatter.merge('body' => body)
    end
  end
end
