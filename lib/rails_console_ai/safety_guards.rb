module RailsConsoleAi
  # Raised by safety guards to block dangerous operations.
  # Host apps should raise this error in their custom guards.
  # RailsConsoleAi will catch it and guide the user to use 'd' or /danger.
  class SafetyError < StandardError
    attr_reader :guard, :blocked_key

    def initialize(message, guard: nil, blocked_key: nil)
      super(message)
      @guard = guard
      @blocked_key = blocked_key
    end
  end

  class SafetyGuards
    attr_reader :guards

    def initialize
      @guards = {}
      @enabled = true
      @allowlist = {}  # { guard_name => [String or Regexp, ...] }
    end

    def add(name, &block)
      @guards[name.to_sym] = block
    end

    def remove(name)
      @guards.delete(name.to_sym)
    end

    def enabled?
      @enabled
    end

    def enable!
      @enabled = true
    end

    def disable!
      @enabled = false
    end

    def empty?
      @guards.empty?
    end

    def names
      @guards.keys
    end

    def allow(guard_name, key)
      guard_name = guard_name.to_sym
      @allowlist[guard_name] ||= []
      @allowlist[guard_name] << key unless @allowlist[guard_name].include?(key)
    end

    def allowed?(guard_name, key)
      entries = @allowlist[guard_name.to_sym]
      return false unless entries

      entries.any? do |entry|
        case entry
        when Regexp then key.match?(entry)
        else entry.to_s == key.to_s
        end
      end
    end

    def allowlist
      @allowlist
    end

    # Compose all guards around a block of code.
    # Each guard is an around-block: guard.call { inner }
    # Result: guard_1 { guard_2 { guard_3 { yield } } }
    def wrap(&block)
      return yield unless @enabled && !@guards.empty?

      @guards.values.reduce(block) { |inner, guard|
        -> { guard.call(&inner) }
      }.call
    end
  end

  # Built-in guard: database write prevention
  # Works on all Rails versions (5+) and all database adapters.
  # Prepends a write-intercepting module once, controlled by a thread-local flag.
  module BuiltinGuards
    # Blocks INSERT, UPDATE, DELETE, DROP, CREATE, ALTER, TRUNCATE
    module WriteBlocker
      WRITE_PATTERN = /\A\s*(INSERT|UPDATE|DELETE|DROP|CREATE|ALTER|TRUNCATE)\b/i
      TABLE_PATTERN = /\b(?:INTO|FROM|UPDATE|TABLE|TRUNCATE)\s+[`"]?(\w+)[`"]?/i

      private

      def rails_console_ai_check_write!(sql)
        return unless Thread.current[:rails_console_ai_block_writes] && sql.match?(WRITE_PATTERN)

        table = sql.match(TABLE_PATTERN)&.captures&.first
        guards = RailsConsoleAi.configuration.safety_guards
        return if table && guards.allowed?(:database_writes, table)

        raise RailsConsoleAi::SafetyError.new(
          "Database write blocked: #{sql.strip.split(/\s+/).first(3).join(' ')}...",
          guard: :database_writes,
          blocked_key: table
        )
      end

      public

      def execute(sql, *args, **kwargs)
        rails_console_ai_check_write!(sql)
        super
      end

      def exec_delete(sql, *args, **kwargs)
        rails_console_ai_check_write!(sql)
        super
      end

      def exec_update(sql, *args, **kwargs)
        rails_console_ai_check_write!(sql)
        super
      end
    end

    def self.database_writes
      ->(& block) {
        ensure_write_blocker_installed!
        Thread.current[:rails_console_ai_block_writes] = true
        begin
          block.call
        ensure
          Thread.current[:rails_console_ai_block_writes] = false
        end
      }
    end

    def self.ensure_write_blocker_installed!
      return if @write_blocker_installed

      connection = ActiveRecord::Base.connection
      unless connection.class.ancestors.include?(WriteBlocker)
        connection.class.prepend(WriteBlocker)
      end
      @write_blocker_installed = true
    end

    # Blocks non-safe HTTP requests (POST, PUT, PATCH, DELETE, etc.) via Net::HTTP.
    # Since most Ruby HTTP libraries (HTTParty, RestClient, Faraday) use Net::HTTP
    # under the hood, this covers them all.
    module HttpBlocker
      SAFE_METHODS = %w[GET HEAD OPTIONS TRACE].freeze

      def request(req, *args, &block)
        if Thread.current[:rails_console_ai_block_http] && !SAFE_METHODS.include?(req.method)
          host = @address.to_s
          guards = RailsConsoleAi.configuration.safety_guards
          unless guards.allowed?(:http_mutations, host)
            raise RailsConsoleAi::SafetyError.new(
              "HTTP #{req.method} blocked (#{host}#{req.path})",
              guard: :http_mutations,
              blocked_key: host
            )
          end
        end
        super
      end
    end

    def self.http_mutations
      ->(&block) {
        ensure_http_blocker_installed!
        Thread.current[:rails_console_ai_block_http] = true
        begin
          block.call
        ensure
          Thread.current[:rails_console_ai_block_http] = false
        end
      }
    end

    def self.mailers
      ->(&block) {
        old_value = ActionMailer::Base.perform_deliveries
        ActionMailer::Base.perform_deliveries = false
        begin
          block.call
        ensure
          ActionMailer::Base.perform_deliveries = old_value
        end
      }
    end

    def self.ensure_http_blocker_installed!
      return if @http_blocker_installed

      require 'net/http'
      unless Net::HTTP.ancestors.include?(HttpBlocker)
        Net::HTTP.prepend(HttpBlocker)
      end
      @http_blocker_installed = true
    end
  end
end
