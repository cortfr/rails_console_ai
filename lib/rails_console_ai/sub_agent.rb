require 'rails_console_ai/channel/sub_agent'
require 'rails_console_ai/tools/registry'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/executor'

module RailsConsoleAi
  class SubAgent
    LOOP_WARN_THRESHOLD = 3
    LOOP_BREAK_THRESHOLD = 5
    LARGE_OUTPUT_THRESHOLD = 10_000
    LARGE_OUTPUT_PREVIEW_CHARS = 8_000

    attr_reader :input_tokens, :output_tokens, :model_used

    def initialize(task:, agent_config:, binding_context:, parent_channel:, executor:,
                   output_payload: nil, output_local_name: :output)
      @task = task
      @agent_config = agent_config || {}
      @binding_context = binding_context
      @parent_channel = parent_channel
      @parent_executor = executor
      @output_payload = output_payload
      @output_local_name = output_local_name
      @input_tokens = 0
      @output_tokens = 0
      @model_used = nil
    end

    def run
      channel = Channel::SubAgent.new(
        parent_channel: @parent_channel,
        task_label: @agent_config['name']
      )

      effective_binding =
        if @output_payload
          b = @binding_context.eval("proc { binding }.call")
          b.local_variable_set(@output_local_name, @output_payload)
          b
        else
          @binding_context
        end

      executor = Executor.new(effective_binding, channel: channel)
      allowed_tools = @agent_config['tools'] ? Array(@agent_config['tools']) : nil
      tools = Tools::Registry.new(executor: executor, mode: :sub_agent, channel: channel, allowed_tools: allowed_tools)
      provider = build_provider
      system_prompt = build_system_prompt
      max_rounds = @agent_config['max_rounds'] || RailsConsoleAi.configuration.sub_agent_max_rounds

      messages = [{ role: :user, content: @task }]

      run_tool_loop(messages, system_prompt: system_prompt, tools: tools,
                    provider: provider, channel: channel, executor: executor,
                    max_rounds: max_rounds)
    end

    private

    def run_tool_loop(messages, system_prompt:, tools:, provider:, channel:, executor:, max_rounds:)
      result = nil
      tool_call_counts = Hash.new(0)
      exhausted = false
      last_thinking = nil

      max_rounds.times do |round|
        break if channel.cancelled?

        if round > 0 && channel.respond_to?(:pending_guidance?) && channel.pending_guidance?
          pending = channel.drain_guidance
          messages << { role: :user, content: format_user_interruption(pending) }
          channel.display_status("  Steering: incorporating user guidance.")
        end

        if round == 0
          channel.display_status("Thinking...")
        end

        begin
          result = provider.chat_with_tools(messages, tools: tools, system_prompt: system_prompt)
        rescue Providers::ProviderError => e
          raise
        end
        @input_tokens += result.input_tokens || 0
        @output_tokens += result.output_tokens || 0

        break if channel.cancelled?
        break unless result.tool_use?

        # Display the LLM's reasoning text before executing its tool calls
        if result.text && !result.text.strip.empty?
          result.text.strip.split("\n").each do |line|
            channel.display_thinking("  #{line}")
          end
        end

        assistant_msg = provider.format_assistant_message(result)
        messages << assistant_msg

        result.tool_calls.each do |tc|
          break if channel.cancelled?

          args_display = tc[:arguments].map { |k, v|
            val = v.to_s
            val = val[0, 60] + '...' if val.length > 60
            "#{k}: #{val.inspect}"
          }.join(', ')
          channel.display_tool_call("#{tc[:name]}(#{args_display})")

          tool_result = tools.execute(tc[:name], tc[:arguments])

          preview = tool_result.to_s.lines.first(3).join.strip
          preview = preview[0, 120] + '...' if preview.length > 120
          channel.display_status("  #{preview}")

          # Truncate large outputs to keep sub-agent context lean
          tool_result_str = tool_result.to_s
          if tool_result_str.length > LARGE_OUTPUT_THRESHOLD
            tool_result_str = tool_result_str[0, LARGE_OUTPUT_PREVIEW_CHARS] +
              "\n\n[Output truncated at #{LARGE_OUTPUT_PREVIEW_CHARS} of #{tool_result_str.length} chars]"
          end

          tool_msg = provider.format_tool_result(tc[:id], tool_result_str)
          messages << tool_msg
        end

        # Loop detection
        result.tool_calls.each do |tc|
          key = "#{tc[:name]}:#{tc[:arguments].to_json}"
          tool_call_counts[key] += 1

          if tool_call_counts[key] >= LOOP_BREAK_THRESHOLD
            channel.display_status("Loop detected — stopping.")
            exhausted = true
          elsif tool_call_counts[key] >= LOOP_WARN_THRESHOLD
            messages << { role: :user, content: "You are repeating the same tool call with the same arguments. Try a different approach or provide your answer now." }
          end
        end
        break if exhausted

        break if executor.last_cancelled?

        exhausted = true if round == max_rounds - 1
      end

      if exhausted
        messages << { role: :user, content: "Provide your best answer now based on what you've learned." }
        result = provider.chat(messages, system_prompt: system_prompt)
        @input_tokens += result.input_tokens || 0
        @output_tokens += result.output_tokens || 0
      end

      result&.text || '(sub-agent returned no result)'
    end

    def format_user_interruption(messages)
      joined = messages.map { |t| t.to_s.strip }.reject(&:empty?).join("\n\n")
      <<~MSG.strip
        [INTERRUPTION FROM USER — REAL-TIME MESSAGE]

        The user sent the following message while you were working. They sent it
        before seeing your latest tool result, so it is NOT a reply to that result.
        It is your most recent direction from the user and supersedes the prior task.

        If they are telling you to stop, halt immediately and finish with a brief
        acknowledgement — do not switch to a different method to accomplish the
        original task on your own. If unclear, return what you have so far and let
        the parent agent ask the user.

        User message:
        "#{joined}"
      MSG
    end

    def build_provider
      config = RailsConsoleAi.configuration
      model_override = @agent_config['model'] || config.sub_agent_model

      if model_override
        config_dup = config.dup
        config_dup.model = model_override
        @model_used = model_override
        Providers.build(config_dup)
      else
        @model_used = config.resolved_model
        Providers.build(config)
      end
    end

    def build_system_prompt
      parts = []
      parts << base_instructions unless @agent_config['skip_base_instructions']
      parts << guide_context
      parts << pinned_memory_context
      parts << @agent_config['body'] if @agent_config['body'] && !@agent_config['body'].strip.empty?
      parts.compact.join("\n\n")
    end

    def base_instructions
      <<~PROMPT.strip
        You are a sub-agent assistant for a Ruby on Rails application. You have been delegated
        a specific investigation task. Your job is to use the available tools to find the answer
        efficiently, then provide a concise summary of your findings.

        RULES:
        - Focus on the specific task you were given. Do not go on tangents.
        - Use tools to look up schema/model details rather than guessing.
        - Prefer ActiveRecord query interface over raw SQL.
        - Use describe_model to understand models before querying them.
        - NEVER fabricate URLs, IDs, or data. Always look things up using model methods.
        - When you find methods on a model (e.g. via .methods.grep), USE them rather than
          constructing values manually.
        - End with a concise, factual summary. Include specific IDs, values, and findings.
        - Keep your final answer under 300 words.
      PROMPT
    end

    def guide_context
      content = RailsConsoleAi.storage.read(RailsConsoleAi::GUIDE_KEY)
      return nil if content.nil? || content.strip.empty?

      "## Application Guide\n\n#{content.strip}"
    rescue => e
      RailsConsoleAi.logger.debug("SubAgent: guide context failed: #{e.message}")
      nil
    end

    def pinned_memory_context
      channel_mode = @parent_channel.respond_to?(:mode) ? @parent_channel.mode : nil
      # For sub-agents spawned from Slack, use the Slack channel's pinned memories.
      # For sub-agents spawned from console, use the console channel's pinned memories.
      # Fall back to 'slack' if the parent is a sub_agent channel (nested, though we block this).
      effective_mode = channel_mode == 'sub_agent' ? 'slack' : channel_mode
      return nil unless effective_mode

      channel_cfg = RailsConsoleAi.configuration.channels[effective_mode] || {}
      pinned_tags = channel_cfg['pinned_memory_tags'] || []
      return nil if pinned_tags.empty?

      require 'rails_console_ai/tools/memory_tools'
      sections = pinned_tags.filter_map do |tag|
        content = Tools::MemoryTools.new.recall_memories(tag: tag)
        next if content.nil? || content.include?("No memories")
        content
      end
      return nil if sections.empty?

      "## Key Context (from pinned memories)\n\n" + sections.join("\n\n")
    rescue => e
      RailsConsoleAi.logger.debug("SubAgent: pinned memory context failed: #{e.message}")
      nil
    end
  end
end
