module RailsConsoleAi
  # Raised by safety guards to block dangerous operations.
  # Host apps should raise this error in their custom guards.
  # RailsConsoleAi will catch it and guide the user to use 'd' or /danger.
  class SafetyError < StandardError
    attr_reader :guard, :blocked_key

    # Thread-local tracking so the executor can detect safety errors
    # even when swallowed by a rescue inside eval'd code.
    def self.last_raised
      Thread.current[:rails_console_ai_last_safety_error]
    end

    def self.clear!
      Thread.current[:rails_console_ai_last_safety_error] = nil
    end

    def initialize(message, guard: nil, blocked_key: nil)
      super(message)
      @guard = guard
      @blocked_key = blocked_key
      Thread.current[:rails_console_ai_last_safety_error] = self
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
    def wrap(channel_mode: nil, additional_bypass_methods: nil, &block)
      return yield unless @enabled && !@guards.empty?

      install_skills_once!
      bypass_set = resolve_bypass_methods(channel_mode)
      Array(additional_bypass_methods).each { |m| bypass_set << m }

      prev_active = Thread.current[:rails_console_ai_session_active]
      prev_bypass = Thread.current[:rails_console_ai_bypass_methods]
      Thread.current[:rails_console_ai_session_active] = true
      Thread.current[:rails_console_ai_bypass_methods] = bypass_set
      begin
        @guards.values.reduce(block) { |inner, guard|
          -> { guard.call(&inner) }
        }.call
      ensure
        Thread.current[:rails_console_ai_session_active] = prev_active
        Thread.current[:rails_console_ai_bypass_methods] = prev_bypass
      end
    end

    # Install a bypass shim for a single method spec (e.g. "ChangeApproval#approve_by!").
    # Prepends a module that checks the thread-local bypass set at runtime.
    # Idempotent: tracks which specs have been installed to avoid double-prepending.
    def install_bypass_method!(spec)
      @installed_bypass_specs ||= Set.new
      return if @installed_bypass_specs.include?(spec)

      if spec.include?('.')
        class_name, method_name = spec.split('.')
        class_method = true
      else
        class_name, method_name = spec.split('#')
        class_method = false
      end

      return unless method_name && !method_name.empty?

      klass = Object.const_get(class_name) rescue return
      method_sym = method_name.to_sym

      bypass_mod = Module.new do
        define_method(method_sym) do |*args, &blk|
          if Thread.current[:rails_console_ai_bypass_methods]&.include?(spec)
            RailsConsoleAi.configuration.safety_guards.without_guards { super(*args, &blk) }
          else
            super(*args, &blk)
          end
        end
      end

      if class_method
        klass.singleton_class.prepend(bypass_mod)
      else
        klass.prepend(bypass_mod)
      end
      @installed_bypass_specs << spec
    end

    private

    def resolve_bypass_methods(channel_mode)
      config = RailsConsoleAi.configuration
      methods = Set.new(config.bypass_guards_for_methods)
      if channel_mode
        channel_cfg = config.channels[channel_mode] || {}
        (channel_cfg['bypass_guards_for_methods'] || []).each { |m| methods << m }
      end
      methods
    end

    def install_skills_once!
      return if @skills_installed
      (@skills_mutex ||= Mutex.new).synchronize do
        return if @skills_installed
        all_methods = Set.new(RailsConsoleAi.configuration.bypass_guards_for_methods)
        RailsConsoleAi.configuration.channels.each_value do |cfg|
          (cfg['bypass_guards_for_methods'] || []).each { |m| all_methods << m }
        end
        all_methods.each { |spec| install_bypass_method!(spec) }
        @skills_installed = true
      end
    end

    public

    # Bypass all safety guards for the duration of the block.
    # Thread-safe: uses a thread-local flag that is restored after the block,
    # even if the block raises an exception.
    def without_guards
      prev = Thread.current[:rails_console_ai_bypass_guards]
      Thread.current[:rails_console_ai_bypass_guards] = true
      yield
    ensure
      Thread.current[:rails_console_ai_bypass_guards] = prev
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
        return if Thread.current[:rails_console_ai_bypass_guards]
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

      def exec_query(sql, *args, **kwargs)
        rails_console_ai_check_write!(sql)
        super
      end

      def exec_insert(sql, *args, **kwargs)
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
          return super if Thread.current[:rails_console_ai_bypass_guards]

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
        return block.call if Thread.current[:rails_console_ai_bypass_guards]

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
