module ConsoleAgent
  module ConsoleMethods
    def ai_status
      ConsoleAgent.status
    end

    def ai_memories(n = nil)
      require 'yaml'
      require 'console_agent/tools/memory_tools'
      storage = ConsoleAgent.storage
      keys = storage.list('memories/*.md').sort

      if keys.empty?
        $stdout.puts "\e[2mNo memories stored yet.\e[0m"
        return nil
      end

      memories = keys.filter_map do |key|
        content = storage.read(key)
        next if content.nil? || content.strip.empty?
        next unless content =~ /\A---\s*\n(.*?\n)---\s*\n(.*)/m
        fm = YAML.safe_load($1, permitted_classes: [Time, Date]) || {}
        fm.merge('description' => $2.strip, 'file' => key)
      end

      if memories.empty?
        $stdout.puts "\e[2mNo memories stored yet.\e[0m"
        return nil
      end

      shown = n ? memories.last(n) : memories.last(5)
      total = memories.length

      $stdout.puts "\e[36m[Memories — showing last #{shown.length} of #{total}]\e[0m"
      shown.each do |m|
        $stdout.puts "\e[33m  #{m['name']}\e[0m"
        $stdout.puts "\e[2m  #{m['description']}\e[0m"
        tags = Array(m['tags'])
        $stdout.puts "\e[2m  tags: #{tags.join(', ')}\e[0m" unless tags.empty?
        $stdout.puts
      end

      path = storage.respond_to?(:root_path) ? File.join(storage.root_path, 'memories') : 'memories/'
      $stdout.puts "\e[2mStored in: #{path}/\e[0m"
      $stdout.puts "\e[2mUse ai_memories(n) to show last n.\e[0m"
      nil
    end

    def ai_sessions(n = 10, search: nil)
      require 'console_agent/session_logger'
      session_class = Object.const_get('ConsoleAgent::Session')

      scope = session_class.recent
      scope = scope.search(search) if search
      sessions = scope.limit(n)

      if sessions.empty?
        $stdout.puts "\e[2mNo sessions found.\e[0m"
        return nil
      end

      $stdout.puts "\e[36m[Sessions — showing #{sessions.length}#{search ? " matching \"#{search}\"" : ''}]\e[0m"
      $stdout.puts

      sessions.each do |s|
        id_str = "\e[2m##{s.id}\e[0m"
        name_str = s.name ? "\e[33m#{s.name}\e[0m " : ""
        query_str = s.name ? "\e[2m#{truncate_str(s.query, 50)}\e[0m" : truncate_str(s.query, 50)
        mode_str = "\e[2m[#{s.mode}]\e[0m"
        time_str = "\e[2m#{time_ago(s.created_at)}\e[0m"
        tokens = (s.input_tokens || 0) + (s.output_tokens || 0)
        token_str = tokens > 0 ? "\e[2m#{tokens} tokens\e[0m" : ""

        $stdout.puts "  #{id_str} #{name_str}#{query_str}"
        $stdout.puts "     #{mode_str} #{time_str} #{token_str}"
        $stdout.puts
      end

      $stdout.puts "\e[2mUse ai_resume(id_or_name) to resume a session.\e[0m"
      $stdout.puts "\e[2mUse ai_sessions(n, search: \"term\") to filter.\e[0m"
      nil
    rescue => e
      $stderr.puts "\e[31mConsoleAgent error: #{e.message}\e[0m"
      nil
    end

    def ai_resume(identifier = nil)
      __ensure_console_agent_user

      require 'console_agent/context_builder'
      require 'console_agent/providers/base'
      require 'console_agent/executor'
      require 'console_agent/repl'
      require 'console_agent/session_logger'

      session = if identifier
                  __find_session(identifier)
                else
                  session_class = Object.const_get('ConsoleAgent::Session')
                  session_class.where(mode: 'interactive', user_name: ConsoleAgent.current_user).recent.first
                end

      unless session
        msg = identifier ? "Session not found: #{identifier}" : "No interactive sessions found."
        $stderr.puts "\e[31m#{msg}\e[0m"
        return nil
      end

      repl = Repl.new(__console_agent_binding)
      repl.resume(session)
    rescue => e
      $stderr.puts "\e[31mConsoleAgent error: #{e.message}\e[0m"
      nil
    end

    def ai_name(identifier, new_name)
      require 'console_agent/session_logger'

      session = __find_session(identifier)
      unless session
        $stderr.puts "\e[31mSession not found: #{identifier}\e[0m"
        return nil
      end

      ConsoleAgent::SessionLogger.update(session.id, name: new_name)
      $stdout.puts "\e[36mSession ##{session.id} named: #{new_name}\e[0m"
      nil
    rescue => e
      $stderr.puts "\e[31mConsoleAgent error: #{e.message}\e[0m"
      nil
    end

    def ai_setup
      ConsoleAgent.setup!
    end

    def ai_init
      require 'console_agent/context_builder'
      require 'console_agent/providers/base'
      require 'console_agent/executor'
      require 'console_agent/repl'

      repl = Repl.new(__console_agent_binding)
      repl.init_guide
    rescue => e
      $stderr.puts "\e[31mConsoleAgent error: #{e.message}\e[0m"
      nil
    end

    def ai(query = nil)
      if query.nil?
        $stderr.puts "\e[33mUsage: ai \"your question here\"\e[0m"
        $stderr.puts "\e[33m  ai  \"query\"  - ask + confirm execution\e[0m"
        $stderr.puts "\e[33m  ai! \"query\"  - enter interactive mode (or ai! with no args)\e[0m"
        $stderr.puts "\e[33m  ai? \"query\"  - explain only, no execution\e[0m"
        $stderr.puts "\e[33m  ai_init      - generate/update app guide for better AI context\e[0m"
        $stderr.puts "\e[33m  ai_sessions  - list recent sessions\e[0m"
        $stderr.puts "\e[33m  ai_resume    - resume a session by name or id\e[0m"
        $stderr.puts "\e[33m  ai_name      - name a session: ai_name 42, \"my_label\"\e[0m"
        $stderr.puts "\e[33m  ai_setup     - install session logging table\e[0m"
        $stderr.puts "\e[33m  ai_status    - show current configuration\e[0m"
        $stderr.puts "\e[33m  ai_memories  - show recent memories (ai_memories(n) for last n)\e[0m"
        return nil
      end

      __ensure_console_agent_user

      require 'console_agent/context_builder'
      require 'console_agent/providers/base'
      require 'console_agent/executor'
      require 'console_agent/repl'

      repl = Repl.new(__console_agent_binding)
      repl.one_shot(query.to_s)
    rescue => e
      $stderr.puts "\e[31mConsoleAgent error: #{e.message}\e[0m"
      nil
    end

    def ai!(query = nil)
      __ensure_console_agent_user

      require 'console_agent/context_builder'
      require 'console_agent/providers/base'
      require 'console_agent/executor'
      require 'console_agent/repl'

      repl = Repl.new(__console_agent_binding)

      if query
        repl.one_shot(query.to_s)
      else
        repl.interactive
      end
    rescue => e
      $stderr.puts "\e[31mConsoleAgent error: #{e.message}\e[0m"
      nil
    end

    def ai?(query = nil)
      unless query
        $stderr.puts "\e[33mUsage: ai? \"your question here\" - explain without executing\e[0m"
        return nil
      end

      __ensure_console_agent_user

      require 'console_agent/context_builder'
      require 'console_agent/providers/base'
      require 'console_agent/executor'
      require 'console_agent/repl'

      repl = Repl.new(__console_agent_binding)
      repl.explain(query.to_s)
    rescue => e
      $stderr.puts "\e[31mConsoleAgent error: #{e.message}\e[0m"
      nil
    end

    private

    def __find_session(identifier)
      session_class = Object.const_get('ConsoleAgent::Session')
      if identifier.is_a?(Integer)
        session_class.find_by(id: identifier)
      else
        session_class.where(name: identifier.to_s).recent.first ||
          session_class.find_by(id: identifier.to_i)
      end
    end

    def truncate_str(str, max)
      return '' if str.nil?
      str.length > max ? str[0...max] + '...' : str
    end

    def time_ago(time)
      return '' unless time
      seconds = Time.now - time
      case seconds
      when 0...60       then "just now"
      when 60...3600    then "#{(seconds / 60).to_i}m ago"
      when 3600...86400 then "#{(seconds / 3600).to_i}h ago"
      else                   "#{(seconds / 86400).to_i}d ago"
      end
    end

    def __ensure_console_agent_user
      return if ConsoleAgent.current_user
      $stdout.puts "\e[36mConsoleAgent logs all AI sessions for audit purposes.\e[0m"
      $stdout.print "\e[36mPlease enter your name: \e[0m"
      name = $stdin.gets.to_s.strip
      ConsoleAgent.current_user = name.empty? ? ENV['USER'] : name
    end

    def __console_agent_binding
      # Try IRB workspace binding
      if defined?(IRB) && IRB.respond_to?(:CurrentContext)
        ctx = IRB.CurrentContext rescue nil
        if ctx && ctx.respond_to?(:workspace) && ctx.workspace.respond_to?(:binding)
          return ctx.workspace.binding
        end
      end

      # Try Pry binding
      if defined?(Pry) && respond_to?(:pry_instance, true)
        pry_inst = pry_instance rescue nil
        if pry_inst && pry_inst.respond_to?(:current_binding)
          return pry_inst.current_binding
        end
      end

      # Fallback
      TOPLEVEL_BINDING
    end
  end
end
