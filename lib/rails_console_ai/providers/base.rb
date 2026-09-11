require 'faraday'
require 'json'

module RailsConsoleAi
  module Providers
    class Base
      attr_reader :config
      attr_accessor :routing_session_id

      def initialize(config = RailsConsoleAi.configuration)
        @config = config
      end

      def chat(messages, system_prompt: nil)
        raise NotImplementedError, "#{self.class}#chat must be implemented"
      end

      def chat_with_tools(messages, tools:, system_prompt: nil)
        raise NotImplementedError, "#{self.class}#chat_with_tools must be implemented"
      end

      def format_assistant_message(_result)
        raise NotImplementedError, "#{self.class}#format_assistant_message must be implemented"
      end

      def format_tool_result(_tool_call_id, _result_string)
        raise NotImplementedError, "#{self.class}#format_tool_result must be implemented"
      end

      private

      # Read and connect timeouts are separate budgets. Establishing the TCP/TLS
      # connection either happens in a couple of seconds or is not going to, while
      # generation legitimately takes minutes with adaptive thinking and a large
      # output cap — sharing one value between them means either a connect timeout
      # that hangs or a read timeout that cuts off generation mid-stream. A cut-off
      # request loses the turn AND the tokens already spent producing it.
      def build_connection(url, headers = {})
        Faraday.new(url: url) do |f|
          f.options.timeout = config.respond_to?(:resolved_timeout) ? config.resolved_timeout : config.timeout
          f.options.open_timeout = config.respond_to?(:open_timeout) ? config.open_timeout : 10
          f.headers.update(headers)
          f.headers['Content-Type'] = 'application/json'
          f.adapter Faraday.default_adapter
        end
      end

      # Transient failures worth another attempt: rate limits, upstream overload,
      # and connections that never got established. Deliberately NOT retried:
      #
      # - Timeouts. A request that used its whole read budget is not obviously
      #   going to do better on a second try, and each retry both doubles the wait
      #   and pays again for a generation nobody will read. Raise instead, and say
      #   which knob to turn.
      # - 4xx other than 429. A malformed request stays malformed.
      RETRYABLE_STATUSES = [408, 409, 429, 500, 502, 503, 504, 529].freeze

      def with_retries
        max = config.respond_to?(:max_retries) ? config.max_retries.to_i : 2
        attempt = 0

        loop do
          response = nil
          reason = nil

          begin
            response = yield
          rescue Faraday::TimeoutError
            t = config.respond_to?(:resolved_timeout) ? config.resolved_timeout : config.timeout
            raise ProviderError,
              "Provider request timed out after #{t}s. Raise it with: " \
              "RailsConsoleAi.configure { |c| c.timeout = #{t * 2} }"
          rescue Faraday::ConnectionFailed, Faraday::SSLError => e
            raise ProviderError, "Could not reach the provider: #{e.message}" if attempt >= max

            reason = e.class.name
          end

          if response
            return response if response.success?
            return response unless RETRYABLE_STATUSES.include?(response.status)
            return response if attempt >= max

            reason = "HTTP #{response.status}"
          end

          delay = retry_delay(response, attempt)
          RailsConsoleAi.logger.warn(
            "RailsConsoleAi: #{reason} from provider, retrying in #{'%.1f' % delay}s " \
            "(attempt #{attempt + 1} of #{max})"
          )
          sleep(delay)
          attempt += 1
        end
      end

      # Honour Retry-After when the server sends one; otherwise exponential backoff
      # with jitter, so concurrent sessions don't retry in lockstep.
      def retry_delay(response, attempt)
        header = response && (response.headers['retry-after'] || response.headers['Retry-After'])
        if header && header.to_f > 0
          [header.to_f, 60.0].min
        else
          (2**attempt) + rand
        end
      end

      def debug_request(url, body)
        return unless config.debug

        parsed = body.is_a?(String) ? (JSON.parse(body) rescue nil) : body
        if parsed
          # Support both symbol and string keys
          model = parsed[:model] || parsed['model']
          msgs = parsed[:messages] || parsed['messages']
          sys = parsed[:system] || parsed['system']
          tools = parsed[:tools] || parsed['tools']
          $stderr.puts "\e[33m[debug] POST #{url} | model: #{model} | #{msgs&.length || 0} msgs | system: #{sys.to_s.length} chars | #{tools&.length || 0} tools\e[0m"
        else
          $stderr.puts "\e[33m[debug] POST #{url}\e[0m"
        end
      end

      def debug_response(body)
        return unless config.debug

        parsed = body.is_a?(String) ? (JSON.parse(body) rescue nil) : body
        if parsed && parsed['usage']
          u = parsed['usage']
          $stderr.puts "\e[36m[debug] response: #{parsed['stop_reason']} | in: #{u['input_tokens']} out: #{u['output_tokens']}\e[0m"
        end
      end

      def parse_response(response)
        unless response.success?
          body = begin
                   JSON.parse(response.body)
                 rescue
                   { 'error' => response.body }
                 end
          error_msg = body.dig('error', 'message') || body['error'] || response.body
          raise ProviderError, "API error (#{response.status}): #{error_msg}"
        end

        JSON.parse(response.body)
      rescue JSON::ParserError => e
        raise ProviderError, "Failed to parse response: #{e.message}"
      end
    end

    class ProviderError < StandardError; end

    ChatResult = Struct.new(:text, :input_tokens, :output_tokens, :tool_calls, :stop_reason,
                            :cache_read_input_tokens, :cache_write_input_tokens, :cost, keyword_init: true) do
      def total_tokens
        (input_tokens || 0) + (output_tokens || 0)
      end

      def tool_use?
        stop_reason == :tool_use && tool_calls && !tool_calls.empty?
      end
    end

    def self.build(config = RailsConsoleAi.configuration)
      case config.provider
      when :anthropic
        require 'rails_console_ai/providers/anthropic'
        Anthropic.new(config)
      when :openai
        require 'rails_console_ai/providers/openai'
        OpenAI.new(config)
      when :openrouter
        require 'rails_console_ai/providers/openai'
        require 'rails_console_ai/providers/openrouter'
        OpenRouter.new(config)
      when :local
        require 'rails_console_ai/providers/openai'
        require 'rails_console_ai/providers/local'
        Local.new(config)
      when :bedrock
        require 'rails_console_ai/providers/bedrock'
        Bedrock.new(config)
      else
        raise ConfigurationError, "Unknown provider: #{config.provider}"
      end
    end
  end
end
