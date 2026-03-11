require 'rails_console_ai/channel/base'

module RailsConsoleAi
  module Channel
    class Slack < Base
      ANSI_REGEX = /\e\[[0-9;]*m/

      def initialize(slack_bot:, channel_id:, thread_ts:, user_name: nil)
        @slack_bot = slack_bot
        @channel_id = channel_id
        @thread_ts = thread_ts
        @user_name = user_name
        @reply_queue = Queue.new
        @cancelled = false
        @log_prefix = "[#{@channel_id}/#{@thread_ts}] @#{@user_name}"
        @output_log = StringIO.new
      end

      def cancel!
        @cancelled = true
      end

      def cancelled?
        @cancelled
      end

      def display(text)
        post(strip_ansi(text))
      end

      def display_dim(text)
        raw = strip_ansi(text)
        stripped = raw.strip

        if stripped =~ /\AThinking\.\.\.|\AAttempting to fix|\ACancelled|\A_session:/
          post(stripped)
        elsif stripped =~ /\ACalling LLM/
          # Technical LLM round status — suppress in Slack
          @output_log.write("#{stripped}\n")
          STDOUT.puts "#{@log_prefix} (dim) #{stripped}"
        elsif raw =~ /\A {2,4}\S/ && stripped.length > 10
          # LLM thinking text (2-space indent from conversation engine) — show as status
          post(stripped)
        else
          # Tool result previews (5+ space indent) and other technical noise — log only
          @output_log.write("#{stripped}\n")
          STDOUT.puts "#{@log_prefix} (dim) #{stripped}"
        end
      end

      def display_warning(text)
        post(":warning: #{strip_ansi(text)}")
      end

      def display_error(text)
        post(":x: #{strip_ansi(text)}")
      end

      def display_tool_call(text)
        @output_log.write("-> #{text}\n")
        STDOUT.puts "#{@log_prefix} -> #{text}"
      end

      def display_code(code)
        # Don't post raw code/plan steps to Slack — non-technical users don't need to see Ruby
        # But do log to STDOUT so server logs show what was generated/executed
        @output_log.write("# Generated code:\n#{code}\n")
        STDOUT.puts "#{@log_prefix} (code)\n# Generated code:\n#{code}"
      end

      def display_result_output(output)
        text = strip_ansi(output).strip
        return if text.empty?
        text = text[0, 3000] + "\n... (truncated)" if text.length > 3000
        post("```#{text}```")
      end

      def display_result(_result)
        # Don't post raw return values to Slack — the LLM formats output via puts
        nil
      end

      def prompt(text)
        post(strip_ansi(text))
        @reply_queue.pop
      end

      def confirm(_text)
        'y'
      end

      def user_identity
        @user_name
      end

      def mode
        'slack'
      end

      def supports_danger?
        false
      end

      def supports_editing?
        false
      end

      def wrap_llm_call(&block)
        yield
      end

      def system_instructions
        <<~INSTRUCTIONS.strip
          ## Response Formatting (Slack Channel)

          You are responding to non-technical users in Slack. Follow these rules:

          ## Code Execution
          - ALWAYS use the `execute_code` tool to run Ruby code. Do NOT put code in markdown
            code fences expecting it to be executed — code fences are display-only in Slack.
          - Use `execute_code` for simple queries, and `execute_plan` for multi-step operations.
          - If the user asks you to provide code they can run later, put it in a code fence
            in your text response (it will be displayed but not executed).

          ## Formatting
          - Slack does NOT support markdown tables. For tabular data, use `puts` to print
            a plain-text table inside a code block. Use fixed-width columns with padding so
            columns align. Example format:
            ```
            ID   Name              Email
            123  John Smith        john@example.com
            456  Jane Doe          jane@example.com
            ```
          - Use `puts` with formatted output instead of returning arrays or hashes
          - Summarize findings in plain, simple language
          - Do NOT show technical details like SQL queries, token counts, or class names
          - Keep explanations simple and jargon-free
          - Never return raw Ruby objects — always present data in a human-readable way
          - The output of `puts` in your code is automatically shown to the user. Do NOT
            repeat or re-display data that your code already printed via `puts`.
            Just add a brief summary after (e.g. "10 events found" or "Let me know if you need more detail").
          - Do not offer to make changes or take actions on behalf of the user. Only report findings.
          - This is a live production database — other processes, users, and background jobs are
            constantly changing data. Never assume results will be the same as a previous query.
            Always re-run queries when asked, even if you just ran the same one.
        INSTRUCTIONS
      end

      def log_input(text)
        @output_log.write("@#{@user_name}: #{text}\n")
      end

      # Called by SlackBot when a thread reply arrives
      def receive_reply(text)
        @output_log.write("@#{@user_name}: #{text}\n")
        @reply_queue.push(text)
      end

      def console_capture_string
        @output_log.string
      end

      private

      def post(text)
        return if text.nil? || text.strip.empty?
        @output_log.write("#{text}\n")
        STDOUT.puts "#{@log_prefix} >> #{text}"
        @slack_bot.send(:post_message,
          channel: @channel_id,
          thread_ts: @thread_ts,
          text: text
        )
      rescue => e
        RailsConsoleAi.logger.error("Slack post failed: #{e.message}")
      end

      def strip_ansi(text)
        text.to_s.gsub(ANSI_REGEX, '')
      end
    end
  end
end
