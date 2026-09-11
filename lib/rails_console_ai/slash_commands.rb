require 'rails_console_ai/skill_loader'
require 'rails_console_ai/agent_loader'

module RailsConsoleAi
  # The union of everything a user can invoke by typing "/" in interactive mode:
  # the fixed REPL commands, plus every activatable skill and agent, each exposed
  # under a slug derived from its display name ("Restart user trial" -> /restart-user-trial).
  #
  # Backs three surfaces that must agree with each other: the "/" listing, the
  # completion candidates offered by the line editor, and the dispatcher that
  # decides what a typed slash command actually does.
  class SlashCommands
    Command = Struct.new(:slug, :name, :description, :kind, :record, keyword_init: true) do
      def builtin?; kind == :builtin; end
      def skill?;   kind == :skill;   end
      def agent?;   kind == :agent;   end
    end

    KIND_LABELS = { builtin: 'command', skill: 'skill', agent: 'agent' }.freeze

    # Slug => one-line help. Order is the order they render in the listing.
    # Descriptions that depend on live state (auto-execute on/off, safe mode)
    # are filled in by the channel at render time; these are the static fallbacks.
    BUILTINS = {
      'auto'    => 'Toggle auto-execute',
      'danger'  => 'Toggle safe mode',
      'safe'    => 'Show safety guard status',
      'model'   => 'Show provider, model, and pricing info',
      'think'   => 'Switch to thinking model',
      'unthink' => 'Switch back to default model',
      'compact' => 'Summarize conversation to reduce context',
      'usage'   => 'Show session token totals',
      'cost'    => 'Show cost estimate by model',
      'name'    => 'Name this session for easy resume',
      'context' => 'Show conversation history sent to the LLM',
      'system'  => 'Show the system prompt',
      'expand'  => 'Show full omitted output',
      'debug'   => 'Toggle debug summaries',
      'retry'   => 'Re-execute the last code block'
    }.freeze

    # "Restart user trial" -> restart-user-trial.
    #
    # Close to SkillLoader#skill_key / AgentLoader#agent_key, but kinder to names
    # that aren't plain prose: those two drop "/" and case boundaries outright,
    # which turns "Approve/Reject ChangeApprovals" into the unreadable
    # "approvereject-changeapprovals". Here every boundary a human would read as
    # a word break becomes a dash. The slug is only ever a handle for typing and
    # dispatch — file lookup still goes through the loaders — so the two are free
    # to differ.
    def self.slugify(name)
      name.to_s.strip
        .gsub(%r{[/_\s]+}, '-')                       # separators
        .gsub(/([a-z0-9])([A-Z])/, '\1-\2')           # fooBar    -> foo-Bar
        .gsub(/([A-Z]+)([A-Z][a-z])/, '\1-\2')        # HTTPToken -> HTTP-Token
        .downcase
        .gsub(/[^a-z0-9-]/, '')
        .gsub(/-+/, '-')
        .sub(/\A-/, '').sub(/-\z/, '')
    end

    def initialize(skill_loader: nil, agent_loader: nil)
      @skill_loader = skill_loader
      @agent_loader = agent_loader
    end

    # Loading skills and agents touches the DB and the filesystem, and completion
    # runs on every keystroke — so the list is built once and reused until something
    # that could have changed it (a save_skill/save_agent tool call) finishes.
    def refresh!
      @commands = nil
      self
    end

    def commands
      @commands ||= build
    end

    def skills
      commands.select(&:skill?)
    end

    def agents
      commands.select(&:agent?)
    end

    # Completion candidates, already "/"-prefixed.
    def candidates
      commands.map { |c| "/#{c.slug}" }
    end

    # [slug, kind label] pairs for the line editor. The label is what lets a Tab
    # list say which entries are built-in commands and which are skills or agents.
    def completion_entries
      commands.map { |c| ["/#{c.slug}", KIND_LABELS[c.kind]] }
    end

    def find(slug)
      slug = slug.to_s.sub(%r{\A/}, '').downcase
      commands.find { |c| c.slug == slug }
    end

    private

    def build
      builtins = BUILTINS.map do |slug, desc|
        Command.new(slug: slug, name: slug, description: desc, kind: :builtin, record: nil)
      end

      taken = builtins.map(&:slug)

      skills = safe(:skills) do
        skill_loader.load_activatable_skills.filter_map do |s|
          slug = self.class.slugify(s['name'])
          next if slug.empty? || taken.include?(slug)
          taken << slug
          Command.new(slug: slug, name: s['name'], description: s['description'], kind: :skill, record: s)
        end
      end

      agents = safe(:agents) do
        agent_loader.load_activatable_agents.filter_map do |a|
          slug = self.class.slugify(a['name'])
          next if slug.empty? || taken.include?(slug)
          taken << slug
          Command.new(slug: slug, name: a['name'], description: a['description'], kind: :agent, record: a)
        end
      end

      builtins + skills.sort_by(&:slug) + agents.sort_by(&:slug)
    end

    # A broken skill file or an unmigrated database must not take down the prompt.
    def safe(what)
      yield
    rescue => e
      RailsConsoleAi.logger.warn("RailsConsoleAi: failed to load #{what} for slash commands: #{e.message}")
      []
    end

    def skill_loader
      @skill_loader ||= SkillLoader.new
    end

    def agent_loader
      @agent_loader ||= AgentLoader.new
    end
  end
end
