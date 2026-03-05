require 'readline'

module ConsoleAgent
  class Repl
    def initialize(binding_context)
      @binding_context = binding_context
      @executor = Executor.new(binding_context)
      @provider = nil
      @context_builder = nil
      @context = nil
      @history = []
      @total_input_tokens = 0
      @total_output_tokens = 0
      @token_usage = Hash.new { |h, k| h[k] = { input: 0, output: 0 } }
      @input_history = []
    end

    def one_shot(query)
      start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      console_capture = StringIO.new
      exec_result = with_console_capture(console_capture) do
        conversation = [{ role: :user, content: query }]
        exec_result, code, executed = one_shot_round(conversation)

        # Auto-retry once if execution errored
        if executed && @executor.last_error
          error_msg = "Code execution failed with error: #{@executor.last_error}"
          error_msg = error_msg[0..1000] + '...' if error_msg.length > 1000
          conversation << { role: :assistant, content: @_last_result_text }
          conversation << { role: :user, content: error_msg }

          $stdout.puts "\e[2m  Attempting to fix...\e[0m"
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
      $stderr.puts "\e[31mConsoleAgent Error: #{e.message}\e[0m"
      nil
    rescue => e
      $stderr.puts "\e[31mConsoleAgent Error: #{e.class}: #{e.message}\e[0m"
      nil
    end

    # Executes one LLM round: send query, display, optionally execute code.
    # Returns [exec_result, code, executed].
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
      $stderr.puts "\e[31mConsoleAgent Error: #{e.message}\e[0m"
      nil
    rescue => e
      $stderr.puts "\e[31mConsoleAgent Error: #{e.class}: #{e.message}\e[0m"
      nil
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
        $stdout.puts "\e[36m  Existing guide found (#{existing_guide.length} chars). Will update.\e[0m"
      else
        $stdout.puts "\e[36m  No existing guide. Exploring the app...\e[0m"
      end

      require 'console_agent/tools/registry'
      init_tools = Tools::Registry.new(mode: :init)
      sys_prompt = init_system_prompt(existing_guide)
      messages = [{ role: :user, content: "Explore this Rails application and generate the application guide." }]

      # Temporarily increase timeout — init conversations are large
      original_timeout = ConsoleAgent.configuration.timeout
      ConsoleAgent.configuration.timeout = [original_timeout, 120].max

      result, _ = send_query_with_tools(messages, system_prompt: sys_prompt, tools_override: init_tools)

      guide_text = result.text.to_s.strip
      # Strip markdown code fences if the LLM wrapped the response
      guide_text = guide_text.sub(/\A```(?:markdown)?\s*\n?/, '').sub(/\n?```\s*\z/, '')
      # Strip LLM preamble/thinking before the actual guide content
      guide_text = guide_text.sub(/\A.*?(?=^#\s)/m, '') if guide_text =~ /^#\s/m

      if guide_text.empty?
        $stdout.puts "\e[33m  No guide content generated.\e[0m"
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
      $stderr.puts "\e[31mConsoleAgent Error: #{e.message}\e[0m"
      nil
    rescue => e
      $stderr.puts "\e[31mConsoleAgent Error: #{e.class}: #{e.message}\e[0m"
      nil
    ensure
      ConsoleAgent.configuration.timeout = original_timeout if original_timeout
    end

    def interactive
      init_interactive_state
      interactive_loop
    end

    def resume(session)
      init_interactive_state

      # Restore state from the previous session
      @history = JSON.parse(session.conversation, symbolize_names: true)
      @interactive_session_id = session.id
      @interactive_query = session.query
      @interactive_session_name = session.name
      @total_input_tokens = session.input_tokens || 0
      @total_output_tokens = session.output_tokens || 0

      # Seed the capture buffer with previous output so it's preserved on save
      @interactive_console_capture.write(session.console_output.to_s)

      # Replay to the user via the real stdout (bypass TeeIO to avoid double-capture)
      if session.console_output && !session.console_output.strip.empty?
        @interactive_old_stdout.puts "\e[2m--- Replaying previous session output ---\e[0m"
        @interactive_old_stdout.puts session.console_output
        @interactive_old_stdout.puts "\e[2m--- End of previous output ---\e[0m"
        @interactive_old_stdout.puts
      end

      interactive_loop
    end

    private

    def init_interactive_state
      @interactive_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @interactive_console_capture = StringIO.new
      @interactive_old_stdout = $stdout
      $stdout = TeeIO.new(@interactive_old_stdout, @interactive_console_capture)
      @executor.on_prompt = -> { log_interactive_turn }

      @history = []
      @total_input_tokens = 0
      @total_output_tokens = 0
      @token_usage = Hash.new { |h, k| h[k] = { input: 0, output: 0 } }
      @interactive_query = nil
      @interactive_session_id = nil
      @interactive_session_name = nil
      @last_interactive_code = nil
      @last_interactive_output = nil
      @last_interactive_result = nil
      @last_interactive_executed = false
      @compact_warned = false
    end

    def interactive_loop
      auto = ConsoleAgent.configuration.auto_execute
      name_display = @interactive_session_name ? " (#{@interactive_session_name})" : ""
      # Write banner to real stdout (bypass TeeIO) so it doesn't accumulate on resume
      @interactive_old_stdout.puts "\e[36mConsoleAgent interactive mode#{name_display}. Type 'exit' or 'quit' to leave.\e[0m"
      @interactive_old_stdout.puts "\e[2m  Auto-execute: #{auto ? 'ON' : 'OFF'} (Shift-Tab or /auto to toggle) | > code | /usage | /cost | /compact | /think | /name <label>\e[0m"

      # Bind Shift-Tab to insert /auto command and submit
      if Readline.respond_to?(:parse_and_bind)
        Readline.parse_and_bind('"\e[Z": "\C-a\C-k/auto\C-m"')
      end

      loop do
        input = Readline.readline("\001\e[33m\002ai> \001\e[0m\002", false)
        break if input.nil? # Ctrl-D

        input = input.strip
        break if input.downcase == 'exit' || input.downcase == 'quit'
        next if input.empty?

        if input == '/auto'
          ConsoleAgent.configuration.auto_execute = !ConsoleAgent.configuration.auto_execute
          mode = ConsoleAgent.configuration.auto_execute ? 'ON' : 'OFF'
          @interactive_old_stdout.puts "\e[36m  Auto-execute: #{mode}\e[0m"
          next
        end

        if input == '/usage'
          display_session_summary
          next
        end

        if input == '/debug'
          ConsoleAgent.configuration.debug = !ConsoleAgent.configuration.debug
          mode = ConsoleAgent.configuration.debug ? 'ON' : 'OFF'
          @interactive_old_stdout.puts "\e[36m  Debug: #{mode}\e[0m"
          next
        end

        if input == '/compact'
          compact_history
          next
        end

        if input == '/cost'
          display_cost_summary
          next
        end

        if input == '/think'
          upgrade_to_thinking_model
          next
        end

        if input.start_with?('/name')
          name = input.sub('/name', '').strip
          if name.empty?
            if @interactive_session_name
              @interactive_old_stdout.puts "\e[36m  Session name: #{@interactive_session_name}\e[0m"
            else
              @interactive_old_stdout.puts "\e[33m  Usage: /name <label>  (e.g. /name salesforce_user_123)\e[0m"
            end
          else
            @interactive_session_name = name
            if @interactive_session_id
              require 'console_agent/session_logger'
              SessionLogger.update(@interactive_session_id, name: name)
            end
            @interactive_old_stdout.puts "\e[36m  Session named: #{name}\e[0m"
          end
          next
        end

        # Direct code execution with ">" prefix — skip LLM entirely
        if input.start_with?('>') && !input.start_with?('>=')
          raw_code = input.sub(/\A>\s?/, '')
          Readline::HISTORY.push(input) unless input == Readline::HISTORY.to_a.last
          @interactive_console_capture.write("ai> #{input}\n")

          exec_result = @executor.execute(raw_code)

          output_parts = []
          output_parts << "Output:\n#{@executor.last_output.strip}" if @executor.last_output && !@executor.last_output.strip.empty?
          output_parts << "Return value: #{exec_result.inspect}" if exec_result

          result_str = output_parts.join("\n\n")
          result_str = result_str[0..1000] + '...' if result_str.length > 1000

          context_msg = "User directly executed code: `#{raw_code}`"
          context_msg += "\n#{result_str}" unless output_parts.empty?
          @history << { role: :user, content: context_msg }

          @interactive_query ||= input
          @last_interactive_code = raw_code
          @last_interactive_output = @executor.last_output
          @last_interactive_result = exec_result ? exec_result.inspect : nil
          @last_interactive_executed = true

          log_interactive_turn
          next
        end

        # Add to Readline history (avoid consecutive duplicates)
        Readline::HISTORY.push(input) unless input == Readline::HISTORY.to_a.last

        # Auto-upgrade to thinking model on "think harder" phrases
        if input =~ /think\s*harder/i
          upgrade_to_thinking_model
        end

        @interactive_query ||= input
        @history << { role: :user, content: input }

        # Log the user's prompt line to the console capture (Readline doesn't go through $stdout)
        @interactive_console_capture.write("ai> #{input}\n")

        # Save immediately so the session is visible in the admin UI while the AI thinks
        log_interactive_turn

        status = send_and_execute
        if status == :interrupted
          @history.pop # Remove the user message that never got a response
          log_interactive_turn
          next
        end

        # Auto-retry once when execution fails — send error back to LLM for a fix
        if status == :error
          $stdout.puts "\e[2m  Attempting to fix...\e[0m"
          log_interactive_turn
          send_and_execute
        end

        # Update with the AI response, tokens, and any execution results
        log_interactive_turn

        warn_if_history_large
      end

      $stdout = @interactive_old_stdout
      @executor.on_prompt = nil
      finish_interactive_session
      display_exit_info
    rescue Interrupt
      # Ctrl-C during Readline input — exit cleanly
      $stdout = @interactive_old_stdout if @interactive_old_stdout
      @executor.on_prompt = nil
      $stdout.puts
      finish_interactive_session
      display_exit_info
    rescue => e
      $stdout = @interactive_old_stdout if @interactive_old_stdout
      @executor.on_prompt = nil
      $stderr.puts "\e[31mConsoleAgent Error: #{e.class}: #{e.message}\e[0m"
    end

    # Sends conversation to LLM, displays response, executes code if present.
    # Returns :success, :error, :cancelled, :no_code, or :interrupted.
    def send_and_execute
      begin
        result, tool_messages = send_query(nil, conversation: @history)
      rescue Providers::ProviderError => e
        if e.message.include?("prompt is too long") && @history.length >= 6
          $stdout.puts "\e[33m  Context limit reached. Auto-compacting history...\e[0m"
          compact_history
          begin
            result, tool_messages = send_query(nil, conversation: @history)
          rescue Providers::ProviderError => e2
            $stderr.puts "\e[31m  Still too large after compaction: #{e2.message}\e[0m"
            return :error
          end
        else
          $stderr.puts "\e[31mConsoleAgent Error: #{e.class}: #{e.message}\e[0m"
          return :error
        end
      rescue Interrupt
        $stdout.puts "\n\e[33m  Aborted.\e[0m"
        return :interrupted
      end

      track_usage(result)
      code = @executor.display_response(result.text)
      display_usage(result, show_session: true)

      # Save after response is displayed so viewer shows progress before Execute prompt
      log_interactive_turn

      # Add tool call/result messages so the LLM remembers what it learned
      @history.concat(tool_messages) if tool_messages && !tool_messages.empty?
      @history << { role: :assistant, content: result.text }

      return :no_code unless code && !code.strip.empty?

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
      elsif @executor.last_error
        error_msg = "Code execution failed with error: #{@executor.last_error}"
        error_msg = error_msg[0..1000] + '...' if error_msg.length > 1000
        @history << { role: :user, content: error_msg }
        :error
      else
        output_parts = []

        # Capture printed output (puts, print, etc.)
        if @executor.last_output && !@executor.last_output.strip.empty?
          output_parts << "Output:\n#{@executor.last_output.strip}"
        end

        # Capture return value
        if exec_result
          output_parts << "Return value: #{exec_result.inspect}"
        end

        unless output_parts.empty?
          result_str = output_parts.join("\n\n")
          result_str = result_str[0..1000] + '...' if result_str.length > 1000
          @history << { role: :user, content: "Code was executed. #{result_str}" }
        end

        :success
      end
    end

    def provider
      @provider ||= Providers.build
    end

    def context_builder
      @context_builder ||= ContextBuilder.new
    end

    def context
      base = @context_base ||= context_builder.build
      vars = binding_variable_summary
      vars ? "#{base}\n\n#{vars}" : base
    end

    # Summarize local and instance variables from the user's console session
    # so the LLM knows what's available to reference in generated code.
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

      send_query_with_tools(messages)
    end

    def send_query_with_tools(messages, system_prompt: nil, tools_override: nil)
      require 'console_agent/tools/registry'
      tools = tools_override || Tools::Registry.new(executor: @executor)
      active_system_prompt = system_prompt || context
      max_rounds = ConsoleAgent.configuration.max_tool_rounds
      total_input = 0
      total_output = 0
      result = nil
      new_messages = []  # Track messages added during tool use
      last_thinking = nil
      last_tool_names = []

      exhausted = false

      max_rounds.times do |round|
        if round == 0
          $stdout.puts "\e[2m  Thinking...\e[0m"
        else
          # Show buffered thinking text before the "Calling LLM" line
          if last_thinking
            last_thinking.split("\n").each do |line|
              $stdout.puts "\e[2m  #{line}\e[0m"
            end
          end
          $stdout.puts "\e[2m  #{llm_status(round, messages, total_input, last_thinking, last_tool_names)}\e[0m"
        end

        begin
          result = with_escape_monitoring do
            provider.chat_with_tools(messages, tools: tools, system_prompt: active_system_prompt)
          end
        rescue Providers::ProviderError => e
          if e.message.include?("prompt is too long") && messages.length >= 6
            $stdout.puts "\e[33m  Context limit hit mid-session. Compacting messages...\e[0m"
            messages = compact_messages(messages)
            unless @_retried_compact
              @_retried_compact = true
              retry
            end
          end
          raise
        ensure
          @_retried_compact = nil
        end
        total_input += result.input_tokens || 0
        total_output += result.output_tokens || 0

        break unless result.tool_use?

        # Buffer thinking text for display before next LLM call
        last_thinking = (result.text && !result.text.strip.empty?) ? result.text.strip : nil

        # Add assistant message with tool calls to conversation
        assistant_msg = provider.format_assistant_message(result)
        messages << assistant_msg
        new_messages << assistant_msg

        # Execute each tool and show progress
        last_tool_names = result.tool_calls.map { |tc| tc[:name] }
        result.tool_calls.each do |tc|
          # ask_user and execute_plan handle their own display
          if tc[:name] == 'ask_user' || tc[:name] == 'execute_plan'
            tool_result = tools.execute(tc[:name], tc[:arguments])
          else
            args_display = format_tool_args(tc[:name], tc[:arguments])
            $stdout.puts "\e[33m  -> #{tc[:name]}#{args_display}\e[0m"

            tool_result = tools.execute(tc[:name], tc[:arguments])

            preview = compact_tool_result(tc[:name], tool_result)
            cached_tag = tools.last_cached? ? " (cached)" : ""
            $stdout.puts "\e[2m     #{preview}#{cached_tag}\e[0m"
          end

          if ConsoleAgent.configuration.debug
            $stderr.puts "\e[35m[debug tool result] #{tool_result}\e[0m"
          end

          tool_msg = provider.format_tool_result(tc[:id], tool_result)
          messages << tool_msg
          new_messages << tool_msg
        end

        exhausted = true if round == max_rounds - 1
      end

      # If we hit the tool round limit, force a final response without tools
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

    # Monitors stdin for Escape (or Ctrl+C, since raw mode disables signals)
    # and raises Interrupt in the main thread when detected.
    def with_escape_monitoring
      require 'io/console'
      return yield unless $stdin.respond_to?(:raw)

      monitor = Thread.new do
        Thread.current.report_on_exception = false
        $stdin.raw do |io|
          loop do
            break if Thread.current[:stop]
            ready = IO.select([io], nil, nil, 0.2)
            next unless ready

            char = io.read_nonblock(1) rescue nil
            next unless char

            if char == "\x03" # Ctrl+C (raw mode eats the signal)
              Thread.main.raise(Interrupt)
              break
            elsif char == "\e"
              # Distinguish standalone Escape from escape sequences (arrow keys, etc.)
              seq = IO.select([io], nil, nil, 0.05)
              if seq
                io.read_nonblock(10) rescue nil # consume the sequence
              else
                Thread.main.raise(Interrupt)
                break
              end
            end
          end
        end
      rescue IOError, Errno::EIO, Errno::ENODEV, Errno::ENOTTY
        # stdin is not a TTY (e.g. in tests or piped input) — silently skip
      end

      begin
        yield
      ensure
        monitor[:stop] = true
        monitor.join(1) rescue nil
      end
    end


    def llm_status(round, messages, tokens_so_far, last_thinking = nil, last_tool_names = [])
      status = "Calling LLM (round #{round + 1}, #{messages.length} msgs"
      status += ", ~#{format_tokens(tokens_so_far)} ctx" if tokens_so_far > 0
      status += ")"
      if !last_thinking && last_tool_names.any?
        # Summarize tools when there's no thinking text
        counts = last_tool_names.tally
        summary = counts.map { |name, n| n > 1 ? "#{name} x#{n}" : name }.join(", ")
        status += " after #{summary}"
      end
      status += "..."
      status
    end

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
      when 'describe_table'
        "(\"#{args['table_name']}\")"
      when 'describe_model'
        "(\"#{args['model_name']}\")"
      when 'read_file'
        "(\"#{args['path']}\")"
      when 'search_code'
        dir = args['directory'] ? ", dir: \"#{args['directory']}\"" : ''
        "(\"#{args['query']}\"#{dir})"
      when 'list_files'
        args['directory'] ? "(\"#{args['directory']}\")" : ''
      when 'save_memory'
        "(\"#{args['name']}\")"
      when 'delete_memory'
        "(\"#{args['name']}\")"
      when 'recall_memories'
        args['query'] ? "(\"#{args['query']}\")" : ''
      when 'execute_plan'
        steps = args['steps']
        steps ? "(#{steps.length} steps)" : ''
      else
        ''
      end
    end

    def compact_tool_result(name, result)
      return '(empty)' if result.nil? || result.strip.empty?

      case name
      when 'list_tables'
        tables = result.split(', ')
        if tables.length > 8
          "#{tables.length} tables: #{tables.first(8).join(', ')}..."
        else
          "#{tables.length} tables: #{result}"
        end
      when 'list_models'
        lines = result.split("\n")
        if lines.length > 6
          "#{lines.length} models: #{lines.first(6).map { |l| l.split(' ').first }.join(', ')}..."
        else
          "#{lines.length} models"
        end
      when 'describe_table'
        col_count = result.scan(/^\s{2}\S/).length
        "#{col_count} columns"
      when 'describe_model'
        parts = []
        assoc_count = result.scan(/^\s{2}(has_many|has_one|belongs_to|has_and_belongs_to_many)/).length
        val_count = result.scan(/^\s{2}(presence|uniqueness|format|length|numericality|inclusion|exclusion|confirmation|acceptance)/).length
        parts << "#{assoc_count} associations" if assoc_count > 0
        parts << "#{val_count} validations" if val_count > 0
        parts.empty? ? truncate(result, 80) : parts.join(', ')
      when 'list_files'
        lines = result.split("\n")
        "#{lines.length} files"
      when 'read_file'
        if result =~ /^Lines (\d+)-(\d+) of (\d+):/
          "lines #{$1}-#{$2} of #{$3}"
        else
          lines = result.split("\n")
          "#{lines.length} lines"
        end
      when 'search_code'
        if result.start_with?('Found')
          result.split("\n").first
        elsif result.start_with?('No matches')
          result
        else
          truncate(result, 80)
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
        console_output: @interactive_console_capture&.string
      }

      if @interactive_session_id
        SessionLogger.update(@interactive_session_id, session_attrs)
      else
        @interactive_session_id = SessionLogger.log(
          session_attrs.merge(
            query: @interactive_query || '(interactive session)',
            mode:  'interactive',
            name:  @interactive_session_name
          )
        )
      end
    end

    def finish_interactive_session
      require 'console_agent/session_logger'
      duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - @interactive_start) * 1000).round
      if @interactive_session_id
        SessionLogger.update(@interactive_session_id,
          conversation:  @history,
          input_tokens:  @total_input_tokens,
          output_tokens: @total_output_tokens,
          code_executed: @last_interactive_code,
          code_output:   @last_interactive_output,
          code_result:   @last_interactive_result,
          executed:      @last_interactive_executed,
          console_output: @interactive_console_capture&.string,
          duration_ms:   duration_ms
        )
      elsif @interactive_query
        # Session was never created (e.g., only one turn that failed to log)
        log_session(
          query: @interactive_query,
          conversation: @history,
          mode: 'interactive',
          code_executed: @last_interactive_code,
          code_output: @last_interactive_output,
          code_result: @last_interactive_result,
          executed: @last_interactive_executed,
          console_output: @interactive_console_capture&.string,
          start_time: @interactive_start
        )
      end
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

    def on_thinking_model?
      config = ConsoleAgent.configuration
      config.resolved_model == config.resolved_thinking_model
    end

    def warn_if_history_large
      chars = @history.sum { |m| m[:content].to_s.length }

      if chars > 120_000 && @history.length >= 6
        $stdout.puts "\e[33m  Context growing large (~#{format_tokens(chars)} chars). Auto-compacting...\e[0m"
        compact_history
      elsif chars > 50_000 && !@compact_warned
        @compact_warned = true
        $stdout.puts "\e[33m  Conversation is getting large (~#{format_tokens(chars)} chars). Consider running /compact to reduce context size.\e[0m"
      end
    end

    def compact_history
      if @history.length < 6
        $stdout.puts "\e[33m  History too short to compact (#{@history.length} messages). Need at least 6.\e[0m"
        return
      end

      before_chars = @history.sum { |m| m[:content].to_s.length }
      before_count = @history.length

      $stdout.puts "\e[2m  Compacting #{before_count} messages (~#{format_tokens(before_chars)} chars)...\e[0m"

      system_prompt = <<~PROMPT
        You are a conversation summarizer. The user will provide a conversation history from a Rails console AI assistant session.

        Produce a concise summary that captures:
        - What the user has been working on and their goals
        - Key findings and data discovered (include specific values, IDs, record counts)
        - Current state: what worked, what failed, where things stand
        - Important variable names, model names, or table names referenced
        - Any code that was executed and its results

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

        @history = [{ role: :user, content: "CONVERSATION SUMMARY (compacted):\n#{summary}" }]
        @compact_warned = false

        after_chars = @history.first[:content].length
        $stdout.puts "\e[36m  Compacted: #{before_count} messages -> 1 summary (~#{format_tokens(before_chars)} -> ~#{format_tokens(after_chars)} chars)\e[0m"
        summary.each_line { |line| $stdout.puts "\e[2m  #{line.rstrip}\e[0m" }
        display_usage(result)
      rescue => e
        $stdout.puts "\e[31m  Compaction failed: #{e.message}\e[0m"
      end
    end

    def compact_messages(messages)
      return messages if messages.length < 6

      to_summarize = messages[0...-4]
      to_keep = messages[-4..]

      history_text = to_summarize.map { |m| "#{m[:role]}: #{m[:content].to_s[0..500]}" }.join("\n\n")

      summary_result = provider.chat(
        [{ role: :user, content: "Summarize this conversation context concisely, preserving key facts, IDs, and findings:\n\n#{history_text}" }],
        system_prompt: "You are a conversation summarizer. Be concise but preserve all actionable information."
      )

      [{ role: :user, content: "CONTEXT SUMMARY:\n#{summary_result.text}" }] + to_keep
    end

    def display_exit_info
      display_session_summary
      if @interactive_session_id
        $stdout.puts "\e[36mSession ##{@interactive_session_id} saved.\e[0m"
        if @interactive_session_name
          $stdout.puts "\e[2m  Resume with: ai_resume \"#{@interactive_session_name}\"\e[0m"
        else
          $stdout.puts "\e[2m  Name it:   ai_name #{@interactive_session_id}, \"descriptive_name\"\e[0m"
          $stdout.puts "\e[2m  Resume it: ai_resume #{@interactive_session_id}\e[0m"
        end
      end
      $stdout.puts "\e[36mLeft ConsoleAgent interactive mode.\e[0m"
    end
  end
end
