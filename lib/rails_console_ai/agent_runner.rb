require 'json'
require 'rails_console_ai/prefixed_io'
require 'rails_console_ai/session_logger'
require 'rails_console_ai/channel/api'
require 'rails_console_ai/conversation_engine'
require 'rails_console_ai/context_builder'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/executor'

module RailsConsoleAi
  class RunnerTimeoutError < StandardError; end

  # Long-running worker that polls the sessions table for queued agent_api
  # rows, claims them atomically, and runs each in its own Thread via
  # ConversationEngine#one_shot. Started by `rake rails_console_ai:agents`.
  class AgentRunner
    POLL_INTERVAL = 2.0
    DEFAULT_CONCURRENCY = 3
    DRAIN_TIMEOUT = 60

    def initialize(concurrency: DEFAULT_CONCURRENCY, poll_interval: POLL_INTERVAL)
      @concurrency = concurrency
      @poll_interval = poll_interval
      @threads = {}      # session_id => Thread
      @mutex = Mutex.new
      @stopping = false
    end

    def start
      $stdout.sync = true
      $stderr.sync = true
      $stdout = RailsConsoleAi::PrefixedIO.new($stdout) unless $stdout.is_a?(RailsConsoleAi::PrefixedIO)
      $stderr = RailsConsoleAi::PrefixedIO.new($stderr) unless $stderr.is_a?(RailsConsoleAi::PrefixedIO)

      install_signal_handlers
      puts "AgentRunner starting (concurrency=#{@concurrency}, poll=#{@poll_interval}s)"
      loop do
        break if @stopping
        reap_finished
        fill_slots
        sleep @poll_interval
      end
      drain
      puts "AgentRunner stopped."
    end

    private

    def install_signal_handlers
      %w[INT TERM].each do |sig|
        Signal.trap(sig) { @stopping = true }
      end
    end

    def reap_finished
      @mutex.synchronize { @threads.reject! { |_, t| !t.alive? } }
    end

    def slots_available
      @concurrency - @mutex.synchronize { @threads.size }
    end

    def fill_slots
      slots = slots_available
      return if slots <= 0
      claim_next(slots).each { |session| spawn(session) }
    rescue => e
      warn "AgentRunner fill_slots failed: #{e.class}: #{e.message}"
    end

    # Returns up to `limit` Session records the runner exclusively owns.
    # Atomic claim: only the runner whose UPDATE flips the row from
    # 'queued' to 'running' may execute it.
    def claim_next(limit)
      candidates = Session.where(mode: 'agent_api', status: 'queued')
                          .order(:created_at)
                          .limit(limit)
                          .pluck(:id)
      claimed = []
      candidates.each do |id|
        n = Session.where(id: id, status: 'queued', mode: 'agent_api')
                   .update_all(status: 'running')
        claimed << Session.find(id) if n == 1
      end
      claimed
    rescue => e
      warn "AgentRunner claim failed: #{e.class}: #{e.message}"
      []
    end

    def spawn(session)
      tag = "[agent/#{session.id}] @#{session.user_name || '?'}"
      opts = parse_options(session)
      banner_extras = []
      banner_extras << 'thinking' if opts['use_thinking_model']
      if (cap = opts['max_wall_clock_seconds'])
        banner_extras << "cap=#{cap}s"
      end
      banner = banner_extras.empty? ? '' : " (#{banner_extras.join(', ')})"
      puts "#{tag}#{banner} << #{session.query.to_s.strip}"

      t = Thread.new do
        Thread.current.report_on_exception = false
        Thread.current[:log_prefix] = tag
        begin
          run_one(session, opts)
        ensure
          ActiveRecord::Base.clear_active_connections! if defined?(ActiveRecord::Base)
        end
      end
      @mutex.synchronize { @threads[session.id] = t }
    end

    def parse_options(session)
      raw = session.respond_to?(:options) ? session.options : nil
      return {} if raw.nil? || raw.to_s.empty?
      return raw if raw.is_a?(Hash)
      JSON.parse(raw)
    rescue => e
      warn "AgentRunner: failed to parse session.options (#{e.class}: #{e.message}); ignoring."
      {}
    end

    def run_one(session, opts = nil)
      opts ||= parse_options(session)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      channel = Channel::Api.new(user_name: session.user_name)
      sandbox_binding = Object.new.instance_eval { binding }
      engine = ConversationEngine.new(binding_context: sandbox_binding, channel: channel)
      engine.upgrade_to_thinking_model if opts['use_thinking_model']

      exec_result = run_with_deadline(opts['max_wall_clock_seconds']) do
        engine.one_shot(session.query, existing_session_id: session.id)
      end
      result_text = compose_result(channel.captured_output, exec_result)

      SessionLogger.update(session.id, status: 'ready', result: result_text)

      elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
      preview = result_text.to_s.strip.lines.first.to_s.strip
      preview = preview[0, 120] + '…' if preview.length > 120
      puts ">> ready (#{elapsed}ms) #{preview}"
    rescue RunnerTimeoutError => e
      warn ">> TIMEOUT #{e.message}"
      SessionLogger.update(session.id, status: 'failed', error_message: e.message)
    rescue => e
      warn ">> FAILED #{e.class}: #{e.message}"
      e.backtrace&.first(5)&.each { |line| warn "   #{line}" }
      SessionLogger.update(session.id,
        status: 'failed',
        error_message: "#{e.class}: #{e.message}\n#{Array(e.backtrace).first(10).join("\n")}"
      )
    end

    # When cap is nil or non-positive, run inline. Otherwise spawn a nested
    # worker thread, join with the deadline, and kill + raise on overshoot.
    # Kept localized (vs Timeout.timeout) so a runaway provider call can't
    # raise from inside our own bookkeeping code.
    def run_with_deadline(cap)
      return yield if cap.nil? || cap.to_f <= 0
      result = nil
      error = nil
      worker = Thread.new do
        Thread.current.report_on_exception = false
        begin
          result = yield
        rescue => e
          error = e
        end
      end
      if worker.join(cap.to_f).nil?
        worker.kill
        raise RunnerTimeoutError, "exceeded max_wall_clock_seconds (#{cap}s)"
      end
      raise error if error
      result
    end

    # Build the `result` payload returned via get_agent_response. The
    # LLM's prose lands in the channel's captured_output; the value the
    # generated code returned lands in exec_result. Without including the
    # latter, the consumer gets only the preamble ("Let me query...")
    # and not the actual answer.
    def compose_result(prose, exec_result)
      parts = []
      trimmed = prose.to_s.strip
      parts << trimmed unless trimmed.empty?
      parts << "Result: #{exec_result.inspect}" unless exec_result.nil?
      parts.empty? ? '' : (parts.join("\n\n") << "\n")
    end

    def drain
      n = @mutex.synchronize { @threads.size }
      return if n.zero?
      puts "AgentRunner draining #{n} in-flight job(s)..."
      deadline = Time.now + DRAIN_TIMEOUT
      loop do
        reap_finished
        break unless @mutex.synchronize { @threads.any? }
        break if Time.now >= deadline
        sleep 0.5
      end
      stuck = @mutex.synchronize { @threads.keys }
      stuck.each do |id|
        SessionLogger.update(id, status: 'failed', error_message: 'Runner shut down before completion')
      end
    end
  end
end
