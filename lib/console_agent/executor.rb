require 'stringio'

module ConsoleAgent
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

    def initialize(binding_context)
      @binding_context = binding_context
      @omitted_outputs = {}
      @omitted_counter = 0
      @output_store = {}
      @output_counter = 0
    end

    def extract_code(response)
      match = response.match(CODE_REGEX)
      match ? match[1].strip : ''
    end

    def display_response(response)
      code = extract_code(response)
      explanation = response.gsub(CODE_REGEX, '').strip

      $stdout.puts
      $stdout.puts colorize(explanation, :cyan) unless explanation.empty?

      unless code.empty?
        $stdout.puts
        $stdout.puts colorize("# Generated code:", :yellow)
        $stdout.puts highlight_code(code)
        $stdout.puts
      end

      code
    end

    def execute(code)
      return nil if code.nil? || code.strip.empty?

      @last_error = nil
      @last_safety_error = false
      @last_safety_exception = nil
      captured_output = StringIO.new
      old_stdout = $stdout
      # Tee output: capture it and also print to the real stdout
      $stdout = TeeIO.new(old_stdout, captured_output)

      result = with_safety_guards do
        binding_context.eval(code, "(console_agent)", 1)
      end

      $stdout = old_stdout
      display_result(result)

      @last_output = captured_output.string
      result
    rescue ConsoleAgent::SafetyError => e
      $stdout = old_stdout if old_stdout
      @last_error = "SafetyError: #{e.message}"
      @last_safety_error = true
      @last_safety_exception = e
      $stderr.puts colorize("Blocked: #{e.message}", :red)
      @last_output = captured_output&.string
      nil
    rescue SyntaxError => e
      $stdout = old_stdout if old_stdout
      @last_error = "SyntaxError: #{e.message}"
      $stderr.puts colorize(@last_error, :red)
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
        $stderr.puts colorize("Blocked: #{safety_msg}", :red)
        @last_output = captured_output&.string
        return nil
      end
      @last_error = "#{e.class}: #{e.message}"
      $stderr.puts colorize("Error: #{@last_error}", :red)
      e.backtrace.first(3).each { |line| $stderr.puts colorize("  #{line}", :red) }
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
      $stdout.print colorize(prompt, :yellow)
      @on_prompt&.call
      answer = $stdin.gets.to_s.strip.downcase
      @last_answer = answer
      echo_stdin(answer)

      loop do
        case answer
        when 'y', 'yes', 'a'
          result = execute(code)
          return offer_danger_retry(code) if @last_safety_error
          return result
        when 'd', 'danger'
          $stdout.puts colorize("Executing with safety guards disabled.", :red)
          return execute_unsafe(code)
        when 'e', 'edit'
          edited = open_in_editor(code)
          if edited && edited != code
            $stdout.puts colorize("# Edited code:", :yellow)
            $stdout.puts highlight_code(edited)
            $stdout.print colorize("Execute edited code? [y/N] ", :yellow)
            edit_answer = $stdin.gets.to_s.strip.downcase
            echo_stdin(edit_answer)
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
          $stdout.print colorize(prompt, :yellow)
          @on_prompt&.call
          answer = $stdin.gets.to_s.strip.downcase
          @last_answer = answer
          echo_stdin(answer)
        end
      end
    end

    def offer_danger_retry(code)
      exc = @last_safety_exception
      blocked_key = exc&.blocked_key
      guard = exc&.guard

      if blocked_key && guard
        allow_desc = allow_description(guard, blocked_key)
        $stdout.puts colorize("  [d] re-run with all safe mode disabled", :yellow)
        $stdout.puts colorize("  [a] allow #{allow_desc} for this session", :yellow)
        $stdout.puts colorize("  [N] cancel", :yellow)
        $stdout.print colorize("Choice: ", :yellow)
      else
        $stdout.print colorize("Re-run with safe mode disabled? [y/N] ", :yellow)
      end

      answer = $stdin.gets.to_s.strip.downcase
      echo_stdin(answer)

      case answer
      when 'a', 'allow'
        if blocked_key && guard
          ConsoleAgent.configuration.safety_guards.allow(guard, blocked_key)
          allow_desc = allow_description(guard, blocked_key)
          $stdout.puts colorize("Allowed #{allow_desc} for this session.", :green)
          return execute(code)
        else
          $stdout.puts colorize("Nothing to allow — re-run with safe mode disabled instead? [y/N]", :yellow)
          answer = $stdin.gets.to_s.strip.downcase
          echo_stdin(answer)
        end
      when 'd', 'danger', 'y', 'yes'
        $stdout.puts colorize("Executing with safety guards disabled.", :red)
        return execute_unsafe(code)
      end

      $stdout.puts colorize("Cancelled.", :yellow)
      nil
    end

    private

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
      guards = ConsoleAgent.configuration.safety_guards
      guards.disable!
      execute(code)
    ensure
      guards.enable!
    end

    def execute_prompt
      guards = ConsoleAgent.configuration.safety_guards
      if !guards.empty? && guards.enabled?
        "Execute? [y/N/edit/danger] "
      else
        "Execute? [y/N/edit] "
      end
    end

    def with_safety_guards(&block)
      ConsoleAgent.configuration.safety_guards.wrap(&block)
    end

    # Check if an exception is or wraps a SafetyError (e.g. AR::StatementInvalid wrapping it)
    def safety_error?(exception)
      return true if exception.is_a?(ConsoleAgent::SafetyError)
      return true if exception.message.include?("ConsoleAgent safe mode")
      cause = exception.cause
      while cause
        return true if cause.is_a?(ConsoleAgent::SafetyError)
        cause = cause.cause
      end
      false
    end

    def extract_safety_exception(exception)
      return exception if exception.is_a?(ConsoleAgent::SafetyError)
      cause = exception.cause
      while cause
        return cause if cause.is_a?(ConsoleAgent::SafetyError)
        cause = cause.cause
      end
      nil
    end

    MAX_DISPLAY_LINES = 10
    MAX_DISPLAY_CHARS = 2000

    def display_result(result)
      full = "=> #{result.inspect}"
      lines = full.lines
      total_lines = lines.length
      total_chars = full.length

      if total_lines <= MAX_DISPLAY_LINES && total_chars <= MAX_DISPLAY_CHARS
        $stdout.puts colorize(full, :green)
      else
        # Truncate by lines first, then by chars
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

    # Write stdin input to the capture IO only (avoids double-echo on terminal)
    def echo_stdin(text)
      $stdout.secondary.write("#{text}\n") if $stdout.respond_to?(:secondary)
    end

    def open_in_editor(code)
      require 'tempfile'
      editor = ENV['EDITOR'] || 'vi'
      tmpfile = Tempfile.new(['console_agent', '.rb'])
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
