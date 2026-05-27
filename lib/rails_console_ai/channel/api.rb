require 'rails_console_ai/channel/base'

module RailsConsoleAi
  module Channel
    # Non-interactive channel used by the AgentRunner. It owns its own
    # buffers — there is no parent channel and no user to prompt. The
    # runner reads `captured_output` back as the agent's `result`.
    #
    # Mirrors Channel::Slack's pattern of logging every display event to
    # STDOUT (tagged) so the rake task log shows progress in real time,
    # while ALSO buffering display output into `captured_output` for the
    # runner to compose the final result.
    class Api < Base
      ANSI_REGEX = /\e\[[0-9;]*[a-zA-Z]/.freeze

      attr_reader :captured_output, :status_log

      def initialize(user_name: nil)
        @user_name = user_name
        @captured_output = +''
        @status_log = []
      end

      def display(text)
        stripped = strip_ansi(text)
        @captured_output << stripped << "\n"
        log_prefixed(">>", stripped)
      end

      def display_result(text)
        stripped = strip_ansi(text)
        @captured_output << stripped << "\n"
        log_prefixed(">>", stripped)
      end

      def display_result_output(text)
        stripped = strip_ansi(text)
        @captured_output << stripped << "\n"
        log_prefixed(">>", stripped)
      end

      def display_code(code)
        # Don't add to captured_output — code itself is persisted on the
        # session row as code_executed. But DO log it to STDOUT so the
        # rake task log shows what was generated.
        log_prefixed("(code)", '')
        code.to_s.each_line { |line| log_prefixed("(code)", line.rstrip) }
      end

      def display_thinking(text)
        stripped = strip_ansi(text).strip
        return if stripped.empty?
        @status_log << stripped
        log_prefixed("(thinking)", stripped)
      end

      def display_status(text)
        stripped = strip_ansi(text).strip
        return if stripped.empty?
        @status_log << stripped
        log_prefixed("(status)", stripped)
      end

      def display_tool_call(text)
        stripped = strip_ansi(text)
        @status_log << stripped
        log_prefixed("->", stripped)
      end

      def display_warning(text)
        stripped = strip_ansi(text)
        @status_log << "WARN: #{stripped}"
        log_prefixed("(warn)", stripped)
      end

      def display_error(text)
        stripped = strip_ansi(text)
        @status_log << "ERROR: #{stripped}"
        log_prefixed("(error)", stripped)
      end

      def prompt(_text)
        ''  # non-interactive — no user to ask
      end

      def confirm(_text)
        # No human present to confirm. Auto-yes matches Channel::SubAgent's
        # behavior — actual safety comes from the safety guards plus
        # supports_danger? = false below, not from this prompt.
        'y'
      end

      def user_identity
        @user_name
      end

      def mode
        'api'
      end

      def cancelled?
        false
      end

      def supports_danger?
        false  # like sub_agent: never bypass safety guards without a human
      end

      def supports_editing?
        false
      end

      def wrap_llm_call(&block)
        yield
      end

      def system_instructions
        nil
      end

      private

      # Mirror of Channel::Slack#log_prefixed — emit each line through
      # $stdout so PrefixedIO (installed by AgentRunner#start) adds the
      # per-session tag from Thread.current[:log_prefix].
      def log_prefixed(tag, text)
        if text.to_s.strip.empty?
          $stdout.puts(tag)
        else
          text.to_s.each_line { |line| $stdout.puts "#{tag} #{line.rstrip}" }
        end
      end

      def strip_ansi(text)
        text.to_s.gsub(ANSI_REGEX, '')
      end
    end
  end
end
