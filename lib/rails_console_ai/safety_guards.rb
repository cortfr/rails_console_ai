require 'rails_console_ai/guard_state'
require 'rails_console_ai/sql_writes'

module RailsConsoleAi
  # Raised by safety guards to block dangerous operations.
  # Host apps should raise this error in their custom guards.
  # RailsConsoleAi will catch it and guide the user to use 'd' or /danger.
  class SafetyError < StandardError
    attr_reader :guard, :blocked_key

    # Tracked so the executor can detect safety errors even when swallowed by a
    # rescue inside eval'd code — including code running in a thread it spawned.
    def self.last_raised
      GuardState[:last_safety_error]
    end

    def self.clear!
      GuardState[:last_safety_error] = nil
    end

    def initialize(message, guard: nil, blocked_key: nil)
      super(message)
      @guard = guard
      @blocked_key = blocked_key
      GuardState.record_error(self)
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
      @enabled && !GuardState[:guards_disabled]
    end

    def enable!
      GuardState[:guards_disabled] = nil
    end

    def disable!
      GuardState[:guards_disabled] = true
    end

    # Hard sandbox: block ALL database access (reads and writes) for the duration of the
    # block. Used to fence in sub-agents that must never touch the DB (e.g. the
    # output-explorer, which only examines an in-memory string). Scoped to the block
    # (see GuardState), so it covers the calling thread and anything it spawns, and is
    # restored afterward — nestable, and independent of enable!/disable! and the
    # registered guard set.
    def with_database_blocked(&block)
      BuiltinGuards.ensure_write_blocker_installed!
      GuardState.with(block_all_db: true, &block)
    end

    def empty?
      @guards.empty?
    end

    def names
      @guards.keys
    end

    # Add a permanent (config-time) allowlist entry visible to all threads.
    def allow_global(guard_name, key)
      guard_name = guard_name.to_sym
      @allowlist[guard_name] ||= []
      @allowlist[guard_name] << key unless @allowlist[guard_name].include?(key)
    end

    # Add a runtime allowlist entry ("allow for this session"), held by the
    # session's thread.
    def allow(guard_name, key)
      thread_list = session_allowlist
      guard_name = guard_name.to_sym
      thread_list[guard_name] ||= []
      thread_list[guard_name] << key unless thread_list[guard_name].include?(key)
    end

    def allowed?(guard_name, key)
      guard_name = guard_name.to_sym
      match = ->(entries) {
        entries&.any? do |entry|
          case entry
          when Regexp then key.match?(entry)
          else entry.to_s == key.to_s
          end
        end
      }
      # Check global (config-time) allowlist
      return true if match.call(@allowlist[guard_name])
      # Check the runtime (session) allowlist
      thread_list = GuardState[:allowlist]
      return true if thread_list && match.call(thread_list[guard_name])
      false
    end

    def allowlist
      thread_list = GuardState[:allowlist]
      return @allowlist unless thread_list
      merged = @allowlist.dup
      thread_list.each { |k, v| merged[k] = (merged[k] || []) + v }
      merged
    end

    # Compose all guards around a block of code.
    # Each guard is an around-block: guard.call { inner }
    # Result: guard_1 { guard_2 { guard_3 { yield } } }
    def wrap(channel_mode: nil, additional_bypass_methods: nil, &block)
      return yield unless enabled? && !@guards.empty?

      install_skills_once!
      bypass_set = resolve_bypass_methods(channel_mode)
      Array(additional_bypass_methods).each { |m| bypass_set << m }

      # The allowlist and the error sink are carried in the scope so threads the
      # guarded code spawns consult the session's allowlist and report blocked
      # operations back to the session's thread.
      GuardState.with(
        session_active: true,
        bypass_methods: bypass_set,
        allowlist: session_allowlist,
        error_sink: GuardState.base
      ) do
        @guards.values.reduce(block) { |inner, guard|
          -> { guard.call(&inner) }
        }.call
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
          if GuardState[:bypass_methods]&.include?(spec)
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

    # The runtime allowlist in effect: the enclosing guarded execution's when
    # there is one (so a spawned thread adds to the session's list, not its own),
    # otherwise the calling thread's.
    def session_allowlist
      GuardState[:allowlist] || (GuardState[:allowlist] = {})
    end

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
    # Thread-safe: scoped to the calling thread and anything it spawns inside
    # the block (see GuardState), and restored after the block even if it raises.
    def without_guards(&block)
      GuardState.with(bypass_guards: true, &block)
    end
  end

  # Built-in guard: database write prevention
  # Works on all Rails versions (5+) and all database adapters.
  # Prepends a write-intercepting module once, controlled by a thread-local flag.
  module BuiltinGuards
    # Blocks statements that write — see SqlWrites for what counts as one.
    module WriteBlocker
      private

      # Hard sandbox: when active, block ALL database access (reads and writes), not just
      # mutations. Used to fence in sub-agents that must never touch the DB (e.g. the
      # output-explorer, which only examines an in-memory string). Deliberately does NOT
      # honor the bypass flag — it is a true wall, not a safe-mode toggle.
      def rails_console_ai_check_db_blocked!(_sql)
        return unless GuardState[:block_all_db]

        raise RailsConsoleAi::SafetyError.new(
          "Database access is disabled here. The captured data is in the `output` " \
          "variable — examine that instead of querying the database.",
          guard: :database_access,
          blocked_key: nil
        )
      end

      def rails_console_ai_check_write!(sql)
        return unless GuardState[:block_writes]

        writes = SqlWrites.find(sql, mysql: rails_console_ai_mysql?)
        return if writes.empty?
        return if GuardState[:bypass_guards]

        # Every write in the statement has to be allowed, not just the first:
        # `WITH d AS (DELETE FROM a ...) INSERT INTO b ...` touches both.
        guards = RailsConsoleAi.configuration.safety_guards
        blocked = writes.find do |write|
          !(write.table && [write.table, write.qualified_table].uniq.any? { |key| guards.allowed?(:database_writes, key) })
        end
        return unless blocked

        raise RailsConsoleAi::SafetyError.new(
          "Database write blocked: #{blocked.summary}...",
          guard: :database_writes,
          blocked_key: blocked.table
        )
      end

      # MySQL reads comments, string escapes and double quotes differently from
      # every other database, which changes where a statement's code starts and
      # stops.
      def rails_console_ai_mysql?
        respond_to?(:adapter_name) && adapter_name.to_s.match?(/mysql|trilogy|maria/i)
      end

      public

      def execute(sql, *args, **kwargs)
        rails_console_ai_check_db_blocked!(sql)
        rails_console_ai_check_write!(sql)
        super
      end

      def exec_query(sql, *args, **kwargs)
        rails_console_ai_check_db_blocked!(sql)
        rails_console_ai_check_write!(sql)
        super
      end

      def exec_insert(sql, *args, **kwargs)
        rails_console_ai_check_db_blocked!(sql)
        rails_console_ai_check_write!(sql)
        super
      end

      def exec_delete(sql, *args, **kwargs)
        rails_console_ai_check_db_blocked!(sql)
        rails_console_ai_check_write!(sql)
        super
      end

      def exec_update(sql, *args, **kwargs)
        rails_console_ai_check_db_blocked!(sql)
        rails_console_ai_check_write!(sql)
        super
      end
    end

    def self.database_writes
      ->(& block) {
        ensure_write_blocker_installed!
        GuardState.with(block_writes: true, &block)
      }
    end

    # Rails 7.1 moved the work beneath the public methods WriteBlocker wraps.
    # select_all, find_by_sql and insert_all/upsert_all now go straight to
    # internal_exec_query, and from Rails 8 everything funnels into raw_execute,
    # so a bulk insert, or a write passed to a select method, never reached the
    # check — and neither did the reads the hard sandbox is meant to stop.
    LOW_LEVEL_ENTRY_POINTS = %i[internal_exec_query raw_execute].freeze

    # Built per adapter class, wrapping only the entry points that class has and
    # keeping their visibility: defining one where Rails doesn't would make
    # respond_to? lie to anything that feature-tests the adapter.
    def self.low_level_write_blocker(adapter_class)
      Module.new do
        LOW_LEVEL_ENTRY_POINTS.each do |name|
          visibility =
            if adapter_class.private_method_defined?(name) then :private
            elsif adapter_class.protected_method_defined?(name) then :protected
            elsif adapter_class.public_method_defined?(name) then :public
            end
          next unless visibility

          define_method(name) do |sql, *args, **kwargs, &block|
            rails_console_ai_check_db_blocked!(sql)
            rails_console_ai_check_write!(sql)
            super(sql, *args, **kwargs, &block)
          end
          send(visibility, name)
        end
      end
    end

    def self.ensure_write_blocker_installed!
      return if @write_blocker_installed

      adapter_class = ActiveRecord::Base.connection.class
      unless adapter_class.ancestors.include?(WriteBlocker)
        # Prepended first so WriteBlocker's own (private) checks sit above it.
        adapter_class.prepend(low_level_write_blocker(adapter_class))
        adapter_class.prepend(WriteBlocker)
      end
      @write_blocker_installed = true
    end

    # Blocks non-safe HTTP requests (POST, PUT, PATCH, DELETE, etc.) via Net::HTTP.
    # Since most Ruby HTTP libraries (HTTParty, RestClient, Faraday) use Net::HTTP
    # under the hood, this covers them all.
    module HttpBlocker
      SAFE_METHODS = %w[GET HEAD OPTIONS TRACE].freeze

      def request(req, *args, &block)
        if GuardState[:block_http] && !SAFE_METHODS.include?(req.method)
          return super if GuardState[:bypass_guards]

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
        GuardState.with(block_http: true, &block)
      }
    end

    def self.mailers
      ->(&block) {
        return block.call if GuardState[:bypass_guards]

        old_value = ActionMailer::Base.perform_deliveries
        ActionMailer::Base.perform_deliveries = false
        begin
          block.call
        ensure
          ActionMailer::Base.perform_deliveries = old_value
        end
      }
    end

    # Blocks in-process HTTP dispatch against the running app itself.
    # An ActionDispatch::Integration::Session request (the console `app` helper,
    # or a manually built integration session) runs the app's full middleware
    # stack inside the current process and can deadlock or hang the session
    # thread indefinitely — so ALL verbs are blocked, including GET.
    module InProcessRequestBlocker
      def process(*args, **kwargs, &block)
        RailsConsoleAi::BuiltinGuards.check_in_process_request!(args[0], args[1])
        super
      end
    end

    # Backstop for the same hazard via direct Rack dispatch
    # (e.g. Rails.application.call(env)), which bypasses Integration::Session.
    module EngineCallBlocker
      def call(env, *args)
        if env.is_a?(Hash)
          RailsConsoleAi::BuiltinGuards.check_in_process_request!(env['REQUEST_METHOD'], env['PATH_INFO'])
        end
        super
      end
    end

    def self.check_in_process_request!(http_method, path)
      return unless GuardState[:block_in_process_requests]
      return if GuardState[:bypass_guards]

      key = path.to_s
      guards = RailsConsoleAi.configuration.safety_guards
      return if !key.empty? && guards.allowed?(:in_process_requests, key)

      label = [http_method.to_s.upcase, key].reject(&:empty?).join(' ')
      raise RailsConsoleAi::SafetyError.new(
        "In-process HTTP request blocked (#{label.empty? ? 'app dispatch' : label}). " \
        "Dispatching a request through the app's own middleware stack from this session " \
        "can hang the process indefinitely, even for GET. Do not retry via another route " \
        "or Rack — call the controller's underlying service or model code directly instead.",
        guard: :in_process_requests,
        blocked_key: key.empty? ? nil : key
      )
    end

    def self.in_process_requests
      ->(&block) {
        ensure_in_process_blocker_installed!
        GuardState.with(block_in_process_requests: true, &block)
      }
    end

    def self.ensure_in_process_blocker_installed!
      return if @in_process_blocker_installed

      begin
        require 'action_dispatch'
        require 'action_dispatch/testing/integration'
      rescue LoadError, NameError
        nil # actionpack not (fully) available — the Engine backstop may still apply
      end

      if defined?(ActionDispatch::Integration::Session) &&
         !ActionDispatch::Integration::Session.ancestors.include?(InProcessRequestBlocker)
        ActionDispatch::Integration::Session.prepend(InProcessRequestBlocker)
      end
      if defined?(Rails::Engine) && !Rails::Engine.ancestors.include?(EngineCallBlocker)
        Rails::Engine.prepend(EngineCallBlocker)
      end
      @in_process_blocker_installed = true
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
