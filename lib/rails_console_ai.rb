require 'rails_console_ai/version'
require 'rails_console_ai/configuration'

module RailsConsoleAi
  GUIDE_KEY = 'rails_console_ai.md'.freeze

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration) if block_given?
    end

    def reset_configuration!
      @configuration = Configuration.new
      reset_storage!
    end

    def storage
      @storage ||= begin
        adapter = configuration.storage_adapter
        if adapter
          adapter
        else
          require 'rails_console_ai/storage/file_storage'
          Storage::FileStorage.new
        end
      end
    end

    def reset_storage!
      @storage = nil
    end

    def logger
      @logger ||= if defined?(Rails) && Rails.respond_to?(:logger) && Rails.logger
                    Rails.logger
                  else
                    require 'logger'
                    Logger.new($stderr, progname: 'RailsConsoleAi')
                  end
    end

    def logger=(log)
      @logger = log
    end

    def current_user
      @current_user
    end

    def current_user=(name)
      @current_user = name
    end

    # Enqueue an agent run. Returns the Integer session id immediately;
    # the actual work is picked up by `rake rails_console_ai:agents`.
    #
    # use_thinking_model:     run on the configured thinking-tier model
    # max_wall_clock_seconds: hard kill the run after N seconds (nil = no cap)
    def run_agent(query, name: nil, user_name: nil,
                  use_thinking_model: false,
                  max_wall_clock_seconds: 600)
      require 'rails_console_ai/session_logger'
      options = {
        'use_thinking_model'     => !!use_thinking_model,
        'max_wall_clock_seconds' => max_wall_clock_seconds
      }
      id = SessionLogger.log(
        query: query,
        conversation: [],
        mode: 'agent_api',
        name: name,
        user_name: user_name,
        status: 'queued',
        executed: false,
        options: options
      )
      raise 'Failed to enqueue agent run (session logging disabled or table missing)' unless id
      id
    end

    # Returns the current status string for an enqueued agent run, or nil
    # if the session id is not found. Status is one of:
    # 'queued' | 'running' | 'ready' | 'failed'.
    def check_agent(session_id)
      Session.where(id: session_id).pluck(:status).first
    end

    # Returns a hash describing an agent run:
    #   { status:, result:, error: }
    # All three keys are nil when the session id is not found.
    def get_agent_response(session_id)
      row = Session.where(id: session_id).select(:status, :result, :error_message).first
      return { status: nil, result: nil, error: nil } unless row
      { status: row.status, result: row.result, error: row.error_message }
    end

    def status
      c = configuration
      key = c.resolved_api_key
      masked_key = if key.nil? || key.empty? || key == 'no-key'
                     c.provider == :local ? "\e[32m(not required)\e[0m" : "\e[31m(not set)\e[0m"
                   else
                     key[0..6] + '...' + key[-4..-1]
                   end

      lines = []
      lines << "\e[36m[RailsConsoleAi v#{VERSION}]\e[0m"
      lines << "  Provider:       #{c.provider}"
      lines << "  Model:          #{c.resolved_model}"
      lines << "  API key:        #{masked_key}"
      lines << "  Local URL:      #{c.local_url}" if c.provider == :local
      lines << "  Max tokens:     #{c.max_tokens || '(auto)'}"
      lines << "  Temperature:    #{c.temperature}"
      lines << "  Timeout:        #{c.timeout}s"
      lines << "  Max tool rounds:#{c.max_tool_rounds}"
      lines << "  Auto-execute:   #{c.auto_execute}"
      guards = c.safety_guards
      if guards.empty?
        lines << "  Safe mode:      \e[33m(no guards configured)\e[0m"
      else
        status = guards.enabled? ? "\e[32mON\e[0m" : "\e[31mOFF\e[0m"
        lines << "  Safe mode:      #{status} (#{guards.names.join(', ')})"
      end
      lines << "  Memories:       #{c.memories_enabled}"
      lines << "  Session logging:#{session_table_status}"
      lines << "  Debug:          #{c.debug}"
      $stdout.puts lines.join("\n")
      nil
    end

    def setup!
      conn = session_connection
      table = 'rails_console_ai_sessions'

      unless conn.table_exists?(table)
        conn.create_table(table) do |t|
          t.text    :query,         null: false
          t.text    :conversation,  null: false
          t.integer :input_tokens,  default: 0
          t.integer :output_tokens, default: 0
          t.string  :user_name,     limit: 255
          t.string  :mode,          limit: 20, null: false
          t.text    :code_executed
          t.text    :code_output
          t.text    :code_result
          t.text    :console_output
          t.boolean :executed,      default: false
          t.string  :provider,      limit: 50
          t.string  :model,         limit: 100
          t.string  :name,          limit: 255
          t.string  :slack_thread_ts, limit: 255
          t.string  :slack_channel_name, limit: 255
          t.integer :duration_ms
          t.text    :options
          t.datetime :created_at,   null: false
        end

        conn.add_index(table, :created_at)
        conn.add_index(table, :user_name)
        conn.add_index(table, :name)
        conn.add_index(table, :slack_thread_ts)

        $stdout.puts "\e[32mRailsConsoleAi: created #{table} table.\e[0m"
      end

      setup_skills_tables!(conn)
      setup_memories_tables!(conn)
      setup_agents_tables!(conn)

      migrate!
    rescue => e
      $stderr.puts "\e[31mRailsConsoleAi setup failed: #{e.class}: #{e.message}\e[0m"
    end

    def setup_skills_tables!(conn)
      skills_table   = 'rails_console_ai_skills'
      versions_table = 'rails_console_ai_skill_versions'

      unless conn.table_exists?(skills_table)
        conn.create_table(skills_table) do |t|
          t.string   :name,        limit: 255, null: false
          t.text     :description
          t.text     :body
          t.text     :tags
          t.text     :bypass_guards_for_methods
          t.string   :status,      limit: 20,  default: 'proposed', null: false
          t.string   :approved_by, limit: 255
          t.datetime :approved_at
          t.integer  :use_count,   default: 0, null: false
          t.datetime :last_used_at
          t.datetime :created_at,  null: false
          t.datetime :updated_at,  null: false
        end
        conn.add_index(skills_table, :name, unique: true)
        conn.add_index(skills_table, :status)
        $stdout.puts "\e[32mRailsConsoleAi: created #{skills_table} table.\e[0m"
      else
        # Idempotent column-add probes for existing installs.
        unless conn.column_exists?(skills_table, :status)
          conn.add_column(skills_table, :status, :string, limit: 20, default: 'proposed', null: false)
          conn.add_index(skills_table, :status) unless conn.index_exists?(skills_table, :status)
        end
        unless conn.column_exists?(skills_table, :approved_by)
          conn.add_column(skills_table, :approved_by, :string, limit: 255)
        end
        unless conn.column_exists?(skills_table, :approved_at)
          conn.add_column(skills_table, :approved_at, :datetime)
        end
        unless conn.column_exists?(skills_table, :use_count)
          conn.add_column(skills_table, :use_count, :integer, default: 0, null: false)
        end
        unless conn.column_exists?(skills_table, :last_used_at)
          conn.add_column(skills_table, :last_used_at, :datetime)
        end
      end

      unless conn.table_exists?(versions_table)
        conn.create_table(versions_table) do |t|
          t.integer  :skill_id
          t.string   :name,        limit: 255
          t.text     :description
          t.text     :body
          t.text     :tags
          t.text     :bypass_guards_for_methods
          t.string   :status,      limit: 20
          t.string   :edited_by,   limit: 255
          t.text     :change_note
          t.datetime :created_at,  null: false
        end
        conn.add_index(versions_table, :skill_id)
        conn.add_index(versions_table, :created_at)
        $stdout.puts "\e[32mRailsConsoleAi: created #{versions_table} table.\e[0m"
      else
        unless conn.column_exists?(versions_table, :status)
          conn.add_column(versions_table, :status, :string, limit: 20)
        end
      end
    end

    def setup_memories_tables!(conn)
      memories_table = 'rails_console_ai_memories'
      versions_table = 'rails_console_ai_memory_versions'

      unless conn.table_exists?(memories_table)
        conn.create_table(memories_table) do |t|
          t.string   :name,        limit: 255, null: false
          t.text     :description
          t.text     :tags
          t.integer  :use_count,   default: 0, null: false
          t.datetime :last_used_at
          t.datetime :created_at,  null: false
          t.datetime :updated_at,  null: false
        end
        conn.add_index(memories_table, :name, unique: true)
        $stdout.puts "\e[32mRailsConsoleAi: created #{memories_table} table.\e[0m"
      else
        unless conn.column_exists?(memories_table, :use_count)
          conn.add_column(memories_table, :use_count, :integer, default: 0, null: false)
        end
        unless conn.column_exists?(memories_table, :last_used_at)
          conn.add_column(memories_table, :last_used_at, :datetime)
        end
      end

      unless conn.table_exists?(versions_table)
        conn.create_table(versions_table) do |t|
          t.integer  :memory_id
          t.string   :name,        limit: 255
          t.text     :description
          t.text     :tags
          t.string   :edited_by,   limit: 255
          t.text     :change_note
          t.datetime :created_at,  null: false
        end
        conn.add_index(versions_table, :memory_id)
        conn.add_index(versions_table, :created_at)
        $stdout.puts "\e[32mRailsConsoleAi: created #{versions_table} table.\e[0m"
      end
    end

    def setup_agents_tables!(conn)
      agents_table   = 'rails_console_ai_agents'
      versions_table = 'rails_console_ai_agent_versions'

      unless conn.table_exists?(agents_table)
        conn.create_table(agents_table) do |t|
          t.string   :name,        limit: 255, null: false
          t.text     :description
          t.text     :body
          t.integer  :max_rounds
          t.string   :model,       limit: 100
          t.text     :tools
          t.string   :status,      limit: 20,  default: 'proposed', null: false
          t.string   :approved_by, limit: 255
          t.datetime :approved_at
          t.integer  :use_count,   default: 0, null: false
          t.datetime :last_used_at
          t.datetime :created_at,  null: false
          t.datetime :updated_at,  null: false
        end
        conn.add_index(agents_table, :name, unique: true)
        conn.add_index(agents_table, :status)
        $stdout.puts "\e[32mRailsConsoleAi: created #{agents_table} table.\e[0m"
      else
        unless conn.column_exists?(agents_table, :status)
          conn.add_column(agents_table, :status, :string, limit: 20, default: 'proposed', null: false)
          conn.add_index(agents_table, :status) unless conn.index_exists?(agents_table, :status)
        end
        unless conn.column_exists?(agents_table, :approved_by)
          conn.add_column(agents_table, :approved_by, :string, limit: 255)
        end
        unless conn.column_exists?(agents_table, :approved_at)
          conn.add_column(agents_table, :approved_at, :datetime)
        end
        unless conn.column_exists?(agents_table, :use_count)
          conn.add_column(agents_table, :use_count, :integer, default: 0, null: false)
        end
        unless conn.column_exists?(agents_table, :last_used_at)
          conn.add_column(agents_table, :last_used_at, :datetime)
        end
      end

      unless conn.table_exists?(versions_table)
        conn.create_table(versions_table) do |t|
          t.integer  :agent_id
          t.string   :name,        limit: 255
          t.text     :description
          t.text     :body
          t.integer  :max_rounds
          t.string   :model,       limit: 100
          t.text     :tools
          t.string   :status,      limit: 20
          t.string   :edited_by,   limit: 255
          t.text     :change_note
          t.datetime :created_at,  null: false
        end
        conn.add_index(versions_table, :agent_id)
        conn.add_index(versions_table, :created_at)
        $stdout.puts "\e[32mRailsConsoleAi: created #{versions_table} table.\e[0m"
      end
    end

    def migrate!
      conn = session_connection
      table = 'rails_console_ai_sessions'

      unless conn.table_exists?(table)
        $stderr.puts "\e[33mRailsConsoleAi: #{table} does not exist. Run RailsConsoleAi.setup! first.\e[0m"
        return
      end

      migrations = []

      unless conn.column_exists?(table, :name)
        conn.add_column(table, :name, :string, limit: 255)
        conn.add_index(table, :name) unless conn.index_exists?(table, :name)
        migrations << 'name'
      end

      unless conn.column_exists?(table, :slack_thread_ts)
        conn.add_column(table, :slack_thread_ts, :string, limit: 255)
        conn.add_index(table, :slack_thread_ts) unless conn.index_exists?(table, :slack_thread_ts)
        migrations << 'slack_thread_ts'
      end

      unless conn.column_exists?(table, :slack_channel_name)
        conn.add_column(table, :slack_channel_name, :string, limit: 255)
        migrations << 'slack_channel_name'
      end

      unless conn.column_exists?(table, :status)
        conn.add_column(table, :status, :string, limit: 20)
        migrations << 'status'
      end

      unless conn.column_exists?(table, :result)
        conn.add_column(table, :result, :text)
        migrations << 'result'
      end

      unless conn.column_exists?(table, :error_message)
        conn.add_column(table, :error_message, :text)
        migrations << 'error_message'
      end

      unless conn.column_exists?(table, :options)
        conn.add_column(table, :options, :text)
        migrations << 'options'
      end

      unless conn.index_exists?(table, [:mode, :status], name: 'idx_rca_sessions_mode_status')
        conn.add_index(table, [:mode, :status], name: 'idx_rca_sessions_mode_status')
        migrations << 'idx_rca_sessions_mode_status'
      end

      # Bring skills/memories/agents tables fully up to date. Each setup_* method is
      # internally idempotent (guards both `create_table` and every `add_column` /
      # `add_index`), so running it on an existing install adds any missing columns
      # (e.g. `status`, `approved_by`, `approved_at`) and indexes without disturbing
      # data. Note: we always call these — the previous version skipped them when
      # the base table already existed, which meant column probes never ran on
      # upgrade and methods like Skill#status hit NameError. See:
      # https://github.com/cortfr/rails_console_ai/issues (whichever issue you file)
      pre_columns = {
        skills:   table_columns(conn, 'rails_console_ai_skills'),
        memories: table_columns(conn, 'rails_console_ai_memories'),
        agents:   table_columns(conn, 'rails_console_ai_agents')
      }

      setup_skills_tables!(conn)
      setup_memories_tables!(conn)
      setup_agents_tables!(conn)

      [[:skills, 'rails_console_ai_skills'], [:memories, 'rails_console_ai_memories'], [:agents, 'rails_console_ai_agents']].each do |key, name|
        post = table_columns(conn, name)
        added = post - pre_columns[key]
        migrations.concat(added.map { |c| "#{name}.#{c}" }) unless added.empty?
      end

      if migrations.empty?
        $stdout.puts "\e[32mRailsConsoleAi: #{table} is up to date.\e[0m"
      else
        RailsConsoleAi::Session.reset_column_information if defined?(RailsConsoleAi::Session)
        $stdout.puts "\e[32mRailsConsoleAi: added columns: #{migrations.join(', ')}.\e[0m"
      end
    rescue => e
      $stderr.puts "\e[31mRailsConsoleAi migrate failed: #{e.class}: #{e.message}\e[0m"
    end

    def teardown!
      conn = session_connection
      table = 'rails_console_ai_sessions'

      unless conn.table_exists?(table)
        $stdout.puts "\e[33mRailsConsoleAi: #{table} does not exist, nothing to remove.\e[0m"
        return
      end

      count = conn.select_value("SELECT COUNT(*) FROM #{conn.quote_table_name(table)}")
      $stdout.print "\e[33mDrop #{table} (#{count} sessions)? [y/N] \e[0m"
      answer = $stdin.gets.to_s.strip.downcase

      unless answer == 'y' || answer == 'yes'
        $stdout.puts "\e[33mCancelled.\e[0m"
        return
      end

      conn.drop_table(table)
      $stdout.puts "\e[32mRailsConsoleAi: dropped #{table}.\e[0m"
    rescue => e
      $stderr.puts "\e[31mRailsConsoleAi teardown failed: #{e.class}: #{e.message}\e[0m"
    end

    private

    def session_table_status
      return 'disabled' unless configuration.session_logging
      conn = session_connection
      if conn.table_exists?('rails_console_ai_sessions')
        count = conn.select_value("SELECT COUNT(*) FROM #{conn.quote_table_name('rails_console_ai_sessions')}")
        "\e[32m#{count} sessions\e[0m"
      else
        "\e[33mtable missing (run RailsConsoleAi.setup!)\e[0m"
      end
    rescue
      "\e[33munavailable\e[0m"
    end

    def session_connection
      klass = configuration.connection_class
      if klass
        klass = Object.const_get(klass) if klass.is_a?(String)
        klass.connection
      else
        ActiveRecord::Base.connection
      end
    end

    def table_columns(conn, table_name)
      return [] unless conn.table_exists?(table_name)
      conn.columns(table_name).map { |c| c.name }
    rescue
      []
    end
  end
end

if defined?(Rails::Railtie)
  require 'rails_console_ai/railtie'
  require 'rails_console_ai/engine'
end
