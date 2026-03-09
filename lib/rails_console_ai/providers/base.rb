require 'faraday'
require 'json'

module RailsConsoleAi
  module Providers
    class Base
      attr_reader :config

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

      def build_connection(url, headers = {})
        Faraday.new(url: url) do |f|
          t = config.respond_to?(:resolved_timeout) ? config.resolved_timeout : config.timeout
          f.options.timeout = t
          f.options.open_timeout = t
          f.headers.update(headers)
          f.headers['Content-Type'] = 'application/json'
          f.adapter Faraday.default_adapter
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
                            :cache_read_input_tokens, :cache_write_input_tokens, keyword_init: true) do
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
