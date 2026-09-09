module RailsConsoleAi
  module Providers
    class OpenRouter < OpenAI
      DEFAULT_URL = 'https://openrouter.ai'.freeze
      ANTHROPIC_MODEL = /anthropic\/|claude/i

      private

      def api_base
        config.openrouter_url || DEFAULT_URL
      end

      def endpoint_path
        '/api/v1/chat/completions'
      end

      def request_headers
        h = { 'Authorization' => "Bearer #{config.resolved_api_key}" }
        h['HTTP-Referer'] = config.openrouter_site_url if config.openrouter_site_url
        h['X-Title'] = config.openrouter_app_name if config.openrouter_app_name
        h
      end

      def build_body(messages, system_prompt:, tools:)
        body = super
        body[:cache_control] = { type: 'ephemeral' } if cache_supported?
        body[:session_id] = routing_session_id if routing_session_id
        body
      end

      def build_result(data, body:, tools: nil)
        raise_inline_error!(data)
        result = super
        usage = data['usage'] || {}
        details = usage['prompt_tokens_details'] || {}

        result.cache_read_input_tokens = details['cached_tokens']
        result.cache_write_input_tokens = details['cache_write_tokens']
        result.cost = usage['cost']

        if result.tool_calls&.any?
          result.stop_reason = :tool_use
        end

        result
      end

      def cache_supported?
        config.resolved_model.to_s.match?(ANTHROPIC_MODEL)
      end

      def raise_inline_error!(data)
        err = data['error'] || (data['choices'] || []).first&.dig('error')
        return unless err

        msg = err.is_a?(Hash) ? (err['message'] || err.to_s) : err.to_s
        code = err.is_a?(Hash) ? err['code'] : 'unknown'
        raise ProviderError, "OpenRouter error (#{code}): #{msg}"
      end
    end
  end
end
