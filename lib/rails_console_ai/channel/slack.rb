require 'rails_console_ai/channel/base'

module RailsConsoleAi
  module Channel
    class Slack < Base
      ANSI_REGEX = /\e\[[0-9;]*m/

      THINKING_MESSAGES = [
        "Thinking...",
        "Reticulating splines...",
        "Scrubbing encryption bits...",
        "Consulting the oracle...",
        "Rummaging through the database...",
        "Warming up the hamster wheel...",
        "Polishing the pixels...",
        "Untangling the spaghetti code...",
        "Asking the magic 8-ball...",
        "Counting all the things...",
        "Herding the electrons...",
        "Dusting off the old records...",
        "Feeding the algorithms...",
        "Shaking the data tree...",
        "Bribing the servers...",
      ].freeze

      def initialize(slack_bot:, channel_id:, thread_ts:, user_name: nil)
        @slack_bot = slack_bot
        @channel_id = channel_id
        @thread_ts = thread_ts
        @user_name = user_name
        @reply_queue = Queue.new
        @cancelled = false
        @log_prefix = "[#{@channel_id}/#{@thread_ts}] @#{@user_name}"
        @output_log = StringIO.new
        @thinking_ts = nil
      end

      def cancel!
        @cancelled = true
      end

      def cancelled?
        @cancelled
      end

      def display(text)
        clear_thinking
        post(strip_ansi(text))
      end

      def display_dim(text)
        stripped = strip_ansi(text).strip
        if stripped =~ /\AThinking\.\.\.|\ACalling LLM/
          show_thinking
        elsif stripped =~ /\AAttempting to fix|\ACancelled|\A_session:/
          post(stripped)
        else
          # Log for engineers but don't post to Slack
          @output_log.write("#{stripped}\n")
          $stdout.puts "#{@log_prefix} (dim) #{stripped}"
        end
      end

      def display_warning(text)
        clear_thinking
        post(":warning: #{strip_ansi(text)}")
      end

      def display_error(text)
        clear_thinking
        post(":x: #{strip_ansi(text)}")
      end

      def display_code(_code)
        # Don't post raw code/plan steps to Slack — non-technical users don't need to see Ruby
        nil
      end

      def display_result_output(output)
        clear_thinking
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
        $stdout.puts "#{@log_prefix} >> #{text}"
        @slack_bot.send(:post_message,
          channel: @channel_id,
          thread_ts: @thread_ts,
          text: text
        )
      rescue => e
        RailsConsoleAi.logger.error("Slack post failed: #{e.message}")
      end

      def show_thinking
        msg = THINKING_MESSAGES.sample
        if @thinking_ts
          # Update the existing thinking message in place
          @slack_bot.send(:slack_api, "chat.update",
            channel: @channel_id,
            ts: @thinking_ts,
            text: msg
          )
        else
          # Post a new thinking message and track its ts
          result = @slack_bot.send(:post_message,
            channel: @channel_id,
            thread_ts: @thread_ts,
            text: msg
          )
          @thinking_ts = result&.dig("ts")
        end
        $stdout.puts "#{@log_prefix} >> #{msg}"
      rescue => e
        RailsConsoleAi.logger.error("Slack thinking message failed: #{e.message}")
      end

      def clear_thinking
        return unless @thinking_ts

        @slack_bot.send(:slack_api, "chat.delete",
          channel: @channel_id,
          ts: @thinking_ts
        )
        @thinking_ts = nil
      rescue => e
        RailsConsoleAi.logger.error("Slack clear thinking failed: #{e.message}")
        @thinking_ts = nil
      end

      def strip_ansi(text)
        text.to_s.gsub(ANSI_REGEX, '')
      end
    end
  end
end
