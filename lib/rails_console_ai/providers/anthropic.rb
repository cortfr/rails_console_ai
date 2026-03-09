module RailsConsoleAi
  module Providers
    class Anthropic < Base
      API_URL = 'https://api.anthropic.com'.freeze

      def chat(messages, system_prompt: nil)
        result = call_api(messages, system_prompt: system_prompt)
        result
      end

      def chat_with_tools(messages, tools:, system_prompt: nil)
        call_api(messages, system_prompt: system_prompt, tools: tools)
      end

      def format_assistant_message(result)
        # Rebuild the assistant content blocks from the raw response
        content_blocks = []
        content_blocks << { 'type' => 'text', 'text' => result.text } if result.text && !result.text.empty?
        (result.tool_calls || []).each do |tc|
          content_blocks << {
            'type' => 'tool_use',
            'id' => tc[:id],
            'name' => tc[:name],
            'input' => tc[:arguments]
          }
        end
        { role: 'assistant', content: content_blocks }
      end

      def format_tool_result(tool_call_id, result_string)
        {
          role: 'user',
          content: [
            {
              'type' => 'tool_result',
              'tool_use_id' => tool_call_id,
              'content' => result_string.to_s
            }
          ]
        }
      end

      private

      def call_api(messages, system_prompt: nil, tools: nil)
        conn = build_connection(API_URL, {
          'x-api-key' => config.resolved_api_key,
          'anthropic-version' => '2023-06-01'
        })

        body = {
          model: config.resolved_model,
          max_tokens: config.resolved_max_tokens,
          temperature: config.temperature,
          messages: format_messages(messages)
        }
        if system_prompt
          body[:system] = [
            { 'type' => 'text', 'text' => system_prompt, 'cache_control' => { 'type' => 'ephemeral' } }
          ]
        end
        if tools
          anthropic_tools = tools.to_anthropic_format
          anthropic_tools.last['cache_control'] = { 'type' => 'ephemeral' } if anthropic_tools.any?
          body[:tools] = anthropic_tools
        end

        json_body = JSON.generate(body)
        debug_request("#{API_URL}/v1/messages", body)
        response = conn.post('/v1/messages', json_body)
        debug_response(response.body)
        data = parse_response(response)
        usage = data['usage'] || {}

        tool_calls = extract_tool_calls(data)
        stop = data['stop_reason'] == 'tool_use' ? :tool_use : :end_turn

        ChatResult.new(
          text: extract_text(data),
          input_tokens: usage['input_tokens'],
          output_tokens: usage['output_tokens'],
          cache_read_input_tokens: usage['cache_read_input_tokens'],
          cache_write_input_tokens: usage['cache_creation_input_tokens'],
          tool_calls: tool_calls,
          stop_reason: stop
        )
      end

      def format_messages(messages)
        messages.map do |msg|
          if msg[:content].is_a?(Array)
            { role: msg[:role].to_s, content: msg[:content] }
          else
            { role: msg[:role].to_s, content: msg[:content].to_s }
          end
        end
      end

      def extract_text(data)
        content = data['content']
        return '' unless content.is_a?(Array)

        content.select { |c| c['type'] == 'text' }
               .map { |c| c['text'] }
               .join("\n")
      end

      def extract_tool_calls(data)
        content = data['content']
        return [] unless content.is_a?(Array)

        content.select { |c| c['type'] == 'tool_use' }.map do |c|
          {
            id: c['id'],
            name: c['name'],
            arguments: c['input'] || {}
          }
        end
      end
    end
  end
end
