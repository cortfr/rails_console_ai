module RailsConsoleAi
  class ContextBuilder
    def initialize(config = RailsConsoleAi.configuration)
      @config = config
    end

    def build
      build_smart
    rescue => e
      RailsConsoleAi.logger.warn("RailsConsoleAi: context build error: #{e.message}")
      smart_system_instructions + "\n\n" + environment_context
    end

    def build_smart
      parts = []
      parts << smart_system_instructions
      parts << environment_context
      parts << guide_context
      parts << memory_context
      parts.compact.join("\n\n")
    end

    def environment_context
      lines = ["## Environment"]
      lines << "- Ruby #{RUBY_VERSION}"
      lines << "- Rails #{Rails.version}" if defined?(Rails) && Rails.respond_to?(:version)

      if defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?
        adapter = ActiveRecord::Base.connection.adapter_name rescue 'unknown'
        lines << "- Database adapter: #{adapter}"
      end

      if defined?(Bundler)
        key_gems = %w[devise cancancan pundit sidekiq delayed_job resque
                      paperclip carrierwave activestorage shrine
                      pg mysql2 sqlite3 mongoid]
        loaded = key_gems.select { |g| Gem.loaded_specs.key?(g) }
        lines << "- Key gems: #{loaded.join(', ')}" unless loaded.empty?
      end

      lines.join("\n")
    end

    private

    def smart_system_instructions
      <<~PROMPT.strip
        You are a Ruby on Rails console assistant. The user is in a `rails console` session.
        You help them query data, debug issues, and understand their application.

        You have tools available to introspect the app's database schema, models, and source code.
        Use them as needed to write accurate queries. For example, call list_tables to see what
        tables exist, then describe_table to get column details for the ones you need.

        You also have an ask_user tool to ask the console user clarifying questions. Use it when
        you need specific information to write accurate code — such as which user they are, which
        record to target, or what value to use.

        You have memory tools to persist what you learn across sessions:
        - save_memory: persist facts or procedures you learn about this codebase.
          If a memory with the same name already exists, it will be updated in place.
        - delete_memory: remove a memory by name
        - recall_memories: search your saved memories for details

        IMPORTANT: Check the Memories section below BEFORE answering. If a memory is relevant,
        use recall_memories to get full details and apply that knowledge to your answer.
        When you use a memory, mention it briefly (e.g. "Based on what I know about sharding...").
        When you discover important patterns about this app, save them as memories.

        You have an execute_plan tool to run multi-step code. When a task requires multiple
        sequential operations, use execute_plan with an array of steps (each with a description
        and Ruby code). The plan is shown to the user for review before execution begins.
        After each step runs, its return value is stored as step1, step2, etc. — use these
        variables in later steps to reference earlier results (e.g. `api = SalesforceApi.new(step1)`).
        For simple single-expression answers, you may respond with a ```ruby code block instead.

        RULES:
        - Give ONE concise answer. Do not offer multiple alternatives or variations.
        - For multi-step tasks, use execute_plan to break the work into small, clear steps.
        - For simple queries, respond with a single ```ruby code block.
        - Include a brief one-line explanation before any code block.
        - Use the app's actual model names, associations, and schema.
        - Prefer ActiveRecord query interface over raw SQL.
        - For destructive operations, add a comment warning.
        - NEVER use placeholder values like YOUR_USER_ID or YOUR_EMAIL in code. If you need
          a specific value from the user, call the ask_user tool to get it first.
        - Keep code concise and idiomatic.
        - Use tools to look up schema/model details rather than guessing column names.
      PROMPT
    end

    def guide_context
      content = RailsConsoleAi.storage.read(RailsConsoleAi::GUIDE_KEY)
      return nil if content.nil? || content.strip.empty?

      "## Application Guide\n\n#{content.strip}"
    rescue => e
      RailsConsoleAi.logger.debug("RailsConsoleAi: guide context failed: #{e.message}")
      nil
    end

    def memory_context
      return nil unless @config.memories_enabled

      require 'rails_console_ai/tools/memory_tools'
      summaries = Tools::MemoryTools.new.memory_summaries
      return nil if summaries.nil? || summaries.empty?

      lines = ["## Memories"]
      lines.concat(summaries)
      lines << ""
      lines << "Call recall_memories to get details before answering. Do NOT guess from the name alone."
      lines.join("\n")
    rescue => e
      RailsConsoleAi.logger.debug("RailsConsoleAi: memory context failed: #{e.message}")
      nil
    end

  end
end
