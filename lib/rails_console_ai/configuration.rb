module RailsConsoleAi
  class Configuration
    PROVIDERS = %i[anthropic openai local bedrock].freeze

    # cache_read: 0.1x input, cache_write: 1.25x input for Anthropic models
    PRICING = {
      'claude-sonnet-4-6' => { input: 3.0 / 1_000_000, output: 15.0 / 1_000_000, cache_read: 0.30 / 1_000_000, cache_write: 3.75 / 1_000_000 },
      'claude-opus-4-6'   => { input: 15.0 / 1_000_000, output: 75.0 / 1_000_000, cache_read: 1.50 / 1_000_000, cache_write: 18.75 / 1_000_000 },
      'claude-haiku-4-5-20251001' => { input: 0.80 / 1_000_000, output: 4.0 / 1_000_000, cache_read: 0.08 / 1_000_000, cache_write: 1.0 / 1_000_000 },
      # Bedrock model IDs (same pricing as direct API)
      'us.anthropic.claude-sonnet-4-6' => { input: 3.0 / 1_000_000, output: 15.0 / 1_000_000, cache_read: 0.30 / 1_000_000, cache_write: 3.75 / 1_000_000 },
      'us.anthropic.claude-opus-4-6-v1' => { input: 15.0 / 1_000_000, output: 75.0 / 1_000_000, cache_read: 1.50 / 1_000_000, cache_write: 18.75 / 1_000_000 },
    }.freeze

    DEFAULT_MAX_TOKENS = {
      'claude-sonnet-4-6' => 16_000,
      'claude-haiku-4-5-20251001' => 16_000,
      'claude-opus-4-6'   => 4_096,
    }.freeze

    attr_accessor :provider, :api_key, :model, :thinking_model, :max_tokens,
                  :auto_execute, :temperature,
                  :timeout, :debug, :max_tool_rounds,
                  :storage_adapter, :memories_enabled,
                  :session_logging, :connection_class,
                  :admin_username, :admin_password,
                  :authenticate,
                  :slack_bot_token, :slack_app_token, :slack_channel_ids, :slack_allowed_usernames,
                  :local_url, :local_model, :local_api_key,
                  :bedrock_region

    def initialize
      @provider     = :anthropic
      @api_key      = nil
      @model        = nil
      @thinking_model = nil
      @max_tokens   = nil
      @auto_execute = false
      @temperature  = 0.2
      @timeout      = 30
      @debug        = false
      @max_tool_rounds = 200
      @storage_adapter  = nil
      @memories_enabled = true
      @session_logging  = true
      @connection_class = nil
      @admin_username   = nil
      @admin_password   = nil
      @authenticate     = nil
      @safety_guards    = nil
      @slack_bot_token  = nil
      @slack_app_token  = nil
      @slack_channel_ids = nil
      @slack_allowed_usernames = nil
      @local_url        = 'http://localhost:11434'
      @local_model      = 'qwen2.5:7b'
      @local_api_key    = nil
      @bedrock_region   = nil
    end

    def safety_guards
      @safety_guards ||= begin
        require 'rails_console_ai/safety_guards'
        SafetyGuards.new
      end
    end

    # Register a custom safety guard by name with an around-block.
    #
    #   config.safety_guard :mailers do |&execute|
    #     ActionMailer::Base.perform_deliveries = false
    #     execute.call
    #   ensure
    #     ActionMailer::Base.perform_deliveries = true
    #   end
    def safety_guard(name, &block)
      safety_guards.add(name, &block)
    end

    # Register a built-in safety guard by name.
    # Available: :database_writes, :http_mutations, :mailers
    #
    # Options:
    #   allow: Array of strings or regexps to allowlist for this guard.
    #     - :http_mutations  → hosts (e.g. "s3.amazonaws.com", /googleapis\.com/)
    #     - :database_writes → table names (e.g. "rails_console_ai_sessions")
    def use_builtin_safety_guard(name, allow: nil)
      require 'rails_console_ai/safety_guards'
      guard_name = name.to_sym
      case guard_name
      when :database_writes
        safety_guards.add(:database_writes, &BuiltinGuards.database_writes)
      when :http_mutations
        safety_guards.add(:http_mutations, &BuiltinGuards.http_mutations)
      when :mailers
        safety_guards.add(:mailers, &BuiltinGuards.mailers)
      else
        raise ConfigurationError, "Unknown built-in safety guard: #{name}. Available: database_writes, http_mutations, mailers"
      end

      if allow
        Array(allow).each { |key| safety_guards.allow(guard_name, key) }
      end
    end

    def resolved_api_key
      return @api_key if @api_key && !@api_key.empty?

      case @provider
      when :anthropic
        ENV['ANTHROPIC_API_KEY']
      when :openai
        ENV['OPENAI_API_KEY']
      when :local
        @local_api_key || 'no-key'
      when :bedrock
        'aws-sdk'
      end
    end

    def resolved_model
      return @model if @model && !@model.empty?

      case @provider
      when :anthropic
        'claude-sonnet-4-6'
      when :openai
        'gpt-5.3-codex'
      when :local
        @local_model
      when :bedrock
        'us.anthropic.claude-sonnet-4-6'
      end
    end

    def resolved_max_tokens
      return @max_tokens if @max_tokens

      DEFAULT_MAX_TOKENS.fetch(resolved_model, 4096)
    end

    def resolved_thinking_model
      return @thinking_model if @thinking_model && !@thinking_model.empty?

      case @provider
      when :anthropic
        'claude-opus-4-6'
      when :openai
        'gpt-5.3-codex'
      when :local
        @local_model
      when :bedrock
        'us.anthropic.claude-opus-4-6-v1'
      end
    end

    def resolved_timeout
      @provider == :local ? [@timeout, 300].max : @timeout
    end

    def validate!
      unless PROVIDERS.include?(@provider)
        raise ConfigurationError, "Unknown provider: #{@provider}. Valid: #{PROVIDERS.join(', ')}"
      end

      if @provider == :local
        raise ConfigurationError, "No local_url configured for :local provider." unless @local_url && !@local_url.empty?
      elsif @provider == :bedrock
        begin
          require 'aws-sdk-bedrockruntime'
        rescue LoadError
          raise ConfigurationError,
            "aws-sdk-bedrockruntime gem is required for the :bedrock provider. Add it to your Gemfile."
        end
      else
        unless resolved_api_key
          env_var = @provider == :anthropic ? 'ANTHROPIC_API_KEY' : 'OPENAI_API_KEY'
          raise ConfigurationError, "No API key. Set config.api_key or #{env_var} env var."
        end
      end
    end
  end

  class ConfigurationError < StandardError; end
end
