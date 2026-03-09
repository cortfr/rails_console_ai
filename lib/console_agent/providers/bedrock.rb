module ConsoleAgent
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
        params = {
          model_id: config.resolved_model,
          messages: format_messages(messages),
          inference_config: {
            max_tokens: config.resolved_max_tokens,
            temperature: config.temperature
          }
        }
        if system_prompt
          sys_blocks = [{ text: system_prompt }]
          sys_blocks << { cache_point: { type: 'default' } } if cache_supported?
          params[:system] = sys_blocks
        end
        if tools
          bedrock_tools = tools.to_bedrock_format
          bedrock_tools << { cache_point: { type: 'default' } } if bedrock_tools.any? && cache_supported?
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
          cache_read_input_tokens: usage.respond_to?(:cache_read_input_token_count) ? usage.cache_read_input_token_count : nil,
          cache_write_input_tokens: usage.respond_to?(:cache_write_input_token_count) ? usage.cache_write_input_token_count : nil,
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
        messages.map do |msg|
          content = if msg[:content].is_a?(Array)
                      msg[:content]
                    else
                      [{ text: msg[:content].to_s }]
                    end
          { role: msg[:role].to_s, content: content }
        end
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
          $stderr.puts "\e[36m[debug] response: #{response.stop_reason} | in: #{usage.input_tokens} out: #{usage.output_tokens}\e[0m"
        end
      end
    end
  end
end
