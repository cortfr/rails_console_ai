module RailsConsoleAi
  module Providers
    class Local < OpenAI
      private

      def api_base
        config.local_url
      end

      def request_headers
        key = config.local_api_key
        return {} if key.nil? || key.empty? || key == 'no-key'
        { 'Authorization' => "Bearer #{key}" }
      end

      def build_result(data, body:, tools: nil)
        usage = data['usage'] || {}
        estimated_input_tokens = estimate_tokens(body)

        prompt_tokens = usage['prompt_tokens']
        if prompt_tokens && estimated_input_tokens > 0 && prompt_tokens < estimated_input_tokens * 0.5
          raise ProviderError,
            "Context truncated by local server: sent ~#{estimated_input_tokens} estimated tokens " \
            "but server only used #{prompt_tokens}. Increase the model's context window " \
            "(e.g. num_ctx for Ollama) or reduce conversation length."
        end

        choice = (data['choices'] || []).first || {}
        message = choice['message'] || {}
        finish_reason = choice['finish_reason']

        tool_calls = extract_tool_calls(message)

        if tool_calls.empty? && tools
          tool_names = tools.to_openai_format.map { |t| t.dig('function', 'name') }.compact
          text_calls = extract_tool_calls_from_text(message['content'], tool_names)
          if text_calls.any?
            tool_calls = text_calls
            finish_reason = 'tool_calls'
            message['content'] = ''
          end
        end

        stop = finish_reason == 'tool_calls' ? :tool_use : :end_turn

        ChatResult.new(
          text: message['content'] || '',
          input_tokens: usage['prompt_tokens'],
          output_tokens: usage['completion_tokens'],
          tool_calls: tool_calls,
          stop_reason: stop
        )
      end

      def estimate_tokens(body)
        chars = 0
        (body[:messages] || []).each do |m|
          chars += m[:content].to_s.length + (m[:tool_calls].to_s.length)
        end
        chars += body[:tools].to_s.length if body[:tools]
        chars / 4
      end

      # Parse tool calls emitted as JSON text in the content field.
      # Only recognizes calls whose "name" matches a known tool name.
      def extract_tool_calls_from_text(content, tool_names)
        return [] if content.nil? || content.strip.empty?

        text = content.strip
        parsed = begin
                   JSON.parse(text)
                 rescue JSON::ParserError
                   match = text.match(/```(?:json)?\s*(\{[\s\S]*?\}|\[[\s\S]*?\])\s*```/)
                   match ? (JSON.parse(match[1]) rescue nil) : nil
                 end

        return [] unless parsed

        calls = parsed.is_a?(Array) ? parsed : [parsed]
        calls.filter_map do |call|
          next unless call.is_a?(Hash) && tool_names.include?(call['name'])
          {
            id: "local_#{SecureRandom.hex(4)}",
            name: call['name'],
            arguments: call['arguments'] || {}
          }
        end
      rescue
        []
      end
    end
  end
end
