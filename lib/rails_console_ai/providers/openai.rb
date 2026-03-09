module RailsConsoleAi
  module Providers
    class OpenAI < Base
      API_URL = 'https://api.openai.com'.freeze

      def chat(messages, system_prompt: nil)
        call_api(messages, system_prompt: system_prompt)
      end

      def chat_with_tools(messages, tools:, system_prompt: nil)
        call_api(messages, system_prompt: system_prompt, tools: tools)
      end

      def format_assistant_message(result)
        msg = { role: 'assistant' }
        msg[:content] = result.text if result.text && !result.text.empty?
        if result.tool_calls && !result.tool_calls.empty?
          msg[:tool_calls] = result.tool_calls.map do |tc|
            {
              'id' => tc[:id],
              'type' => 'function',
              'function' => {
                'name' => tc[:name],
                'arguments' => JSON.generate(tc[:arguments] || {})
              }
            }
          end
        end
        msg
      end

      def format_tool_result(tool_call_id, result_string)
        {
          role: 'tool',
          tool_call_id: tool_call_id,
          content: result_string.to_s
        }
      end

      private

      def call_api(messages, system_prompt: nil, tools: nil)
        conn = build_connection(API_URL, {
          'Authorization' => "Bearer #{config.resolved_api_key}"
        })

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

        json_body = JSON.generate(body)
        debug_request("#{API_URL}/v1/chat/completions", body)
        response = conn.post('/v1/chat/completions', json_body)
        debug_response(response.body)
        data = parse_response(response)
        usage = data['usage'] || {}

        choice = (data['choices'] || []).first || {}
        message = choice['message'] || {}
        finish_reason = choice['finish_reason']

        tool_calls = extract_tool_calls(message)
        stop = finish_reason == 'tool_calls' ? :tool_use : :end_turn

        ChatResult.new(
          text: message['content'] || '',
          input_tokens: usage['prompt_tokens'],
          output_tokens: usage['completion_tokens'],
          tool_calls: tool_calls,
          stop_reason: stop
        )
      end

      def format_messages(messages)
        messages.map do |msg|
          base = { role: msg[:role].to_s }
          if msg[:content]
            base[:content] = msg[:content].is_a?(Array) ? JSON.generate(msg[:content]) : msg[:content].to_s
          end
          base[:tool_calls] = msg[:tool_calls] if msg[:tool_calls]
          base[:tool_call_id] = msg[:tool_call_id] if msg[:tool_call_id]
          base
        end
      end

      def extract_tool_calls(message)
        calls = message['tool_calls']
        return [] unless calls.is_a?(Array)

        calls.map do |tc|
          func = tc['function'] || {}
          args = begin
                   JSON.parse(func['arguments'] || '{}')
                 rescue
                   {}
                 end
          {
            id: tc['id'],
            name: func['name'],
            arguments: args
          }
        end
      end
    end
  end
end
