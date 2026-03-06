module ConsoleAgent
  class ConversationEngine
    attr_reader :history, :total_input_tokens, :total_output_tokens,
                :interactive_session_id, :session_name

    RECENT_OUTPUTS_TO_KEEP = 2

    def initialize(binding_context:, channel:, slack_thread_ts: nil)
      @binding_context = binding_context
      @channel = channel
      @slack_thread_ts = slack_thread_ts
      @executor = Executor.new(binding_context, channel: channel)
      @provider = nil
      @context_builder = nil
      @context = nil
      @history = []
      @total_input_tokens = 0
      @total_output_tokens = 0
      @token_usage = Hash.new { |h, k| h[k] = { input: 0, output: 0 } }
      @interactive_session_id = nil
      @session_name = nil
      @interactive_query = nil
      @interactive_start = nil
      @last_interactive_code = nil
      @last_interactive_output = nil
      @last_interactive_result = nil
      @last_interactive_executed = false
      @compact_warned = false
      @prior_duration_ms = 0
    end

    # --- Public API for channels ---

    def one_shot(query)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      console_capture = StringIO.new
      exec_result = with_console_capture(console_capture) do
        conversation = [{ role: :user, content: query }]
        exec_result, code, executed = one_shot_round(conversation)

        if executed && @executor.last_error && !@executor.last_safety_error
          error_msg = "Code execution failed with error: #{@executor.last_error}"
          error_msg = error_msg[0..1000] + '...' if error_msg.length > 1000
          conversation << { role: :assistant, content: @_last_result_text }
          conversation << { role: :user, content: error_msg }

          @channel.display_dim("  Attempting to fix...")
          exec_result, code, executed = one_shot_round(conversation)
        end

        @_last_log_attrs = {
          query: query,
          conversation: conversation,
          mode: 'one_shot',
          code_executed: code,
          code_output: executed ? @executor.last_output : nil,
          code_result: executed && exec_result ? exec_result.inspect : nil,
          executed: executed,
          start_time: start_time
        }

        exec_result
      end

      log_session(@_last_log_attrs.merge(console_output: console_capture.string))
      exec_result
    rescue Providers::ProviderError => e
      @channel.display_error("ConsoleAgent Error: #{e.message}")
      nil
    rescue => e
      @channel.display_error("ConsoleAgent Error: #{e.class}: #{e.message}")
      nil
    end

    def explain(query)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      console_capture = StringIO.new
      with_console_capture(console_capture) do
        result, _ = send_query(query)
        track_usage(result)
        @executor.display_response(result.text)
        display_usage(result)

        @_last_log_attrs = {
          query: query,
          conversation: [{ role: :user, content: query }, { role: :assistant, content: result.text }],
          mode: 'explain',
          executed: false,
          start_time: start_time
        }
      end

      log_session(@_last_log_attrs.merge(console_output: console_capture.string))
      nil
    rescue Providers::ProviderError => e
      @channel.display_error("ConsoleAgent Error: #{e.message}")
      nil
    rescue => e
      @channel.display_error("ConsoleAgent Error: #{e.class}: #{e.message}")
      nil
    end

    def process_message(text)
      # Initialize interactive state if not already set (first message in session)
      init_interactive unless @interactive_start
      @channel.log_input(text) if @channel.respond_to?(:log_input)
      @interactive_query ||= text
      @history << { role: :user, content: text }

      status = send_and_execute
      if status == :error
        @channel.display_dim("  Attempting to fix...")
        send_and_execute
      end
    end

    def init_guide
      storage = ConsoleAgent.storage
      existing_guide = begin
        content = storage.read(ConsoleAgent::GUIDE_KEY)
        (content && !content.strip.empty?) ? content.strip : nil
      rescue
        nil
      end

      if existing_guide
        @channel.display("  Existing guide found (#{existing_guide.length} chars). Will update.")
      else
        @channel.display("  No existing guide. Exploring the app...")
      end

      require 'console_agent/tools/registry'
      init_tools = Tools::Registry.new(mode: :init)
      sys_prompt = init_system_prompt(existing_guide)
      messages = [{ role: :user, content: "Explore this Rails application and generate the application guide." }]

      original_timeout = ConsoleAgent.configuration.timeout
      ConsoleAgent.configuration.timeout = [original_timeout, 120].max

      result, _ = send_query_with_tools(messages, system_prompt: sys_prompt, tools_override: init_tools)

      guide_text = result.text.to_s.strip
      guide_text = guide_text.sub(/\A```(?:markdown)?\s*\n?/, '').sub(/\n?```\s*\z/, '')
      guide_text = guide_text.sub(/\A.*?(?=^#\s)/m, '') if guide_text =~ /^#\s/m

      if guide_text.empty?
        @channel.display_warning("  No guide content generated.")
        return nil
      end

      storage.write(ConsoleAgent::GUIDE_KEY, guide_text)
      path = storage.respond_to?(:root_path) ? File.join(storage.root_path, ConsoleAgent::GUIDE_KEY) : ConsoleAgent::GUIDE_KEY
      $stdout.puts "\e[32m  Guide saved to #{path} (#{guide_text.length} chars)\e[0m"
      display_usage(result)
      nil
    rescue Interrupt
      $stdout.puts "\n\e[33m  Interrupted.\e[0m"
      nil
    rescue Providers::ProviderError => e
      @channel.display_error("ConsoleAgent Error: #{e.message}")
      nil
    rescue => e
      @channel.display_error("ConsoleAgent Error: #{e.class}: #{e.message}")
      nil
    ensure
      ConsoleAgent.configuration.timeout = original_timeout if original_timeout
    end

    # --- Interactive session management ---

    def init_interactive
      @interactive_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @executor.on_prompt = -> { log_interactive_turn }
      @history = []
      @total_input_tokens = 0
      @total_output_tokens = 0
      @token_usage = Hash.new { |h, k| h[k] = { input: 0, output: 0 } }
      @interactive_query = nil
      @interactive_session_id = nil
      @session_name = nil
      @last_interactive_code = nil
      @last_interactive_output = nil
      @last_interactive_result = nil
      @last_interactive_executed = false
      @compact_warned = false
      @prior_duration_ms = 0
    end

    def restore_session(session)
      @history = JSON.parse(session.conversation, symbolize_names: true)
      @interactive_session_id = session.id
      @interactive_query = session.query
      @session_name = session.name
      @total_input_tokens = session.input_tokens || 0
      @total_output_tokens = session.output_tokens || 0
      @prior_duration_ms = session.duration_ms || 0

      if session.model && (session.input_tokens.to_i > 0 || session.output_tokens.to_i > 0)
        @token_usage[session.model][:input] = session.input_tokens.to_i
        @token_usage[session.model][:output] = session.output_tokens.to_i
      end
    end

    def set_interactive_query(text)
      @interactive_query ||= text
    end

    def add_user_message(text)
      @history << { role: :user, content: text }
    end

    def pop_last_message
      @history.pop
    end

    def set_session_name(name)
      @session_name = name
      if @interactive_session_id
        require 'console_agent/session_logger'
        SessionLogger.update(@interactive_session_id, name: name)
      end
    end

    def execute_direct(raw_code)
      exec_result = @executor.execute(raw_code)

      output_parts = []
      output_parts << "Output:\n#{@executor.last_output.strip}" if @executor.last_output && !@executor.last_output.strip.empty?
      output_parts << "Return value: #{exec_result.inspect}" if exec_result

      result_str = output_parts.join("\n\n")
      result_str = result_str[0..1000] + '...' if result_str.length > 1000

      context_msg = "User directly executed code: `#{raw_code}`"
      context_msg += "\n#{result_str}" unless output_parts.empty?
      output_id = output_parts.empty? ? nil : @executor.store_output(result_str)
      @history << { role: :user, content: context_msg, output_id: output_id }

      @interactive_query ||= "> #{raw_code}"
      @last_interactive_code = raw_code
      @last_interactive_output = @executor.last_output
      @last_interactive_result = exec_result ? exec_result.inspect : nil
      @last_interactive_executed = true
    end

    def send_and_execute
      begin
        result, tool_messages = send_query(nil, conversation: @history)
      rescue Providers::ProviderError => e
        if e.message.include?("prompt is too long") && @history.length >= 6
          @channel.display_warning("  Context limit reached. Run /compact to reduce context size, then try again.")
        else
          @channel.display_error("ConsoleAgent Error: #{e.class}: #{e.message}")
        end
        return :error
      rescue Interrupt
        $stdout.puts "\n\e[33m  Aborted.\e[0m"
        return :interrupted
      end

      track_usage(result)
      return :cancelled if @channel.cancelled?
      code = @executor.display_response(result.text)
      display_usage(result, show_session: true)

      log_interactive_turn

      @history.concat(tool_messages) if tool_messages && !tool_messages.empty?
      @history << { role: :assistant, content: result.text }

      return :no_code unless code && !code.strip.empty?
      return :cancelled if @channel.cancelled?

      exec_result = if ConsoleAgent.configuration.auto_execute
                      @executor.execute(code)
                    else
                      @executor.confirm_and_execute(code)
                    end

      unless @executor.last_cancelled?
        @last_interactive_code = code
        @last_interactive_output = @executor.last_output
        @last_interactive_result = exec_result ? exec_result.inspect : nil
        @last_interactive_executed = true
      end

      if @executor.last_cancelled?
        @history << { role: :user, content: "User declined to execute the code." }
        :cancelled
      elsif @executor.last_safety_error
        exec_result = @executor.offer_danger_retry(code)
        if exec_result || !@executor.last_error
          @last_interactive_code = code
          @last_interactive_output = @executor.last_output
          @last_interactive_result = exec_result ? exec_result.inspect : nil
          @last_interactive_executed = true

          output_parts = []
          if @executor.last_output && !@executor.last_output.strip.empty?
            output_parts << "Output:\n#{@executor.last_output.strip}"
          end
          output_parts << "Return value: #{exec_result.inspect}" if exec_result
          unless output_parts.empty?
            result_str = output_parts.join("\n\n")
            result_str = result_str[0..1000] + '...' if result_str.length > 1000
            output_id = @executor.store_output(result_str)
            @history << { role: :user, content: "Code was executed (safety override). #{result_str}", output_id: output_id }
          end
          :success
        else
          @history << { role: :user, content: "User declined to execute with safe mode disabled." }
          :cancelled
        end
      elsif @executor.last_error
        error_msg = "Code execution failed with error: #{@executor.last_error}"
        error_msg = error_msg[0..1000] + '...' if error_msg.length > 1000
        @history << { role: :user, content: error_msg }
        :error
      else
        output_parts = []
        if @executor.last_output && !@executor.last_output.strip.empty?
          output_parts << "Output:\n#{@executor.last_output.strip}"
        end
        output_parts << "Return value: #{exec_result.inspect}" if exec_result

        unless output_parts.empty?
          result_str = output_parts.join("\n\n")
          result_str = result_str[0..1000] + '...' if result_str.length > 1000
          output_id = @executor.store_output(result_str)
          @history << { role: :user, content: "Code was executed. #{result_str}", output_id: output_id }
        end

        :success
      end
    end

    # --- Display helpers (used by Channel::Console slash commands) ---

    def display_session_summary
      return if @total_input_tokens == 0 && @total_output_tokens == 0
      $stdout.puts "\e[2m[session totals — in: #{@total_input_tokens} | out: #{@total_output_tokens} | total: #{@total_input_tokens + @total_output_tokens}]\e[0m"
    end

    def display_cost_summary
      if @token_usage.empty?
        $stdout.puts "\e[2m  No usage yet.\e[0m"
        return
      end

      total_cost = 0.0
      $stdout.puts "\e[36m  Cost estimate:\e[0m"

      @token_usage.each do |model, usage|
        pricing = Configuration::PRICING[model]
        input_str = "in: #{format_tokens(usage[:input])}"
        output_str = "out: #{format_tokens(usage[:output])}"

        if pricing
          cost = (usage[:input] * pricing[:input]) + (usage[:output] * pricing[:output])
          total_cost += cost
          $stdout.puts "\e[2m    #{model}:  #{input_str}  #{output_str}  ~$#{'%.2f' % cost}\e[0m"
        else
          $stdout.puts "\e[2m    #{model}:  #{input_str}  #{output_str}  (pricing unknown)\e[0m"
        end
      end

      $stdout.puts "\e[36m    Total: ~$#{'%.2f' % total_cost}\e[0m"
    end

    def display_conversation
      stdout = @channel.respond_to?(:real_stdout) ? @channel.real_stdout : $stdout
      if @history.empty?
        stdout.puts "\e[2m  (no conversation history yet)\e[0m"
        return
      end

      trimmed = trim_old_outputs(@history)
      stdout.puts "\e[36m  Conversation (#{trimmed.length} messages, as sent to LLM):\e[0m"
      trimmed.each_with_index do |msg, i|
        role = msg[:role].to_s
        content = msg[:content].to_s
        label = role == 'user' ? "\e[33m[user]\e[0m" : "\e[36m[assistant]\e[0m"
        stdout.puts "#{label} #{content}"
        stdout.puts if i < trimmed.length - 1
      end
    end

    def context
      base = @context_base ||= context_builder.build
      parts = [base]
      parts << safety_context
      parts << binding_variable_summary
      parts.compact.join("\n\n")
    end

    def upgrade_to_thinking_model
      config = ConsoleAgent.configuration
      current = config.resolved_model
      thinking = config.resolved_thinking_model

      if current == thinking
        $stdout.puts "\e[36m  Already using thinking model (#{current}).\e[0m"
      else
        config.model = thinking
        @provider = nil
        $stdout.puts "\e[36m  Switched to thinking model: #{thinking}\e[0m"
      end
    end

    def compact_history
      if @history.length < 6
        $stdout.puts "\e[33m  History too short to compact (#{@history.length} messages). Need at least 6.\e[0m"
        return
      end

      before_chars = @history.sum { |m| m[:content].to_s.length }
      before_count = @history.length

      executed_code = extract_executed_code(@history)

      $stdout.puts "\e[2m  Compacting #{before_count} messages (~#{format_tokens(before_chars)} chars)...\e[0m"

      system_prompt = <<~PROMPT
        You are a conversation summarizer. The user will provide a conversation history from a Rails console AI assistant session.

        Produce a concise summary that captures:
        - What the user has been working on and their goals
        - Key findings and data discovered (include specific values, IDs, record counts)
        - Current state: what worked, what failed, where things stand
        - Important variable names, model names, or table names referenced

        Do NOT include code that was executed — that will be preserved separately.
        Be concise but preserve all information that would be needed to continue the conversation naturally.
        Do NOT include any preamble — just output the summary directly.
      PROMPT

      history_text = @history.map { |m| "#{m[:role]}: #{m[:content]}" }.join("\n\n")
      messages = [{ role: :user, content: "Summarize this conversation history:\n\n#{history_text}" }]

      begin
        result = provider.chat(messages, system_prompt: system_prompt)
        track_usage(result)

        summary = result.text.to_s.strip
        if summary.empty?
          $stdout.puts "\e[33m  Compaction failed: empty summary returned.\e[0m"
          return
        end

        content = "CONVERSATION SUMMARY (compacted):\n#{summary}"
        unless executed_code.empty?
          content += "\n\nCODE EXECUTED THIS SESSION (preserved for continuation):\n#{executed_code}"
        end

        @history = [{ role: :user, content: content }]
        @compact_warned = false

        after_chars = @history.first[:content].length
        $stdout.puts "\e[36m  Compacted: #{before_count} messages -> 1 summary (~#{format_tokens(before_chars)} -> ~#{format_tokens(after_chars)} chars)\e[0m"
        summary.each_line { |line| $stdout.puts "\e[2m  #{line.rstrip}\e[0m" }
        if !executed_code.empty?
          $stdout.puts "\e[2m  (preserved #{executed_code.scan(/```ruby/).length} executed code block(s))\e[0m"
        end
        display_usage(result)
      rescue => e
        $stdout.puts "\e[31m  Compaction failed: #{e.message}\e[0m"
      end
    end

    def warn_if_history_large
      chars = @history.sum { |m| m[:content].to_s.length }

      if chars > 50_000 && !@compact_warned
        @compact_warned = true
        $stdout.puts "\e[33m  Conversation is getting large (~#{format_tokens(chars)} chars). Consider running /compact to reduce context size.\e[0m"
      end
    end

    # --- Session logging ---

    def log_interactive_turn
      require 'console_agent/session_logger'
      session_attrs = {
        conversation:  @history,
        input_tokens:  @total_input_tokens,
        output_tokens: @total_output_tokens,
        code_executed: @last_interactive_code,
        code_output:   @last_interactive_output,
        code_result:   @last_interactive_result,
        executed:      @last_interactive_executed,
        console_output: @channel.respond_to?(:console_capture_string) ? @channel.console_capture_string : nil
      }

      if @interactive_session_id
        SessionLogger.update(@interactive_session_id, session_attrs)
      else
        log_attrs = session_attrs.merge(
          query: @interactive_query || '(interactive session)',
          mode:  @slack_thread_ts ? 'slack' : 'interactive',
          name:  @session_name
        )
        log_attrs[:slack_thread_ts] = @slack_thread_ts if @slack_thread_ts
        if @channel.user_identity
          log_attrs[:user_name] = @channel.mode == 'slack' ? "slack:#{@channel.user_identity}" : @channel.user_identity
        end
        @interactive_session_id = SessionLogger.log(log_attrs)
      end
    end

    def finish_interactive_session
      @executor.on_prompt = nil
      require 'console_agent/session_logger'
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @interactive_start) * 1000).round + @prior_duration_ms
      if @interactive_session_id
        SessionLogger.update(@interactive_session_id,
          conversation:  @history,
          input_tokens:  @total_input_tokens,
          output_tokens: @total_output_tokens,
          code_executed: @last_interactive_code,
          code_output:   @last_interactive_output,
          code_result:   @last_interactive_result,
          executed:      @last_interactive_executed,
          console_output: @channel.respond_to?(:console_capture_string) ? @channel.console_capture_string : nil,
          duration_ms:   duration_ms
        )
      elsif @interactive_query
        log_attrs = {
          query: @interactive_query,
          conversation: @history,
          mode: @slack_thread_ts ? 'slack' : 'interactive',
          code_executed: @last_interactive_code,
          code_output: @last_interactive_output,
          code_result: @last_interactive_result,
          executed: @last_interactive_executed,
          console_output: @channel.respond_to?(:console_capture_string) ? @channel.console_capture_string : nil,
          start_time: @interactive_start
        }
        log_attrs[:slack_thread_ts] = @slack_thread_ts if @slack_thread_ts
        if @channel.user_identity
          log_attrs[:user_name] = @channel.mode == 'slack' ? "slack:#{@channel.user_identity}" : @channel.user_identity
        end
        log_session(log_attrs)
      end
    end

    private

    def safety_context
      guards = ConsoleAgent.configuration.safety_guards
      return nil if guards.empty?

      if !@channel.supports_danger?
        <<~PROMPT.strip
          ## Safety Guards (ENFORCED — CANNOT BE DISABLED)

          This session has safety guards that block side effects. These guards CANNOT be bypassed,
          disabled, or worked around in this channel. Do NOT attempt to:
          - Search for ways to disable safety guards
          - Look for SafetyError, allow_writes, or similar bypass mechanisms
          - Suggest the user disable protections
          - Re-attempt blocked operations with different syntax

          When an operation is blocked, report what happened and move on.
          Only read operations are permitted.
        PROMPT
      elsif guards.enabled?
        <<~PROMPT.strip
          ## Safety Guards

          This session has safety guards that block side effects (database writes, HTTP mutations, etc.).
          If an operation is blocked, the user will be prompted to allow it or disable guards.
        PROMPT
      end
    end

    def one_shot_round(conversation)
      result, _ = send_query(nil, conversation: conversation)
      track_usage(result)
      code = @executor.display_response(result.text)
      display_usage(result)
      @_last_result_text = result.text

      exec_result = nil
      executed = false
      has_code = code && !code.strip.empty?

      if has_code
        exec_result = if ConsoleAgent.configuration.auto_execute
                        @executor.execute(code)
                      else
                        @executor.confirm_and_execute(code)
                      end
        executed = !@executor.last_cancelled?
      end

      [exec_result, has_code ? code : nil, executed]
    end

    def provider
      @provider ||= Providers.build
    end

    def context_builder
      @context_builder ||= ContextBuilder.new
    end

    def binding_variable_summary
      parts = []

      locals = @binding_context.local_variables.reject { |v| v.to_s.start_with?('_') }
      locals.first(20).each do |var|
        val = @binding_context.local_variable_get(var) rescue nil
        parts << "#{var} (#{val.class})"
      end

      ivars = (@binding_context.eval("instance_variables") rescue [])
      ivars.reject { |v| v.to_s =~ /\A@_/ }.first(20).each do |var|
        val = @binding_context.eval(var.to_s) rescue nil
        parts << "#{var} (#{val.class})"
      end

      return nil if parts.empty?
      "The user's console session has these variables available: #{parts.join(', ')}. You can reference them directly in code."
    rescue
      nil
    end

    def init_system_prompt(existing_guide)
      env = context_builder.environment_context

      prompt = <<~PROMPT
        You are a Rails application analyst. Your job is to explore this Rails app using the
        available tools and produce a concise markdown guide that will be injected into future
        AI assistant sessions.

        #{env}

        EXPLORATION STRATEGY — be efficient to avoid timeouts:
        1. Start with list_models to see all models and their associations
        2. Pick the 5-8 CORE models and call describe_model on those only
        3. Call describe_table on only 3-5 key tables (skip tables whose models already told you enough)
        4. Use search_code sparingly — only for specific patterns you suspect (sharding, STI, concerns)
        5. Use read_file only when you need to understand a specific pattern (read small sections, not whole files)
        6. Do NOT exhaustively describe every table or model — focus on what's important

        IMPORTANT: Keep your total tool calls under 20. Prioritize breadth over depth.

        Produce a markdown document with these sections:
        - **Application Overview**: What the app does, key domain concepts
        - **Key Models & Relationships**: Core models and how they relate
        - **Data Architecture**: Important tables, notable columns, any partitioning/sharding
        - **Important Patterns**: Custom concerns, service objects, key abstractions
        - **Common Maintenance Tasks**: Typical console operations for this app
        - **Gotchas**: Non-obvious behaviors, tricky associations, known quirks

        Keep it concise — aim for 1-2 pages. Focus on what a console user needs to know.
        Do NOT wrap the output in markdown code fences.
      PROMPT

      if existing_guide
        prompt += <<~UPDATE

          Here is the existing guide. Update and merge with any new findings:

          #{existing_guide}
        UPDATE
      end

      prompt.strip
    end

    def send_query(query, conversation: nil)
      ConsoleAgent.configuration.validate!

      messages = if conversation
                   conversation.dup
                 else
                   [{ role: :user, content: query }]
                 end

      messages = trim_old_outputs(messages) if conversation

      send_query_with_tools(messages)
    end

    def send_query_with_tools(messages, system_prompt: nil, tools_override: nil)
      require 'console_agent/tools/registry'
      tools = tools_override || Tools::Registry.new(executor: @executor, channel: @channel)
      active_system_prompt = system_prompt || context
      max_rounds = ConsoleAgent.configuration.max_tool_rounds
      total_input = 0
      total_output = 0
      result = nil
      new_messages = []
      last_thinking = nil
      last_tool_names = []

      exhausted = false

      max_rounds.times do |round|
        if @channel.cancelled?
          @channel.display_dim("  Cancelled.")
          break
        end

        if round == 0
          @channel.display_dim("  Thinking...")
        else
          if last_thinking
            last_thinking.split("\n").each do |line|
              @channel.display_dim("  #{line}")
            end
          end
          @channel.display_dim("  #{llm_status(round, messages, total_input, last_thinking, last_tool_names)}")
        end

        if ConsoleAgent.configuration.debug
          debug_pre_call(round, messages, active_system_prompt, tools, total_input, total_output)
        end

        begin
          result = @channel.wrap_llm_call do
            provider.chat_with_tools(messages, tools: tools, system_prompt: active_system_prompt)
          end
        rescue Providers::ProviderError => e
          raise
        end
        total_input += result.input_tokens || 0
        total_output += result.output_tokens || 0

        break if @channel.cancelled?

        if ConsoleAgent.configuration.debug
          debug_post_call(round, result, @total_input_tokens + total_input, @total_output_tokens + total_output)
        end

        break unless result.tool_use?

        last_thinking = (result.text && !result.text.strip.empty?) ? result.text.strip : nil

        assistant_msg = provider.format_assistant_message(result)
        messages << assistant_msg
        new_messages << assistant_msg

        last_tool_names = result.tool_calls.map { |tc| tc[:name] }
        result.tool_calls.each do |tc|
          break if @channel.cancelled?
          if tc[:name] == 'ask_user' || tc[:name] == 'execute_plan'
            tool_result = tools.execute(tc[:name], tc[:arguments])
          else
            args_display = format_tool_args(tc[:name], tc[:arguments])
            $stdout.puts "\e[33m  -> #{tc[:name]}#{args_display}\e[0m"

            tool_result = tools.execute(tc[:name], tc[:arguments])

            preview = compact_tool_result(tc[:name], tool_result)
            cached_tag = tools.last_cached? ? " (cached)" : ""
            @channel.display_dim("     #{preview}#{cached_tag}")
          end

          if ConsoleAgent.configuration.debug
            $stderr.puts "\e[35m[debug] tool result (#{tool_result.to_s.length} chars)\e[0m"
          end

          tool_msg = provider.format_tool_result(tc[:id], tool_result)
          if tool_result.to_s.length > 200
            tool_msg[:output_id] = @executor.store_output(tool_result.to_s)
          end
          messages << tool_msg
          new_messages << tool_msg
        end

        exhausted = true if round == max_rounds - 1
      end

      if exhausted
        $stdout.puts "\e[33m  Hit tool round limit (#{max_rounds}). Forcing final answer. Increase with: ConsoleAgent.configure { |c| c.max_tool_rounds = 200 }\e[0m"
        messages << { role: :user, content: "You've used all available tool rounds. Please provide your best answer now based on what you've learned so far." }
        result = provider.chat(messages, system_prompt: active_system_prompt)
        total_input += result.input_tokens || 0
        total_output += result.output_tokens || 0
      end

      final_result = Providers::ChatResult.new(
        text: result ? result.text : '',
        input_tokens: total_input,
        output_tokens: total_output,
        stop_reason: result ? result.stop_reason : :end_turn
      )
      [final_result, new_messages]
    end

    def track_usage(result)
      @total_input_tokens += result.input_tokens || 0
      @total_output_tokens += result.output_tokens || 0

      model = ConsoleAgent.configuration.resolved_model
      @token_usage[model][:input] += result.input_tokens || 0
      @token_usage[model][:output] += result.output_tokens || 0
    end

    def display_usage(result, show_session: false)
      input  = result.input_tokens
      output = result.output_tokens
      return unless input || output

      parts = []
      parts << "in: #{input}" if input
      parts << "out: #{output}" if output
      parts << "total: #{result.total_tokens}"

      line = "\e[2m[tokens #{parts.join(' | ')}]\e[0m"

      if show_session && (@total_input_tokens + @total_output_tokens) > result.total_tokens
        line += "\e[2m [session: in: #{@total_input_tokens} | out: #{@total_output_tokens} | total: #{@total_input_tokens + @total_output_tokens}]\e[0m"
      end

      $stdout.puts line
    end

    def with_console_capture(capture_io)
      old_stdout = $stdout
      $stdout = TeeIO.new(old_stdout, capture_io)
      yield
    ensure
      $stdout = old_stdout
    end

    def log_session(attrs)
      require 'console_agent/session_logger'
      start_time = attrs.delete(:start_time)
      duration_ms = if start_time
                      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round
                    end
      SessionLogger.log(
        attrs.merge(
          input_tokens: @total_input_tokens,
          output_tokens: @total_output_tokens,
          duration_ms: duration_ms
        )
      )
    end

    # --- Formatting helpers ---

    def format_tokens(count)
      if count >= 1_000_000
        "#{(count / 1_000_000.0).round(1)}M"
      elsif count >= 1_000
        "#{(count / 1_000.0).round(1)}K"
      else
        count.to_s
      end
    end

    def format_tool_args(name, args)
      return '' if args.nil? || args.empty?

      case name
      when 'describe_table'  then "(\"#{args['table_name']}\")"
      when 'describe_model'  then "(\"#{args['model_name']}\")"
      when 'read_file'       then "(\"#{args['path']}\")"
      when 'search_code'
        dir = args['directory'] ? ", dir: \"#{args['directory']}\"" : ''
        "(\"#{args['query']}\"#{dir})"
      when 'list_files'      then args['directory'] ? "(\"#{args['directory']}\")" : ''
      when 'save_memory'     then "(\"#{args['name']}\")"
      when 'delete_memory'   then "(\"#{args['name']}\")"
      when 'recall_memories' then args['query'] ? "(\"#{args['query']}\")" : ''
      when 'execute_plan'
        steps = args['steps']
        steps ? "(#{steps.length} steps)" : ''
      else ''
      end
    end

    def compact_tool_result(name, result)
      return '(empty)' if result.nil? || result.strip.empty?

      case name
      when 'list_tables'
        tables = result.split(', ')
        tables.length > 8 ? "#{tables.length} tables: #{tables.first(8).join(', ')}..." : "#{tables.length} tables: #{result}"
      when 'list_models'
        lines = result.split("\n")
        lines.length > 6 ? "#{lines.length} models: #{lines.first(6).map { |l| l.split(' ').first }.join(', ')}..." : "#{lines.length} models"
      when 'describe_table'
        "#{result.scan(/^\s{2}\S/).length} columns"
      when 'describe_model'
        parts = []
        assoc_count = result.scan(/^\s{2}(has_many|has_one|belongs_to|has_and_belongs_to_many)/).length
        val_count = result.scan(/^\s{2}(presence|uniqueness|format|length|numericality|inclusion|exclusion|confirmation|acceptance)/).length
        parts << "#{assoc_count} associations" if assoc_count > 0
        parts << "#{val_count} validations" if val_count > 0
        parts.empty? ? truncate(result, 80) : parts.join(', ')
      when 'list_files'    then "#{result.split("\n").length} files"
      when 'read_file'
        if result =~ /^Lines (\d+)-(\d+) of (\d+):/
          "lines #{$1}-#{$2} of #{$3}"
        else
          "#{result.split("\n").length} lines"
        end
      when 'search_code'
        if result.start_with?('Found') then result.split("\n").first
        elsif result.start_with?('No matches') then result
        else truncate(result, 80)
        end
      when 'save_memory'
        (result.start_with?('Memory saved') || result.start_with?('Memory updated')) ? result : truncate(result, 80)
      when 'delete_memory'
        result.start_with?('Memory deleted') ? result : truncate(result, 80)
      when 'recall_memories'
        chunks = result.split("\n\n")
        chunks.length > 1 ? "#{chunks.length} memories found" : truncate(result, 80)
      when 'execute_plan'
        steps_done = result.scan(/^Step \d+/).length
        steps_done > 0 ? "#{steps_done} steps executed" : truncate(result, 80)
      else
        truncate(result, 80)
      end
    end

    def truncate(str, max)
      str.length > max ? str[0..max] + '...' : str
    end

    def llm_status(round, messages, tokens_so_far, last_thinking = nil, last_tool_names = [])
      status = "Calling LLM (round #{round + 1}, #{messages.length} msgs"
      status += ", ~#{format_tokens(tokens_so_far)} ctx" if tokens_so_far > 0
      status += ")"
      if !last_thinking && last_tool_names.any?
        counts = last_tool_names.tally
        summary = counts.map { |name, n| n > 1 ? "#{name} x#{n}" : name }.join(", ")
        status += " after #{summary}"
      end
      status += "..."
      status
    end

    def debug_pre_call(round, messages, system_prompt, tools, total_input, total_output)
      d = "\e[35m"
      r = "\e[0m"

      user_msgs = 0; assistant_msgs = 0; tool_result_msgs = 0; tool_use_msgs = 0
      output_msgs = 0; omitted_msgs = 0
      total_content_chars = system_prompt.to_s.length

      messages.each do |msg|
        content_str = msg[:content].is_a?(Array) ? msg[:content].to_s : msg[:content].to_s
        total_content_chars += content_str.length

        role = msg[:role].to_s
        if role == 'tool'
          tool_result_msgs += 1
        elsif msg[:content].is_a?(Array)
          msg[:content].each do |block|
            next unless block.is_a?(Hash)
            if block['type'] == 'tool_result'
              tool_result_msgs += 1
              omitted_msgs += 1 if block['content'].to_s.include?('Output omitted')
            elsif block['type'] == 'tool_use'
              tool_use_msgs += 1
            end
          end
        elsif role == 'user'
          user_msgs += 1
          if content_str.include?('Code was executed') || content_str.include?('directly executed code')
            output_msgs += 1
            omitted_msgs += 1 if content_str.include?('Output omitted')
          end
        elsif role == 'assistant'
          assistant_msgs += 1
        end
      end

      tool_count = tools.respond_to?(:definitions) ? tools.definitions.length : 0

      $stderr.puts "#{d}[debug] ── LLM call ##{round + 1} ──#{r}"
      $stderr.puts "#{d}[debug]   system prompt: #{format_tokens(system_prompt.to_s.length)} chars#{r}"
      $stderr.puts "#{d}[debug]   messages: #{messages.length} (#{user_msgs} user, #{assistant_msgs} assistant, #{tool_result_msgs} tool results, #{tool_use_msgs} tool calls)#{r}"
      $stderr.puts "#{d}[debug]   execution outputs: #{output_msgs} (#{omitted_msgs} omitted)#{r}" if output_msgs > 0 || omitted_msgs > 0
      $stderr.puts "#{d}[debug]   tools provided: #{tool_count}#{r}"
      $stderr.puts "#{d}[debug]   est. content size: #{format_tokens(total_content_chars)} chars#{r}"
      if total_input > 0 || total_output > 0
        $stderr.puts "#{d}[debug]   tokens so far: in: #{format_tokens(total_input)} | out: #{format_tokens(total_output)}#{r}"
      end
    end

    def debug_post_call(round, result, total_input, total_output)
      d = "\e[35m"
      r = "\e[0m"

      input_t = result.input_tokens || 0
      output_t = result.output_tokens || 0
      model = ConsoleAgent.configuration.resolved_model
      pricing = Configuration::PRICING[model]

      parts = ["in: #{format_tokens(input_t)}", "out: #{format_tokens(output_t)}"]

      if pricing
        cost = (input_t * pricing[:input]) + (output_t * pricing[:output])
        session_cost = (total_input * pricing[:input]) + (total_output * pricing[:output])
        parts << "~$#{'%.4f' % cost}"
        $stderr.puts "#{d}[debug]   ← response: #{parts.join(' | ')}  (session: ~$#{'%.4f' % session_cost})#{r}"
      else
        $stderr.puts "#{d}[debug]   ← response: #{parts.join(' | ')}#{r}"
      end

      if result.tool_use?
        tool_names = result.tool_calls.map { |tc| tc[:name] }
        $stderr.puts "#{d}[debug]   tool calls: #{tool_names.join(', ')}#{r}"
      else
        $stderr.puts "#{d}[debug]   stop reason: #{result.stop_reason}#{r}"
      end
    end

    # --- Conversation context management ---

    def trim_old_outputs(messages)
      output_indices = messages.each_with_index
                               .select { |m, _| m[:output_id] }
                               .map { |_, i| i }

      if output_indices.length <= RECENT_OUTPUTS_TO_KEEP
        return messages.map { |m| m.except(:output_id) }
      end

      trim_indices = output_indices[0..-(RECENT_OUTPUTS_TO_KEEP + 1)]
      messages.each_with_index.map do |msg, i|
        if trim_indices.include?(i)
          trim_message(msg)
        else
          msg.except(:output_id)
        end
      end
    end

    def trim_message(msg)
      ref = "[Output omitted — use recall_output tool with id #{msg[:output_id]} to retrieve]"

      if msg[:content].is_a?(Array)
        trimmed_content = msg[:content].map do |block|
          if block.is_a?(Hash) && block['type'] == 'tool_result'
            block.merge('content' => ref)
          else
            block
          end
        end
        { role: msg[:role], content: trimmed_content }
      elsif msg[:role].to_s == 'tool'
        msg.except(:output_id).merge(content: ref)
      else
        first_line = msg[:content].to_s.lines.first&.strip || msg[:content]
        { role: msg[:role], content: "#{first_line}\n#{ref}" }
      end
    end

    def extract_executed_code(history)
      code_blocks = []
      history.each_cons(2) do |msg, next_msg|
        if msg[:role].to_s == 'assistant' && next_msg[:role].to_s == 'user'
          content = msg[:content].to_s
          next_content = next_msg[:content].to_s

          if next_content.start_with?('Code was executed.')
            content.scan(/```ruby\s*\n(.*?)```/m).each do |match|
              code = match[0].strip
              next if code.empty?
              result_summary = next_content[0..200].gsub("\n", "\n# ")
              code_blocks << "```ruby\n#{code}\n```\n# #{result_summary}"
            end
          end
        end

        if msg[:role].to_s == 'assistant' && msg[:content].is_a?(Array)
          msg[:content].each do |block|
            next unless block.is_a?(Hash) && block['type'] == 'tool_use' && block['name'] == 'execute_plan'
            input = block['input'] || {}
            steps = input['steps'] || []

            tool_id = block['id']
            result_msg = find_tool_result(history, tool_id)
            next unless result_msg

            result_text = result_msg.to_s
            steps.each_with_index do |step, i|
              step_num = i + 1
              step_section = result_text[/Step #{step_num}\b.*?(?=Step #{step_num + 1}\b|\z)/m] || ''
              next if step_section.include?('ERROR:')
              next if step_section.include?('User declined')

              code = step['code'].to_s.strip
              next if code.empty?
              desc = step['description'] || "Step #{step_num}"
              code_blocks << "```ruby\n# #{desc}\n#{code}\n```"
            end
          end
        end
      end
      code_blocks.join("\n\n")
    end

    def find_tool_result(history, tool_id)
      history.each do |msg|
        next unless msg[:content].is_a?(Array)
        msg[:content].each do |block|
          next unless block.is_a?(Hash)
          if block['type'] == 'tool_result' && block['tool_use_id'] == tool_id
            return block['content']
          end
          if msg[:role].to_s == 'tool' && msg[:tool_call_id] == tool_id
            return msg[:content]
          end
        end
      end
      nil
    end
  end
end
