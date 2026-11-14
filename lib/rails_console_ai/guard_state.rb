module RailsConsoleAi
  # Where the safety guards keep their runtime state: which guards are blocking,
  # whether they are bypassed, what has been allowed for this session.
  #
  # This used to be plain `Thread.current[:key]`, which is fiber-local despite
  # the name. Code the model wrote only had to run inside a new Thread, a Fiber,
  # or an external Enumerator (`enum.next`) to find every flag nil and every
  # guard off — not as an attack, just by reaching for ordinary concurrency.
  #
  # State set with .with is scoped to the block. While the block is running it
  # is visible to
  #   - every fiber on the calling thread (it is held in a thread variable), and
  #   - every thread and fiber spawned inside the block (it is also published to
  #     fiber storage, which new threads and fibers inherit). Fiber storage is
  #     Ruby 3.2+; on older Rubies a spawned thread still starts with no state.
  #
  # A spawned thread holds a reference to the scope, not a copy of its values:
  # when the block exits, the scope is closed and stops applying everywhere.
  # That is deliberate. A worker a thread pool happened to create during a
  # guarded execution would otherwise carry "writes blocked" for the rest of the
  # process's life, into work that has nothing to do with the session. The cost
  # is that a thread still running after the execution that spawned it has
  # returned is no longer guarded.
  #
  # State set with []= belongs to the calling thread and lasts until changed.
  #
  # Writes are mirrored to the old `Thread.current[:rails_console_ai_<key>]`
  # fiber-locals and reads fall back to them, so host-app code that reads or
  # sets those keys directly keeps working.
  module GuardState
    SCOPE = :rails_console_ai_guard_scope
    BASE  = :rails_console_ai_guard_base

    INHERITABLE = Fiber.respond_to?(:[]=)

    LEGACY_KEYS = %i[
      allowlist
      block_all_db
      block_http
      block_in_process_requests
      block_writes
      bypass_guards
      bypass_methods
      guards_disabled
      last_safety_error
      session_active
    ].map { |key| [key, :"rails_console_ai_#{key}"] }.to_h.freeze

    class Scope
      attr_reader :parent, :values

      def initialize(parent, values)
        @parent = parent
        @values = values.dup.freeze
        @open = true
      end

      def open?
        @open
      end

      def close!
        @open = false
      end
    end

    class << self
      # Nearest enclosing scope that sets the key, then this thread's own state,
      # then the legacy fiber-local.
      def [](key)
        scope = current_scope
        while scope
          return scope.values[key] if scope.open? && scope.values.key?(key)
          scope = scope.parent
        end

        thread = Thread.current
        own = thread.thread_variable_get(BASE)
        return own[key] if own && own.key?(key)

        legacy = LEGACY_KEYS[key]
        legacy && thread[legacy]
      end

      def []=(key, value)
        if value.nil?
          base.delete(key)
        else
          base[key] = value
        end
        legacy = LEGACY_KEYS[key]
        Thread.current[legacy] = value if legacy
      end

      # The calling thread's own (unscoped) state.
      def base
        thread = Thread.current
        own = thread.thread_variable_get(BASE)
        unless own
          own = {}
          thread.thread_variable_set(BASE, own)
        end
        own
      end

      def with(values)
        thread = Thread.current
        previous = current_scope
        scope = Scope.new(previous, values)
        legacy_before = values.keys.map { |key| LEGACY_KEYS[key] }.compact.map { |legacy| [legacy, thread[legacy]] }

        install(scope)
        values.each do |key, value|
          legacy = LEGACY_KEYS[key]
          thread[legacy] = value if legacy
        end

        begin
          yield
        ensure
          scope.close!
          install(previous)
          legacy_before.each { |legacy, value| thread[legacy] = value }
        end
      end

      # A SafetyError raised in a spawned thread is also recorded on the thread
      # that opened the guarded execution, because that is where the executor
      # looks for errors the model's code rescued and carried on from.
      def record_error(error)
        self[:last_safety_error] = error
        sink = self[:error_sink]
        sink[:last_safety_error] = error if sink
      end

      # Clear everything held for the calling thread. For tests.
      def reset!
        thread = Thread.current
        thread.thread_variable_set(BASE, nil)
        install(nil)
        LEGACY_KEYS.each_value { |legacy| thread[legacy] = nil }
      end

      private

      # The thread variable wins over fiber storage: a fiber created during an
      # earlier execution (an enumerator kept in a variable, say) still carries
      # that execution's closed scope in its storage, and must see the current
      # one. Fiber storage is only what a newly spawned thread starts from.
      def current_scope
        Thread.current.thread_variable_get(SCOPE) || (INHERITABLE ? Fiber[SCOPE] : nil)
      end

      def install(scope)
        Thread.current.thread_variable_set(SCOPE, scope)
        Fiber[SCOPE] = scope if INHERITABLE
      end
    end
  end
end
