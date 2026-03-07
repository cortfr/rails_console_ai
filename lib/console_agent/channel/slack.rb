require 'console_agent/channel/base'

module ConsoleAgent
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
        stripped = strip_ansi(text).strip
        if stripped =~ /\AThinking\.\.\.|\ACalling LLM/
          post(random_thinking_message)
        elsif stripped =~ /\AAttempting to fix|\ACancelled|\A_session:/
          post(stripped)
        else
          # Log for engineers but don't post to Slack
          @output_log.write("#{stripped}\n")
          $stdout.puts "#{@log_prefix} (dim) #{stripped}"
        end
      end

      def display_warning(text)
        post(":warning: #{strip_ansi(text)}")
      end

      def display_error(text)
        post(":x: #{strip_ansi(text)}")
      end

      def display_code(code)
        post("```#{strip_ansi(code)}```")
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

          - Format results as readable tables using Slack markdown, NOT raw Ruby objects or arrays
          - Use `puts` with formatted output instead of returning arrays or hashes
          - Summarize findings in plain, simple language
          - Do NOT show technical details like SQL queries, token counts, or class names
          - Keep explanations simple and jargon-free
          - When showing records, format as a clean table with headers and aligned columns
          - Never return raw Ruby objects — always present data in a human-readable way
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
        ConsoleAgent.logger.error("Slack post failed: #{e.message}")
      end

      def random_thinking_message
        THINKING_MESSAGES.sample
      end

      def strip_ansi(text)
        text.to_s.gsub(ANSI_REGEX, '')
      end
    end
  end
end
