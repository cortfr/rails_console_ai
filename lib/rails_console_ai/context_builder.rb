module RailsConsoleAi
  class ContextBuilder
    def initialize(config = RailsConsoleAi.configuration, channel_mode: nil, user_name: nil)
      @config = config
      @channel_mode = channel_mode
      @user_name = user_name
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
      parts << trusted_methods_context
      parts << skills_context
      parts << user_extra_info_context
      parts << pinned_memory_context
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
        Use them as needed to write accurate queries. For example, call list_models to see what
        models exist, then describe_model to get columns, associations, and validations.
        Use describe_table only for tables that have no corresponding model.

        You also have an ask_user tool to ask the console user clarifying questions. Use it when
        you need specific information to write accurate code — such as which user they are, which
        record to target, or what value to use.

        You have memory tools to persist what you learn across sessions:
        - save_memory: persist facts or procedures you learn about this codebase.
          If a memory with the same name already exists, it will be updated in place.
        - delete_memory: remove a memory by name
        - recall_memory: retrieve a specific memory by name. Use when you see a relevant memory
          in the Memories section and want its full details.
        - recall_memories: search memories by keyword or tag. Use when you're not sure which
          memory you need.

        IMPORTANT: Check the Memories section below BEFORE answering. If a memory is relevant,
        use recall_memories to get full details and apply that knowledge to your answer.
        When you use a memory, mention it briefly (e.g. "Based on what I know about sharding...").
        When you discover important patterns about this app, save them as memories.

        You have tools for executing Ruby code:
        - Use execute_code for simple queries and single operations.
        - Use execute_plan for multi-step tasks that require sequential operations. Each step
          has a description and Ruby code. The plan is shown to the user for review before
          execution begins. After each step runs, its return value is stored as step1, step2,
          etc. — use these variables in later steps to reference earlier results
          (e.g. `api = SalesforceApi.new(step1)`).
        - If the user asks you to provide code for them to run later (not execute now), put it
          in a ```ruby code block in your text response.
        You have skills — reusable procedures for specific operations:
        - When a user's request matches an existing skill, call activate_skill to load the recipe
          and enable its guard bypasses, then follow the recipe.
        - When a user asks you to "create a skill" or "make a runbook", use save_skill to create
          a new skill with a step-by-step recipe. Skills are procedures (how to do X); memories
          are facts (what you learned about X). Do NOT use save_memory when asked to create a skill.

        RULES:
        - Give ONE concise answer. Do not offer multiple alternatives or variations.
        - For multi-step tasks, use execute_plan to break the work into small, clear steps.
        - For simple queries, use the execute_code tool.
        - Before calling tools, briefly state what you're about to do (e.g., "Let me check the
          user's migration status." or "I'll look up the table structure."). Keep it to one sentence.
        - Use the app's actual model names, associations, and schema.
        - Prefer ActiveRecord query interface over raw SQL.
        - For destructive operations, add a comment warning.
        - NEVER use placeholder values like YOUR_USER_ID or YOUR_EMAIL in code. If you need
          a specific value from the user, call the ask_user tool to get it first.
        - Keep code concise and idiomatic.
        - Use tools to look up schema/model details rather than guessing column names.
      PROMPT
    end

    def trusted_methods_context
      methods = Array(@config.bypass_guards_for_methods)
      if @channel_mode
        channel_cfg = @config.channels[@channel_mode] || {}
        methods = methods | Array(channel_cfg['bypass_guards_for_methods'])
      end
      return nil if methods.empty?

      lines = ["## Trusted Methods (safety guards bypassed automatically)"]
      methods.each { |m| lines << "- #{m}" }
      lines.join("\n")
    end

    def guide_context
      content = RailsConsoleAi.storage.read(RailsConsoleAi::GUIDE_KEY)
      return nil if content.nil? || content.strip.empty?

      "## Application Guide\n\n#{content.strip}"
    rescue => e
      RailsConsoleAi.logger.debug("RailsConsoleAi: guide context failed: #{e.message}")
      nil
    end

    def skills_context
      require 'rails_console_ai/skill_loader'
      summaries = RailsConsoleAi::SkillLoader.new.skill_summaries
      return nil if summaries.nil? || summaries.empty?

      lines = ["## Skills (call activate_skill to use)"]
      lines.concat(summaries)
      lines.join("\n")
    rescue => e
      RailsConsoleAi.logger.debug("RailsConsoleAi: skills context failed: #{e.message}")
      nil
    end

    def user_extra_info_context
      info = @config.resolve_user_extra_info(@user_name)
      return nil if info.nil? || info.strip.empty?

      "## Current User\n\nUser: #{@user_name}\n#{info}"
    end

    def pinned_memory_context
      return nil unless @channel_mode

      channel_cfg = @config.channels[@channel_mode] || {}
      pinned_tags = channel_cfg['pinned_memory_tags'] || []
      return nil if pinned_tags.empty?

      require 'rails_console_ai/tools/memory_tools'
      sections = pinned_tags.filter_map do |tag|
        content = Tools::MemoryTools.new.recall_memories(tag: tag)
        next if content.nil? || content.include?("No memories")
        content
      end
      return nil if sections.empty?

      "## Pinned Memories (always available — no need to recall_memories for these)\n\n" \
        + sections.join("\n\n")
    rescue => e
      RailsConsoleAi.logger.debug("RailsConsoleAi: pinned memory context failed: #{e.message}")
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
      lines << "Call recall_memory (by name) or recall_memories (by keyword) to get details before answering. Do NOT guess from the name alone."
      lines.join("\n")
    rescue => e
      RailsConsoleAi.logger.debug("RailsConsoleAi: memory context failed: #{e.message}")
      nil
    end

  end
end
