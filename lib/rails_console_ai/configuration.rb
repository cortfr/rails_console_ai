module RailsConsoleAi
  class Configuration
    PROVIDERS = %i[anthropic openai local bedrock].freeze

    # Per-family model attributes, matched by substring so one entry covers every
    # ID variant of a family: bare Anthropic IDs (claude-sonnet-5), dated
    # snapshots (claude-haiku-4-5-20251001), and Bedrock inference profiles
    # (us.anthropic.claude-sonnet-5, global.anthropic.claude-opus-4-6-v1).
    #
    # input/output are $ per MTok (converted to per-token in .pricing_for).
    # Cache pricing is derived: read = 0.1x input, write = 1.25x input.
    # temperature: false marks families that reject the `temperature` parameter
    # (removed on opus-4-7+, sonnet-5, and fable-5).
    MODEL_FAMILIES = {
      'claude-fable-5'    => { input: 10.0, output: 50.0, max_tokens: 16_000, temperature: false },
      'claude-opus-5'     => { input: 5.0,  output: 25.0, max_tokens: 16_000, temperature: false },
      'claude-opus-4-8'   => { input: 5.0,  output: 25.0, max_tokens: 16_000, temperature: false },
      'claude-opus-4-7'   => { input: 5.0,  output: 25.0, max_tokens: 16_000, temperature: false },
      'claude-opus-4-6'   => { input: 5.0,  output: 25.0, max_tokens: 16_000, temperature: true },
      'claude-sonnet-5'   => { input: 3.0,  output: 15.0, max_tokens: 16_000, temperature: false },
      'claude-sonnet-4-6' => { input: 3.0,  output: 15.0, max_tokens: 16_000, temperature: true },
      'claude-haiku-4-5'  => { input: 1.0,  output: 5.0,  max_tokens: 16_000, temperature: true },
    }.freeze

    # Family keys sorted longest-first so a more specific family always wins
    # if keys ever overlap (e.g. a future 'claude-sonnet-5-5' entry would match
    # before 'claude-sonnet-5').
    MODEL_FAMILY_KEYS = MODEL_FAMILIES.keys.sort_by { |k| -k.length }.freeze

    # Returns the family attributes for a model ID, or nil for unknown models.
    def self.model_family(model_id)
      return nil unless model_id
      key = MODEL_FAMILY_KEYS.find { |k| model_id.include?(k) }
      key && MODEL_FAMILIES[key]
    end

    # Per-token pricing for a model ID, matched by family. Returns
    # { input:, output:, cache_read:, cache_write: } or nil for unknown models.
    def self.pricing_for(model_id)
      family = model_family(model_id)
      return nil unless family
      input = family[:input] / 1_000_000
      {
        input: input,
        output: family[:output] / 1_000_000,
        cache_read: input * 0.1,
        cache_write: input * 1.25,
      }
    end

    # Known environment-level failures the executor recognizes and explains to the
    # LLM on the FIRST occurrence, so it doesn't burn rounds rediscovering them
    # through trial and error. Each entry: { name:, pattern:, hint: }.
    # The pattern is matched against the execution error AND the captured output
    # (to catch errors rescued and printed by the generated code itself).
    DEFAULT_ERROR_HINTS = [
      {
        name: :decryption_failure,
        pattern: /OpenSSL::Cipher::CipherError|bad decrypt|ActiveRecord::Encryption::Errors/i,
        hint: "Decryption failed — this console process's encryption key (e.g. ENV['ENCRYPTION_KEY']) " \
              "appears to be missing, invalid, or a placeholder for the data you are reading. This is an " \
              "environment configuration issue, not a data issue, and it affects EVERY encrypted field in " \
              "this session. Retrying with different code (reloading records, toggling encryption flags, " \
              "decrypting other fields or records) will fail the same way. Do NOT retry. Report this " \
              "limitation to the user, tell them the encryption key needs to be configured for this " \
              "environment, and answer using only what you can determine without decrypting."
      }
    ].freeze

    attr_accessor :provider, :api_key, :model, :thinking_model, :max_tokens,
                  :auto_execute, :temperature,
                  :timeout, :debug, :max_tool_rounds,
                  :error_hints,
                  :token_nudge_threshold, :token_stop_threshold,
                  :storage_adapter, :memories_enabled,
                  :session_logging, :connection_class,
                  :admin_username, :admin_password,
                  :authenticate,
                  :slack_bot_token, :slack_app_token, :slack_channel_ids, :slack_allowed_usernames,
                  :local_url, :local_model, :local_api_key,
                  :bedrock_region,
                  :code_search_paths,
                  :channels,
                  :bypass_guards_for_methods,
                  :user_extra_info,
                  :sub_agent_max_rounds,
                  :sub_agent_model

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
      @error_hints = DEFAULT_ERROR_HINTS.dup
      @token_nudge_threshold = 500_000    # input tokens in one tool loop → nudge model to wrap up (nil disables)
      @token_stop_threshold  = 1_000_000  # input tokens in one tool loop → force a final answer (nil disables)
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
      @code_search_paths = %w[app]
      @channels = {}
      @bypass_guards_for_methods = []
      @user_extra_info = {}
      @sub_agent_max_rounds = 15
      @sub_agent_model = nil
    end

    def resolve_user_extra_info(username)
      return nil if @user_extra_info.nil? || @user_extra_info.empty? || username.nil?
      @user_extra_info[username.to_s.downcase]
    end

    # Look up a per-channel setting with backward compatibility.
    # Falls back to top-level slack_* config when channels hash doesn't have the key.
    def channel_setting(mode, key)
      channel_cfg = @channels[mode.to_s] || {}
      value = channel_cfg[key.to_s]

      # Backward compatibility: slack_allowed_usernames → channels.slack.allowed_usernames
      if value.nil? && mode.to_s == 'slack' && key.to_s == 'allowed_usernames'
        value = @slack_allowed_usernames
      end

      value
    end

    # Check if a username is permitted by a channel setting.
    # Returns true when the setting is nil (not configured = no restriction).
    def username_allowed?(mode, key, username)
      list = channel_setting(mode, key)
      return true if list.nil?
      normalized = Array(list).map(&:to_s).map(&:downcase)
      normalized.include?('all') || normalized.include?(username.to_s.downcase)
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
    # Available: :database_writes, :http_mutations, :mailers, :in_process_requests
    #
    # Options:
    #   allow: Array of strings or regexps to allowlist for this guard.
    #     - :http_mutations      → hosts (e.g. "s3.amazonaws.com", /googleapis\.com/)
    #     - :database_writes     → table names (e.g. "rails_console_ai_sessions")
    #     - :in_process_requests → request paths (e.g. "/health")
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
      when :in_process_requests
        safety_guards.add(:in_process_requests, &BuiltinGuards.in_process_requests)
      else
        raise ConfigurationError, "Unknown built-in safety guard: #{name}. Available: database_writes, http_mutations, mailers, in_process_requests"
      end

      if allow
        Array(allow).each { |key| safety_guards.allow_global(guard_name, key) }
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
        'claude-sonnet-5'
      when :openai
        'gpt-5.3-codex'
      when :local
        @local_model
      when :bedrock
        'us.anthropic.claude-sonnet-5'
      end
    end

    def resolved_max_tokens
      return @max_tokens if @max_tokens

      family = self.class.model_family(resolved_model)
      family ? family[:max_tokens] : 4096
    end

    # Returns nil for model families that reject the `temperature` parameter
    # (opus-4-7+, sonnet-5, fable-5) so providers omit the field from the request.
    def resolved_temperature
      family = self.class.model_family(resolved_model)
      return nil if family && family[:temperature] == false
      @temperature
    end

    def resolved_thinking_model
      return @thinking_model if @thinking_model && !@thinking_model.empty?

      case @provider
      when :anthropic
        'claude-opus-5'
      when :openai
        'gpt-5.3-codex'
      when :local
        @local_model
      when :bedrock
        'us.anthropic.claude-opus-5'
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
