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
          messages: mark_conversation_breakpoint(format_messages(messages))
        }
        temp = config.resolved_temperature
        body[:temperature] = temp unless temp.nil?
        if system_prompt
          body[:system] = [
            { 'type' => 'text', 'text' => system_prompt, 'cache_control' => cache_control }
          ]
        end
        if tools
          anthropic_tools = tools.to_anthropic_format
          anthropic_tools.last['cache_control'] = cache_control if anthropic_tools.any?
          body[:tools] = anthropic_tools
        end

        json_body = JSON.generate(body)
        debug_request("#{API_URL}/v1/messages", body)
        response = with_retries { conn.post('/v1/messages', json_body) }
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

      # Text content is always rendered as a one-element block array, even though
      # the API accepts a bare string. The breakpoint below can only be attached
      # to a block, so a string tail would have to be promoted to a block — and
      # then rendered back as a string on the next request, once it is no longer
      # the tail. That byte-level flip-flop would break the prefix at exactly the
      # message the next request needs to read from cache. Rendering one shape
      # always keeps the prefix stable.
      #
      # Empty content is left alone: an empty text block is rejected outright.
      def format_messages(messages)
        messages.map do |msg|
          content = msg[:content]
          content =
            if content.is_a?(Array) || content.to_s.strip.empty?
              content
            else
              [{ 'type' => 'text', 'text' => content.to_s }]
            end
          { role: msg[:role].to_s, content: content }
        end
      end

      def cache_control
        ttl = config.respond_to?(:resolved_cache_ttl) ? config.resolved_cache_ttl : nil
        ttl ? { 'type' => 'ephemeral', 'ttl' => ttl } : { 'type' => 'ephemeral' }
      end

      # Caching `tools` and `system` only covers the static prefix. Every round of
      # a tool loop resends the whole accumulated conversation, so without a
      # breakpoint in `messages` the history — which is nearly all of the tokens —
      # is re-billed at full input price every round, and a task's cost grows with
      # roughly the square of its round count.
      #
      # The breakpoint moves to the end of the array on every request. Breakpoints
      # written by earlier requests stay valid read points, so each round reads
      # everything accumulated so far at ~0.1x and writes only what the last round
      # added. Blocks are duped before marking: `format_messages` passes content
      # arrays through by reference and they belong to the caller's history.
      def mark_conversation_breakpoint(formatted)
        return formatted if formatted.empty?

        last = formatted.last
        # Anything not already a block array is empty content (see #format_messages)
        # — nothing to cache there.
        return formatted unless last[:content].is_a?(Array)

        blocks = last[:content].map { |b| b.is_a?(Hash) ? b.dup : b }
        target = blocks.last
        return formatted unless target.is_a?(Hash)
        target['cache_control'] = cache_control

        formatted[0..-2] + [last.merge(content: blocks)]
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
