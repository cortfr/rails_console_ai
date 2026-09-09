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
        # Root-level cache_control is OpenRouter's automatic mode: it places a
        # breakpoint on the last cacheable block and moves it forward as the
        # conversation grows, which is what a tool loop needs — otherwise every
        # round re-bills the whole accumulated history at full input price.
        body[:cache_control] = cache_control if cache_supported?
        body[:session_id] = routing_session_id if routing_session_id
        body
      end

      # The static system prefix gets its own explicit breakpoint so it has a
      # guaranteed read point no matter what happens later in `messages`; the
      # automatic breakpoint above then covers the growing tail. OpenRouter
      # expresses Anthropic breakpoints as OpenAI-style multipart content.
      def system_message(system_prompt)
        return super unless cache_supported?

        { role: 'system',
          content: [{ type: 'text', text: system_prompt, cache_control: cache_control }] }
      end

      # Same TTL on every breakpoint: entries with the longer TTL must precede
      # shorter ones, and an explicit marker whose TTL differs from the root-level
      # field's is rejected outright.
      def cache_control
        ttl = config.respond_to?(:resolved_cache_ttl) ? config.resolved_cache_ttl : nil
        ttl ? { type: 'ephemeral', ttl: ttl } : { type: 'ephemeral' }
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
