require 'readline'
require 'rails_console_ai/channel/base'

module RailsConsoleAi
  module Channel
    class Console < Base
      attr_reader :real_stdout

      def initialize
        @real_stdout = $stdout
      end

      def display(text)
        $stdout.puts colorize(text, :cyan)
      end

      def display_dim(text)
        $stdout.puts "\e[2m#{text}\e[0m"
      end

      def display_tool_call(text)
        $stdout.puts "\e[33m  -> #{text}\e[0m"
      end

      def display_warning(text)
        $stdout.puts colorize(text, :yellow)
      end

      def display_error(text)
        $stderr.puts colorize(text, :red)
      end

      def display_code(code)
        $stdout.puts
        $stdout.puts colorize("# Generated code:", :yellow)
        $stdout.puts highlight_code(code)
        $stdout.puts
      end

      def display_result_output(output)
        text = output.to_s
        return if text.strip.empty?

        lines = text.lines
        total_lines = lines.length
        total_chars = text.length

        if total_lines <= MAX_DISPLAY_LINES && total_chars <= MAX_DISPLAY_CHARS
          $stdout.print text
        else
          truncated = lines.first(MAX_DISPLAY_LINES).join
          truncated = truncated[0, MAX_DISPLAY_CHARS] if truncated.length > MAX_DISPLAY_CHARS
          $stdout.print truncated

          omitted_lines = [total_lines - MAX_DISPLAY_LINES, 0].max
          omitted_chars = [total_chars - truncated.length, 0].max
          parts = []
          parts << "#{omitted_lines} lines" if omitted_lines > 0
          parts << "#{omitted_chars} chars" if omitted_chars > 0

          @omitted_counter += 1
          @omitted_outputs[@omitted_counter] = text
          $stdout.puts colorize("  (output truncated, omitting #{parts.join(', ')})  /expand #{@omitted_counter} to see all", :yellow)
        end
      end

      def display_result(result)
        full = "=> #{result.inspect}"
        lines = full.lines
        total_lines = lines.length
        total_chars = full.length

        if total_lines <= MAX_DISPLAY_LINES && total_chars <= MAX_DISPLAY_CHARS
          $stdout.puts colorize(full, :green)
        else
          truncated = lines.first(MAX_DISPLAY_LINES).join
          truncated = truncated[0, MAX_DISPLAY_CHARS] if truncated.length > MAX_DISPLAY_CHARS
          $stdout.puts colorize(truncated, :green)

          omitted_lines = [total_lines - MAX_DISPLAY_LINES, 0].max
          omitted_chars = [total_chars - truncated.length, 0].max
          parts = []
          parts << "#{omitted_lines} lines" if omitted_lines > 0
          parts << "#{omitted_chars} chars" if omitted_chars > 0

          @omitted_counter += 1
          @omitted_outputs[@omitted_counter] = full
          $stdout.puts colorize("  (omitting #{parts.join(', ')})  /expand #{@omitted_counter} to see all", :yellow)
        end
      end

      def prompt(text)
        $stdout.print colorize(text, :cyan)
        answer = $stdin.gets
        return '(no answer provided)' if answer.nil?
        answer.strip.empty? ? '(no answer provided)' : answer.strip
      end

      def confirm(text)
        $stdout.print colorize(text, :yellow)
        $stdin.gets.to_s.strip.downcase
      end

      def user_identity
        RailsConsoleAi.current_user
      end

      def mode
        'console'
      end

      def supports_editing?
        true
      end

      def edit_code(code)
        open_in_editor(code)
      end

      def wrap_llm_call(&block)
        with_escape_monitoring(&block)
      end

      # --- Omitted output tracking (shared with Executor) ---

      MAX_DISPLAY_LINES = 10
      MAX_DISPLAY_CHARS = 2000

      def init_omitted_tracking
        @omitted_outputs = {}
        @omitted_counter = 0
      end

      def expand_output(id)
        @omitted_outputs[id]
      end

      # --- Interactive loop ---

      def interactive_loop(engine)
        @engine = engine
        engine.init_interactive
        init_interactive_state
        run_interactive_loop
      end

      def resume_interactive(engine, session)
        @engine = engine
        engine.init_interactive
        init_interactive_state

        # Restore state from the previous session
        engine.restore_session(session)

        # Seed the capture buffer with previous output so it's preserved on save
        @interactive_console_capture.write(session.console_output.to_s)

        # Replay to the user via the real stdout (bypass TeeIO to avoid double-capture)
        if session.console_output && !session.console_output.strip.empty?
          @real_stdout.puts "\e[2m--- Replaying previous session output ---\e[0m"
          @real_stdout.puts session.console_output
          @real_stdout.puts "\e[2m--- End of previous output ---\e[0m"
          @real_stdout.puts
        end

        run_interactive_loop
      end

      # Provide access to the console capture for session logging
      def console_capture_string
        @interactive_console_capture&.string
      end

      def write_to_capture(text)
        @interactive_console_capture&.write(text)
      end

      private

      def init_interactive_state
        init_omitted_tracking
        @interactive_console_capture = StringIO.new
        @real_stdout = $stdout
        $stdout = TeeIO.new(@real_stdout, @interactive_console_capture)
      end

      def run_interactive_loop
        auto = RailsConsoleAi.configuration.auto_execute
        guards = RailsConsoleAi.configuration.safety_guards
        name_display = @engine.session_name ? " (#{@engine.session_name})" : ""
        @real_stdout.puts "\e[36mRailsConsoleAi interactive mode#{name_display}. Type 'exit' or 'quit' to leave.\e[0m"
        config = RailsConsoleAi.configuration
        @real_stdout.puts "\e[2m  Provider: #{config.provider} | Model: #{config.resolved_model}\e[0m"
        safe_info = guards.empty? ? '' : " | Safe mode: #{guards.enabled? ? 'ON' : 'OFF'} (/danger to toggle)"
        @real_stdout.puts "\e[2m  Auto-execute: #{auto ? 'ON' : 'OFF'} (Shift-Tab or /auto to toggle)#{safe_info} | > code | /usage | /cost | /compact | /think | /name <label>\e[0m"

        if Readline.respond_to?(:parse_and_bind)
          Readline.parse_and_bind('"\e[Z": "\C-a\C-k/auto\C-m"')
        end

        loop do
          input = Readline.readline("\001\e[33m\002ai> \001\e[0m\002", false)
          break if input.nil?

          input = input.strip
          break if input.downcase == 'exit' || input.downcase == 'quit'
          next if input.empty?

          handled = handle_slash_command(input)
          next if handled

          # Direct code execution with ">" prefix
          if input.start_with?('>') && !input.start_with?('>=')
            handle_direct_execution(input)
            next
          end

          # Add to Readline history
          Readline::HISTORY.push(input) unless input == Readline::HISTORY.to_a.last

          # Auto-upgrade to thinking model on "think harder" phrases
          @engine.upgrade_to_thinking_model if input =~ /think\s*harder/i

          @engine.set_interactive_query(input)
          @engine.add_user_message(input)
          @interactive_console_capture.write("ai> #{input}\n")
          @engine.log_interactive_turn

          status = @engine.send_and_execute
          if status == :interrupted
            @engine.pop_last_message
            @engine.log_interactive_turn
            next
          end

          if status == :error
            $stdout.puts "\e[2m  Attempting to fix...\e[0m"
            @engine.log_interactive_turn
            @engine.send_and_execute
          end

          @engine.log_interactive_turn
          @engine.warn_if_history_large
        end

        $stdout = @real_stdout
        @engine.finish_interactive_session
        display_exit_info
      rescue Interrupt
        $stdout = @real_stdout if @real_stdout
        $stdout.puts
        @engine.finish_interactive_session
        display_exit_info
      rescue => e
        $stdout = @real_stdout if @real_stdout
        $stderr.puts "\e[31mRailsConsoleAi Error: #{e.class}: #{e.message}\e[0m"
      end

      def handle_slash_command(input)
        case input
        when '?', '/'
          display_help
        when '/auto'
          RailsConsoleAi.configuration.auto_execute = !RailsConsoleAi.configuration.auto_execute
          mode = RailsConsoleAi.configuration.auto_execute ? 'ON' : 'OFF'
          @real_stdout.puts "\e[36m  Auto-execute: #{mode}\e[0m"
        when '/danger'
          toggle_danger
        when '/safe'
          display_safe_status
        when '/usage'
          @engine.display_session_summary
        when '/debug'
          RailsConsoleAi.configuration.debug = !RailsConsoleAi.configuration.debug
          mode = RailsConsoleAi.configuration.debug ? 'ON' : 'OFF'
          @real_stdout.puts "\e[36m  Debug: #{mode}\e[0m"
        when '/compact'
          @engine.compact_history
        when '/system'
          @real_stdout.puts "\e[2m#{@engine.context}\e[0m"
        when '/context'
          @engine.display_conversation
        when '/cost'
          @engine.display_cost_summary
        when '/model'
          display_model_info
        when '/think'
          @engine.upgrade_to_thinking_model
        when /\A\/expand/
          expand_id = input.sub('/expand', '').strip.to_i
          full_output = expand_output(expand_id)
          if full_output
            @real_stdout.puts full_output
          else
            @real_stdout.puts "\e[33mNo omitted output with id #{expand_id}\e[0m"
          end
        when '/retry'
          retry_last_code
        when /\A\/name/
          handle_name_command(input)
        else
          return false
        end
        true
      end

      def retry_last_code
        @engine.retry_last_code
      end

      def handle_direct_execution(input)
        raw_code = input.sub(/\A>\s?/, '')
        Readline::HISTORY.push(input) unless input == Readline::HISTORY.to_a.last
        @interactive_console_capture.write("ai> #{input}\n")
        @engine.execute_direct(raw_code)
        @engine.log_interactive_turn
      end

      def toggle_danger
        guards = RailsConsoleAi.configuration.safety_guards
        if guards.empty?
          @real_stdout.puts "\e[33m  No safety guards configured.\e[0m"
        elsif guards.enabled?
          guards.disable!
          @real_stdout.puts "\e[31m  Safe mode: OFF (writes and side effects allowed!)\e[0m"
        else
          guards.enable!
          @real_stdout.puts "\e[32m  Safe mode: ON (#{guards.names.join(', ')} guarded)\e[0m"
        end
      end

      def display_safe_status
        guards = RailsConsoleAi.configuration.safety_guards
        if guards.empty?
          @real_stdout.puts "\e[33m  No safety guards configured.\e[0m"
        else
          status = guards.enabled? ? "\e[32mON\e[0m" : "\e[31mOFF\e[0m"
          @real_stdout.puts "\e[36m  Safe mode: #{status}\e[0m"
          @real_stdout.puts "\e[2m  Guards: #{guards.names.join(', ')}\e[0m"
          unless guards.allowlist.empty?
            @real_stdout.puts "\e[2m  Allowlist:\e[0m"
            guards.allowlist.each do |guard_name, keys|
              keys.each do |key|
                label = key.is_a?(Regexp) ? key.inspect : key.to_s
                @real_stdout.puts "\e[2m    :#{guard_name} → #{label}\e[0m"
              end
            end
          end
        end
      end

      def display_model_info
        config = RailsConsoleAi.configuration
        model = config.resolved_model
        thinking = config.resolved_thinking_model
        pricing = Configuration::PRICING[model]

        @real_stdout.puts "\e[36m  Model info:\e[0m"
        @real_stdout.puts "\e[2m    Provider:        #{config.provider}\e[0m"
        @real_stdout.puts "\e[2m    Model:           #{model}\e[0m"
        @real_stdout.puts "\e[2m    Thinking model:  #{thinking}\e[0m"
        @real_stdout.puts "\e[2m    Max tokens:      #{config.resolved_max_tokens}\e[0m"
        if pricing
          @real_stdout.puts "\e[2m    Pricing:         $#{pricing[:input] * 1_000_000}/M in, $#{pricing[:output] * 1_000_000}/M out\e[0m"
          if pricing[:cache_read]
            @real_stdout.puts "\e[2m    Cache pricing:   $#{pricing[:cache_read] * 1_000_000}/M read, $#{pricing[:cache_write] * 1_000_000}/M write\e[0m"
          end
        end
        @real_stdout.puts "\e[2m    Bedrock region:  #{config.bedrock_region}\e[0m" if config.provider == :bedrock
        @real_stdout.puts "\e[2m    Local URL:       #{config.local_url}\e[0m" if config.provider == :local
      end

      def handle_name_command(input)
        name = input.sub('/name', '').strip.gsub(/\A(['"])(.*)\1\z/, '\2')
        if name.empty?
          if @engine.session_name
            @real_stdout.puts "\e[36m  Session name: #{@engine.session_name}\e[0m"
          else
            @real_stdout.puts "\e[33m  Usage: /name <label>  (e.g. /name salesforce_user_123)\e[0m"
          end
        else
          @engine.set_session_name(name)
          @real_stdout.puts "\e[36m  Session named: #{name}\e[0m"
        end
      end

      def display_help
        auto = RailsConsoleAi.configuration.auto_execute ? 'ON' : 'OFF'
        guards = RailsConsoleAi.configuration.safety_guards
        @real_stdout.puts "\e[36m  Commands:\e[0m"
        @real_stdout.puts "\e[2m    /auto        Toggle auto-execute (currently #{auto}) (Shift-Tab)\e[0m"
        unless guards.empty?
          safe_status = guards.enabled? ? 'ON' : 'OFF'
          @real_stdout.puts "\e[2m    /danger      Toggle safe mode (currently #{safe_status})\e[0m"
          @real_stdout.puts "\e[2m    /safe        Show safety guard status\e[0m"
        end
        @real_stdout.puts "\e[2m    /model       Show provider, model, and pricing info\e[0m"
        @real_stdout.puts "\e[2m    /think       Switch to thinking model\e[0m"
        @real_stdout.puts "\e[2m    /compact     Summarize conversation to reduce context\e[0m"
        @real_stdout.puts "\e[2m    /usage       Show session token totals\e[0m"
        @real_stdout.puts "\e[2m    /cost        Show cost estimate by model\e[0m"
        @real_stdout.puts "\e[2m    /name <lbl>  Name this session for easy resume\e[0m"
        @real_stdout.puts "\e[2m    /context     Show conversation history sent to the LLM\e[0m"
        @real_stdout.puts "\e[2m    /system      Show the system prompt\e[0m"
        @real_stdout.puts "\e[2m    /expand <id> Show full omitted output\e[0m"
        @real_stdout.puts "\e[2m    /debug       Toggle debug summaries (context stats, cost per call)\e[0m"
        @real_stdout.puts "\e[2m    /retry       Re-execute the last code block\e[0m"
        @real_stdout.puts "\e[2m    > code       Execute Ruby directly (skip LLM)\e[0m"
        @real_stdout.puts "\e[2m    exit/quit    Leave interactive mode\e[0m"
      end

      def display_exit_info
        @engine.display_session_summary
        session_id = @engine.interactive_session_id
        if session_id
          $stdout.puts "\e[36mSession ##{session_id} saved.\e[0m"
          if @engine.session_name
            $stdout.puts "\e[2m  Resume with: ai_resume \"#{@engine.session_name}\"\e[0m"
          else
            $stdout.puts "\e[2m  Name it:   ai_name #{session_id}, \"descriptive_name\"\e[0m"
            $stdout.puts "\e[2m  Resume it: ai_resume #{session_id}\e[0m"
          end
        end
        $stdout.puts "\e[36mLeft RailsConsoleAi interactive mode.\e[0m"
      end

      # --- Terminal helpers ---

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

              if char == "\x03"
                Thread.main.raise(Interrupt)
                break
              elsif char == "\e"
                seq = IO.select([io], nil, nil, 0.05)
                if seq
                  io.read_nonblock(10) rescue nil
                else
                  Thread.main.raise(Interrupt)
                  break
                end
              end
            end
          end
        rescue IOError, Errno::EIO, Errno::ENODEV, Errno::ENOTTY
          # stdin is not a TTY — silently skip
        end

        begin
          yield
        ensure
          monitor[:stop] = true
          monitor.join(1) rescue nil
        end
      end

      def open_in_editor(code)
        require 'tempfile'
        editor = ENV['EDITOR'] || 'vi'
        tmpfile = Tempfile.new(['rails_console_ai', '.rb'])
        tmpfile.write(code)
        tmpfile.flush
        system("#{editor} #{tmpfile.path}")
        File.read(tmpfile.path)
      rescue => e
        $stderr.puts colorize("Editor error: #{e.message}", :red)
        code
      ensure
        tmpfile.close! if tmpfile
      end

      def highlight_code(code)
        if coderay_available?
          CodeRay.scan(code, :ruby).terminal
        else
          colorize(code, :white)
        end
      end

      def coderay_available?
        return @coderay_available unless @coderay_available.nil?
        @coderay_available = begin
          require 'coderay'
          true
        rescue LoadError
          false
        end
      end

      COLORS = {
        red:    "\e[31m",
        green:  "\e[32m",
        yellow: "\e[33m",
        cyan:   "\e[36m",
        white:  "\e[37m",
        reset:  "\e[0m"
      }.freeze

      def colorize(text, color)
        if $stdout.respond_to?(:tty?) && $stdout.tty?
          "#{COLORS[color]}#{text}#{COLORS[:reset]}"
        else
          text
        end
      end
    end
  end
end
