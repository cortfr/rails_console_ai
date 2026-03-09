module RailsConsoleAi
  module Providers
    class Local < OpenAI
      private

      def call_api(messages, system_prompt: nil, tools: nil)
        base_url = config.local_url

        headers = { 'Content-Type' => 'application/json' }
        api_key = config.local_api_key
        if api_key && api_key != 'no-key' && !api_key.empty?
          headers['Authorization'] = "Bearer #{api_key}"
        end

        conn = build_connection(base_url, headers)

        formatted = []
        formatted << { role: 'system', content: system_prompt } if system_prompt
        formatted.concat(format_messages(messages))

        body = {
          model: config.resolved_model,
          max_tokens: config.resolved_max_tokens,
          temperature: config.temperature,
          messages: formatted
        }
        body[:tools] = tools.to_openai_format if tools

        estimated_input_tokens = estimate_tokens(formatted, system_prompt, tools)

        json_body = JSON.generate(body)
        debug_request("#{base_url}/v1/chat/completions", body)
        response = conn.post('/v1/chat/completions', json_body)
        debug_response(response.body)
        data = parse_response(response)
        usage = data['usage'] || {}

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

        # Fallback: some local models (e.g. Ollama) emit tool calls as JSON
        # in the content field instead of using the structured tool_calls format.
        # Only match when the JSON "name" is a known tool name to avoid false positives.
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

      def estimate_tokens(messages, system_prompt, tools)
        chars = system_prompt.to_s.length
        messages.each { |m| chars += m[:content].to_s.length + (m[:tool_calls].to_s.length) }
        chars += tools.to_openai_format.to_s.length if tools
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
