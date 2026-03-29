require 'yaml'

module RailsConsoleAi
  class AgentLoader
    AGENTS_DIR = 'agents'
    BUILTIN_DIR = File.expand_path('../agents', __FILE__)

    def initialize(storage = nil)
      @storage = storage || RailsConsoleAi.storage
    end

    def load_all_agents
      agents = load_builtin_agents
      app_agents = load_app_agents
      # App-specific agents override built-ins with the same name
      app_names = app_agents.map { |a| a['name'].to_s.downcase }.to_set
      agents.reject! { |a| app_names.include?(a['name'].to_s.downcase) }
      agents.concat(app_agents)
      agents
    rescue => e
      RailsConsoleAi.logger.warn("RailsConsoleAi: failed to load agents: #{e.message}")
      []
    end

    def agent_summaries
      agents = load_all_agents
      return nil if agents.empty?

      agents.map { |a|
        "- **#{a['name']}**: #{a['description']}"
      }
    end

    def find_agent(name)
      agents = load_all_agents
      agents.find { |a| a['name'].to_s.downcase == name.to_s.downcase }
    end

    def save_agent(name:, description:, body:, max_rounds: nil, model: nil, tools: nil)
      key = agent_key(name)
      existing = find_agent(name)

      frontmatter = {
        'name' => name,
        'description' => description
      }
      frontmatter['max_rounds'] = max_rounds if max_rounds
      frontmatter['model'] = model if model
      frontmatter['tools'] = Array(tools) if tools && !tools.empty?

      content = "---\n#{YAML.dump(frontmatter).sub("---\n", '').strip}\n---\n\n#{body}\n"
      @storage.write(key, content)

      path = @storage.respond_to?(:root_path) ? File.join(@storage.root_path, key) : key
      if existing
        "Agent updated: \"#{name}\" (#{path})"
      else
        "Agent created: \"#{name}\" (#{path})"
      end
    rescue Storage::StorageError => e
      "FAILED to save agent (#{e.message})."
    end

    def delete_agent(name:)
      key = agent_key(name)
      unless @storage.exists?(key)
        found = load_all_agents.find { |a| a['name'].to_s.downcase == name.to_s.downcase }
        return "No agent found: \"#{name}\"" unless found
        key = agent_key(found['name'])
      end

      agent = load_agent(key)
      @storage.delete(key)
      "Agent deleted: \"#{agent ? agent['name'] : name}\""
    rescue Storage::StorageError => e
      "FAILED to delete agent (#{e.message})."
    end

    private

    def load_builtin_agents
      return [] unless File.directory?(BUILTIN_DIR)
      Dir.glob(File.join(BUILTIN_DIR, '*.md')).sort.filter_map do |path|
        content = File.read(path)
        agent = parse_agent(content)
        agent['builtin'] = true if agent
        agent
      end
    rescue => e
      RailsConsoleAi.logger.debug("RailsConsoleAi: failed to load built-in agents: #{e.message}")
      []
    end

    def load_app_agents
      keys = @storage.list("#{AGENTS_DIR}/*.md")
      keys.filter_map { |key| load_agent(key) }
    rescue => e
      []
    end

    def agent_key(name)
      slug = name.downcase.strip
        .gsub(/[^a-z0-9\s-]/, '')
        .gsub(/[\s]+/, '-')
        .gsub(/-+/, '-')
        .sub(/^-/, '').sub(/-$/, '')
      "#{AGENTS_DIR}/#{slug}.md"
    end

    def load_agent(key)
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
