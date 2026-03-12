require 'stringio'
require_relative 'safety_guards'

module RailsConsoleAi
  # Writes to two IO streams simultaneously
  class TeeIO
    attr_reader :secondary

    def initialize(primary, secondary)
      @primary = primary
      @secondary = secondary
    end

    def write(str)
      @primary.write(str)
      @secondary.write(str)
    end

    def puts(*args)
      @primary.puts(*args)
      # Capture what puts would output
      args.each { |a| @secondary.write("#{a}\n") }
      @secondary.write("\n") if args.empty?
    end

    def print(*args)
      @primary.print(*args)
      args.each { |a| @secondary.write(a.to_s) }
    end

    def flush
      @primary.flush if @primary.respond_to?(:flush)
    end

    def respond_to_missing?(method, include_private = false)
      @primary.respond_to?(method, include_private) || super
    end

    def method_missing(method, *args, &block)
      @primary.send(method, *args, &block)
    end
  end

  class Executor
    CODE_REGEX = /```ruby\s*\n(.*?)```/m

    attr_reader :binding_context, :last_error, :last_safety_error, :last_safety_exception
    attr_accessor :on_prompt

    def initialize(binding_context, channel: nil)
      @binding_context = binding_context
      @channel = channel
      @omitted_outputs = {}
      @omitted_counter = 0
      @output_store = {}
      @output_counter = 0
      @active_skill_bypass_methods = Set.new
    end

    def extract_code(response)
      match = response.match(CODE_REGEX)
      match ? match[1].strip : ''
    end

    # Matches any fenced code block (```anything ... ```)
    ANY_CODE_FENCE_REGEX = /```\w*\s*\n.*?```/m

    def display_response(response)
      # Code execution now happens via the execute_code tool, not code-fence extraction.
      # Just display the full response text as-is.
      text = response.to_s.strip
      return '' if text.empty?

      $stdout.puts
      if @channel
        @channel.display(text)
      else
        $stdout.puts colorize(text, :cyan)
      end

      '' # No code to extract — the LLM uses execute_code tool instead
    end

    def display_code_block(code)
      if @channel
        @channel.display_code(code)
      else
        $stdout.puts
        $stdout.puts colorize("# Generated code:", :yellow)
        $stdout.puts highlight_code(code)
        $stdout.puts
      end
    end

    def execute(code, display: true)
      return nil if code.nil? || code.strip.empty?

      @last_error = nil
      @last_safety_error = false
      @last_safety_exception = nil
      captured_output = StringIO.new
      old_stdout = $stdout
      # When a channel is present it handles display (with truncation), so capture only.
      # Without a channel, tee so output appears live on the terminal.
      $stdout = if @channel
                  captured_output
                else
                  TeeIO.new(old_stdout, captured_output)
                end

      RailsConsoleAi::SafetyError.clear!

      result = with_safety_guards do
        binding_context.eval(code, "(rails_console_ai)", 1)
      end

      $stdout = old_stdout

      # Check if a SafetyError was raised but swallowed by a rescue inside the eval'd code
      if (swallowed = RailsConsoleAi::SafetyError.last_raised)
        RailsConsoleAi::SafetyError.clear!
        @last_error = "SafetyError: #{swallowed.message}"
        @last_safety_error = true
        @last_safety_exception = swallowed
        display_error("Blocked: #{swallowed.message}")
        @last_output = captured_output&.string
        return nil
      end

      # Send captured puts output through channel before the return value
      if display && @channel && !captured_output.string.empty?
        @channel.display_result_output(captured_output.string)
      end

      display_result(result) if display

      @last_output = captured_output.string
      result
    rescue RailsConsoleAi::SafetyError => e
      $stdout = old_stdout if old_stdout
      RailsConsoleAi::SafetyError.clear!
      @last_error = "SafetyError: #{e.message}"
      @last_safety_error = true
      @last_safety_exception = e
      display_error("Blocked: #{e.message}")
      @last_output = captured_output&.string
      nil
    rescue SyntaxError => e
      $stdout = old_stdout if old_stdout
      @last_error = "SyntaxError: #{e.message}"
      display_error(@last_error)
      @last_output = nil
      nil
    rescue => e
      $stdout = old_stdout if old_stdout
      # Check if a SafetyError is wrapped (e.g. ActiveRecord::StatementInvalid wrapping our error)
      if safety_error?(e)
        safety_exc = extract_safety_exception(e)
        safety_msg = safety_exc ? safety_exc.message : e.message
        @last_error = "SafetyError: #{safety_msg}"
        @last_safety_error = true
        @last_safety_exception = safety_exc
        display_error("Blocked: #{safety_msg}")
        @last_output = captured_output&.string
        return nil
      end
      @last_error = "#{e.class}: #{e.message}"
      backtrace = e.backtrace.first(3).map { |line| "  #{line}" }.join("\n")
      display_error("Error: #{@last_error}\n#{backtrace}")
      @last_output = captured_output&.string
      nil
    end

    def last_output
      @last_output
    end

    def expand_output(id)
      @omitted_outputs[id]
    end

    def store_output(content)
      @output_counter += 1
      @output_store[@output_counter] = content
      @output_counter
    end

    def recall_output(id)
      @output_store[id]
    end

    def last_answer
      @last_answer
    end

    def last_cancelled?
      @last_cancelled
    end

    def confirm_and_execute(code)
      return nil if code.nil? || code.strip.empty?

      @last_cancelled = false
      @last_answer = nil
      prompt = execute_prompt

      if @channel
        answer = @channel.confirm(prompt)
      else
        $stdout.print colorize(prompt, :yellow)
        @on_prompt&.call
        answer = $stdin.gets.to_s.strip.downcase
        echo_stdin(answer)
      end
      @last_answer = answer

      loop do
        case answer
        when 'y', 'yes', 'a'
          result = execute(code)
          if @last_safety_error
            return nil unless danger_allowed?
            return offer_danger_retry(code)
          end
          return result
        when 'd', 'danger'
          unless danger_allowed?
            display_error("Safety guards cannot be disabled in this channel.")
            return nil
          end
          if @channel
            @channel.display_error("Executing with safety guards disabled.")
          else
            $stdout.puts colorize("Executing with safety guards disabled.", :red)
          end
          return execute_unsafe(code)
        when 'e', 'edit'
          edited = if @channel && @channel.supports_editing?
                     @channel.edit_code(code)
                   else
                     open_in_editor(code)
                   end
          if edited && edited != code
            $stdout.puts colorize("# Edited code:", :yellow)
            $stdout.puts highlight_code(edited)
            if @channel
              edit_answer = @channel.confirm("Execute edited code? [y/N] ")
            else
              $stdout.print colorize("Execute edited code? [y/N] ", :yellow)
              edit_answer = $stdin.gets.to_s.strip.downcase
              echo_stdin(edit_answer)
            end
            if edit_answer == 'y'
              return execute(edited)
            else
              $stdout.puts colorize("Cancelled.", :yellow)
              return nil
            end
          else
            return execute(code)
          end
        when 'n', 'no', ''
          $stdout.puts colorize("Cancelled.", :yellow)
          @last_cancelled = true
          return nil
        else
          if @channel
            answer = @channel.confirm(prompt)
          else
            $stdout.print colorize(prompt, :yellow)
            @on_prompt&.call
            answer = $stdin.gets.to_s.strip.downcase
            echo_stdin(answer)
          end
          @last_answer = answer
        end
      end
    end

    def offer_danger_retry(code)
      return nil unless danger_allowed?

      exc = @last_safety_exception
      blocked_key = exc&.blocked_key
      guard = exc&.guard

      if blocked_key && guard
        allow_desc = allow_description(guard, blocked_key)
        $stdout.puts colorize("  [d] re-run with all safe mode disabled", :yellow)
        $stdout.puts colorize("  [a] allow #{allow_desc} for this session", :yellow)
        $stdout.puts colorize("  [N] cancel", :yellow)
        prompt_text = "Choice: "
      else
        prompt_text = "Re-run with safe mode disabled? [y/N] "
      end

      if @channel
        answer = @channel.confirm(prompt_text)
      else
        $stdout.print colorize(prompt_text, :yellow)
        answer = $stdin.gets.to_s.strip.downcase
        echo_stdin(answer)
      end

      case answer
      when 'a', 'allow'
        if blocked_key && guard
          RailsConsoleAi.configuration.safety_guards.allow(guard, blocked_key)
          allow_desc = allow_description(guard, blocked_key)
          $stdout.puts colorize("Allowed #{allow_desc} for this session.", :green)
          return execute(code)
        else
          if @channel
            answer = @channel.confirm("Nothing to allow — re-run with safe mode disabled instead? [y/N] ")
          else
            $stdout.puts colorize("Nothing to allow — re-run with safe mode disabled instead? [y/N]", :yellow)
            answer = $stdin.gets.to_s.strip.downcase
            echo_stdin(answer)
          end
        end
      when 'd', 'danger', 'y', 'yes'
        $stdout.puts colorize("Executing with safety guards disabled.", :red)
        return execute_unsafe(code)
      end

      $stdout.puts colorize("Cancelled.", :yellow)
      nil
    end

    def activate_skill_bypasses(methods)
      guards = RailsConsoleAi.configuration.safety_guards
      Array(methods).each do |spec|
        @active_skill_bypass_methods << spec
        guards.install_bypass_method!(spec)
      end
    end

    private

    def danger_allowed?
      @channel.nil? || @channel.supports_danger?
    end

    def display_error(msg)
      if @channel
        @channel.display_error(msg)
      else
        $stderr.puts colorize(msg, :red)
      end
    end

    def allow_description(guard, blocked_key)
      case guard
      when :database_writes
        "all writes to #{blocked_key}"
      when :http_mutations
        "all HTTP mutations to #{blocked_key}"
      else
        "#{blocked_key} for :#{guard}"
      end
    end

    def execute_unsafe(code)
      guards = RailsConsoleAi.configuration.safety_guards
      guards.disable!
      execute(code)
    ensure
      guards.enable!
    end

    def execute_prompt
      guards = RailsConsoleAi.configuration.safety_guards
      if !guards.empty? && guards.enabled? && danger_allowed?
        "Execute? [y/N/edit/danger] "
      else
        "Execute? [y/N/edit] "
      end
    end

    def with_safety_guards(&block)
      RailsConsoleAi.configuration.safety_guards.wrap(
        channel_mode: @channel&.mode,
        additional_bypass_methods: @active_skill_bypass_methods,
        &block
      )
    end

    # Check if an exception is or wraps a SafetyError (e.g. AR::StatementInvalid wrapping it)
    def safety_error?(exception)
      return true if exception.is_a?(RailsConsoleAi::SafetyError)
      return true if exception.message.include?("RailsConsoleAi safe mode")
      cause = exception.cause
      while cause
        return true if cause.is_a?(RailsConsoleAi::SafetyError)
        cause = cause.cause
      end
      false
    end

    def extract_safety_exception(exception)
      return exception if exception.is_a?(RailsConsoleAi::SafetyError)
      cause = exception.cause
      while cause
        return cause if cause.is_a?(RailsConsoleAi::SafetyError)
        cause = cause.cause
      end
      nil
    end

    MAX_DISPLAY_LINES = 10
    MAX_DISPLAY_CHARS = 2000

    def display_result(result)
      if @channel
        @channel.display_result(result)
      else
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
    end

    # Write stdin input to the capture IO only (avoids double-echo on terminal)
    def echo_stdin(text)
      $stdout.secondary.write("#{text}\n") if $stdout.respond_to?(:secondary)
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
