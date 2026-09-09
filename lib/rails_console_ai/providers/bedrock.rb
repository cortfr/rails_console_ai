module RailsConsoleAi
  module Providers
    class Bedrock < Base
      def chat(messages, system_prompt: nil)
        call_api(messages, system_prompt: system_prompt)
      end

      def chat_with_tools(messages, tools:, system_prompt: nil)
        call_api(messages, system_prompt: system_prompt, tools: tools)
      end

      def format_assistant_message(result)
        content = []
        content << { text: result.text } if result.text && !result.text.empty?
        (result.tool_calls || []).each do |tc|
          content << {
            tool_use: {
              tool_use_id: tc[:id],
              name: tc[:name],
              input: tc[:arguments]
            }
          }
        end
        { role: 'assistant', content: content }
      end

      def format_tool_result(tool_call_id, result_string)
        {
          role: 'user',
          content: [
            {
              tool_result: {
                tool_use_id: tool_call_id,
                content: [{ text: result_string.to_s }]
              }
            }
          ]
        }
      end

      private

      def call_api(messages, system_prompt: nil, tools: nil)
        inference = { max_tokens: config.resolved_max_tokens }
        temp = config.resolved_temperature
        inference[:temperature] = temp unless temp.nil?
        params = {
          model_id: config.resolved_model,
          messages: mark_conversation_breakpoint(format_messages(messages)),
          inference_config: inference
        }
        if system_prompt
          sys_blocks = [{ text: system_prompt }]
          sys_blocks << cache_point if cache_supported?
          params[:system] = sys_blocks
        end
        if tools
          bedrock_tools = tools.to_bedrock_format
          bedrock_tools << cache_point if bedrock_tools.any? && cache_supported?
          params[:tool_config] = { tools: bedrock_tools }
        end

        debug_bedrock_request(params)
        response = client.converse(params)
        debug_bedrock_response(response)

        tool_calls = extract_tool_calls(response)
        stop = response.stop_reason == 'tool_use' ? :tool_use : :end_turn

        usage = response.usage
        ChatResult.new(
          text: extract_text(response),
          input_tokens: usage&.input_tokens,
          output_tokens: usage&.output_tokens,
          cache_read_input_tokens: usage.respond_to?(:cache_read_input_tokens) ? usage.cache_read_input_tokens : nil,
          cache_write_input_tokens: usage.respond_to?(:cache_write_input_tokens) ? usage.cache_write_input_tokens : nil,
          tool_calls: tool_calls,
          stop_reason: stop
        )
      rescue aws_error_class => e
        raise ProviderError, "AWS Bedrock error: #{e.message}"
      end

      def client
        @client ||= begin
          unless defined?(Aws::BedrockRuntime::Client)
            begin
              require 'aws-sdk-bedrockruntime'
            rescue LoadError
              raise ProviderError,
                "aws-sdk-bedrockruntime gem is required for the :bedrock provider. Add it to your Gemfile."
            end
          end
          client_opts = {}
          region = config.respond_to?(:bedrock_region) && config.bedrock_region
          client_opts[:region] = region if region && !region.empty?
          t = config.respond_to?(:resolved_timeout) ? config.resolved_timeout : config.timeout
          client_opts[:http_read_timeout] = t
          # Separate budget from generation time, same reasoning as
          # Providers::Base#build_connection. The AWS SDK does its own retrying of
          # throttling and 5xx, so there is no with_retries wrapper on this path.
          client_opts[:http_open_timeout] = config.open_timeout if config.respond_to?(:open_timeout)
          Aws::BedrockRuntime::Client.new(client_opts)
        end
      end

      def cache_supported?
        model = config.resolved_model
        model.include?('anthropic')
      end

      def aws_error_class
        if defined?(Aws::BedrockRuntime::Errors::ServiceError)
          Aws::BedrockRuntime::Errors::ServiceError
        else
          # Fallback if the gem isn't loaded yet (shouldn't happen after client init)
          StandardError
        end
      end

      def format_messages(messages)
        formatted = messages.map do |msg|
          content = if msg[:content].is_a?(Array)
                      msg[:content].dup
                    else
                      [{ text: msg[:content].to_s }]
                    end
          # Bedrock rejects empty or whitespace-only text blocks in content arrays
          content.reject! { |block| block.is_a?(Hash) && block.key?(:text) && !block.key?(:tool_use) && !block.key?(:tool_result) && block[:text].to_s.strip.empty? }
          # Bedrock also rejects messages with completely empty content arrays
          content << { text: '.' } if content.empty?
          { role: msg[:role].to_s, content: content }
        end

        # Bedrock requires all tool_result blocks for a single assistant turn
        # to be in one user message. Merge consecutive same-role messages.
        merged = []
        formatted.each do |msg|
          if merged.last && merged.last[:role] == msg[:role]
            merged.last[:content].concat(msg[:content])
          else
            merged << msg
          end
        end
        merged
      end

      # Converse takes a cache breakpoint as a content block. `ttl` is optional and
      # only present on newer aws-sdk-bedrockruntime versions — the SDK validates
      # params against its own struct and raises on an unknown member, so the
      # member is probed rather than assumed. Omitting it means the 5-minute
      # default, which is also what `cache_ttl = nil` asks for.
      def cache_point
        ttl = config.respond_to?(:resolved_cache_ttl) ? config.resolved_cache_ttl : nil
        return { cache_point: { type: 'default' } } unless ttl && cache_ttl_supported?

        { cache_point: { type: 'default', ttl: ttl } }
      end

      def cache_ttl_supported?
        return @cache_ttl_supported if defined?(@cache_ttl_supported)

        # The struct is only defined once aws-sdk-bedrockruntime is loaded, and
        # #client does that lazily. Probing first would fail-open to "no TTL" on
        # the first request of the process — silently, which is the failure mode
        # this whole change exists to avoid. #client is memoized and needed a few
        # lines later anyway.
        client

        @cache_ttl_supported =
          defined?(Aws::BedrockRuntime::Types::CachePointBlock) &&
          Aws::BedrockRuntime::Types::CachePointBlock.members.include?(:ttl)
      end

      # Same reasoning as Providers::Anthropic#mark_conversation_breakpoint: the
      # system/tools cache points only cover the static prefix, so without a cache
      # point in the conversation the accumulated history is re-billed at full
      # price on every round of a tool loop. `format_messages` has already duped
      # the content arrays, so appending is safe.
      def mark_conversation_breakpoint(formatted)
        return formatted unless cache_supported?
        return formatted if formatted.empty?

        formatted.last[:content] << cache_point
        formatted
      end

      def extract_text(response)
        content = response.output&.message&.content
        return '' unless content.is_a?(Array)

        content.select { |c| c.respond_to?(:text) && c.text }
               .map(&:text)
               .join("\n")
      end

      def extract_tool_calls(response)
        content = response.output&.message&.content
        return [] unless content.is_a?(Array)

        content.select { |c| c.respond_to?(:tool_use) && c.tool_use }
               .map do |c|
          tu = c.tool_use
          {
            id: tu.tool_use_id,
            name: tu.name,
            arguments: tu.input || {}
          }
        end
      end

      def debug_bedrock_request(params)
        return unless config.debug

        msg_count = params[:messages]&.length || 0
        sys_len = params.dig(:system, 0, :text).to_s.length
        tool_count = params.dig(:tool_config, :tools)&.length || 0
        $stderr.puts "\e[33m[debug] Bedrock converse | model: #{params[:model_id]} | #{msg_count} msgs | system: #{sys_len} chars | #{tool_count} tools\e[0m"
      end

      def debug_bedrock_response(response)
        return unless config.debug

        usage = response.usage
        if usage
          cache_r = usage.respond_to?(:cache_read_input_tokens) ? usage.cache_read_input_tokens : 'N/A'
          cache_w = usage.respond_to?(:cache_write_input_tokens) ? usage.cache_write_input_tokens : 'N/A'
          $stderr.puts "\e[36m[debug] response: #{response.stop_reason} | in: #{usage.input_tokens} out: #{usage.output_tokens} | cache_r: #{cache_r} cache_w: #{cache_w}\e[0m"
        end
      end
    end
  end
end
