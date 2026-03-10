require 'json'
require 'uri'
require 'net/http'
require 'openssl'
require 'rails_console_ai/prefixed_io'
require 'rails_console_ai/channel/slack'
require 'rails_console_ai/conversation_engine'
require 'rails_console_ai/context_builder'
require 'rails_console_ai/providers/base'
require 'rails_console_ai/executor'

module RailsConsoleAi
  class SlackBot
    PING_INTERVAL = 30  # seconds — send ping if no data received
    PONG_TIMEOUT  = 60  # seconds — reconnect if no pong after ping

    def initialize
      @bot_token = RailsConsoleAi.configuration.slack_bot_token || ENV['SLACK_BOT_TOKEN']
      @app_token = RailsConsoleAi.configuration.slack_app_token || ENV['SLACK_APP_TOKEN']
      @channel_ids = resolve_channel_ids

      raise ConfigurationError, "SLACK_BOT_TOKEN is required" unless @bot_token
      raise ConfigurationError, "SLACK_APP_TOKEN is required (Socket Mode)" unless @app_token
      raise ConfigurationError, "slack_allowed_usernames must be configured (e.g. ['alice'] or 'ALL')" unless RailsConsoleAi.configuration.slack_allowed_usernames

      @bot_user_id = nil
      @sessions = {}       # thread_ts → { channel:, engine:, thread: }
      @user_cache = {}     # slack user_id → display_name
      @mutex = Mutex.new
    end

    def start
      $stdout.sync = true
      $stderr.sync = true
      $stdout = RailsConsoleAi::PrefixedIO.new($stdout) unless $stdout.is_a?(RailsConsoleAi::PrefixedIO)
      $stderr = RailsConsoleAi::PrefixedIO.new($stderr) unless $stderr.is_a?(RailsConsoleAi::PrefixedIO)

      # Eager load the Rails app so class-level initializers (e.g. Secret.get)
      # run before safety guards are active during user code execution.
      if defined?(Rails) && Rails.application.respond_to?(:eager_load!)
        puts "Eager loading application..."
        Rails.application.eager_load!
      end

      @bot_user_id = slack_api("auth.test", token: @bot_token).dig("user_id")
      log_startup

      loop do
        run_socket_mode
        puts "Reconnecting in 5s..."
        sleep 5
      end
    rescue Interrupt
      puts "\nSlackBot shutting down."
    end

    private

    # --- Socket Mode connection ---

    def run_socket_mode
      url = obtain_wss_url
      uri = URI.parse(url)

      tcp = TCPSocket.new(uri.host, uri.port || 443)
      ssl = OpenSSL::SSL::SSLSocket.new(tcp, OpenSSL::SSL::SSLContext.new)
      ssl.hostname = uri.host
      ssl.connect

      # WebSocket handshake
      path = "#{uri.path}?#{uri.query}"
      handshake = [
        "GET #{path} HTTP/1.1",
        "Host: #{uri.host}",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Sec-WebSocket-Key: #{SecureRandom.base64(16)}",
        "Sec-WebSocket-Version: 13",
        "", ""
      ].join("\r\n")

      ssl.write(handshake)

      # Read HTTP 101 response headers
      response_line = ssl.gets
      unless response_line&.include?("101")
        raise "WebSocket handshake failed: #{response_line}"
      end
      # Consume remaining headers
      loop do
        line = ssl.gets
        break if line.nil? || line.strip.empty?
      end

      puts "Connected to Slack Socket Mode."

      # Main read loop with keepalive
      last_activity = Time.now
      last_ping_sent_at = Time.now
      ping_sent = false

      loop do
        ready = IO.select([ssl.to_io], nil, nil, PING_INTERVAL)

        # Send outbound ping on a fixed schedule, regardless of inbound activity
        if Time.now - last_ping_sent_at >= PING_INTERVAL
          if ping_sent && (Time.now - last_activity) > PONG_TIMEOUT
            puts "Slack connection timed out (no pong received after #{(Time.now - last_activity).round}s). Reconnecting..."
            break
          end
          puts "Sending WebSocket ping (last activity #{(Time.now - last_activity).round}s ago)"
          send_ws_ping(ssl)
          last_ping_sent_at = Time.now
          ping_sent = true
        end

        next if ready.nil?

        data = read_ws_frame(ssl)
        last_activity = Time.now
        if ping_sent
          puts "Received data after ping — connection alive"
          ping_sent = false
        end
        next unless data

        begin
          msg = JSON.parse(data, symbolize_names: true)
        rescue JSON::ParserError
          next
        end

        # Acknowledge immediately (Slack requires fast ack)
        if msg[:envelope_id]
          send_ws_frame(ssl, JSON.generate({ envelope_id: msg[:envelope_id] }))
        end

        case msg[:type]
        when "hello"
          # Connection confirmed
        when "disconnect"
          puts "Slack disconnect: #{msg[:reason]}"
          break
        when "events_api"
          handle_event(msg)
        end
      end
    rescue EOFError, IOError, Errno::ECONNRESET, OpenSSL::SSL::SSLError => e
      puts "Socket Mode connection lost: #{e.message}"
    ensure
      ssl&.close rescue nil
      tcp&.close rescue nil
    end

    def obtain_wss_url
      result = slack_api("apps.connections.open", token: @app_token)
      raise "Failed to obtain WSS URL: #{result["error"]}" unless result["ok"]
      result["url"]
    end

    # --- WebSocket frame reading/writing (RFC 6455 minimal implementation) ---

    def read_ws_frame(ssl)
      first_byte = ssl.read(1)&.unpack1("C")
      return nil unless first_byte

      opcode = first_byte & 0x0F
      # Handle ping (opcode 9) → send pong (opcode 10)
      if opcode == 9
        payload = read_ws_payload(ssl)
        puts "Received server ping, sending pong"
        send_ws_pong(ssl, payload)
        return nil
      end
      # Handle pong (opcode 10) — response to our keepalive ping
      if opcode == 0xA
        read_ws_payload(ssl) # consume payload
        puts "Received WebSocket pong"
        return nil
      end
      # Close frame (opcode 8)
      return nil if opcode == 8
      # Only process text frames (opcode 1)
      return nil unless opcode == 1

      read_ws_payload(ssl)
    end

    def read_ws_payload(ssl)
      second_byte = ssl.read(1)&.unpack1("C")
      return nil unless second_byte

      masked = (second_byte & 0x80) != 0
      length = second_byte & 0x7F

      if length == 126
        length = ssl.read(2).unpack1("n")
      elsif length == 127
        length = ssl.read(8).unpack1("Q>")
      end

      if masked
        mask_key = ssl.read(4).bytes
        raw = ssl.read(length).bytes
        raw.each_with_index.map { |b, i| (b ^ mask_key[i % 4]).chr }.join
      else
        ssl.read(length)
      end
    end

    def send_ws_frame(ssl, text)
      bytes = text.encode("UTF-8").bytes
      # Client frames must be masked per RFC 6455
      mask_key = 4.times.map { rand(256) }
      masked = bytes.each_with_index.map { |b, i| b ^ mask_key[i % 4] }

      frame = [0x81].pack("C") # FIN + text opcode
      if bytes.length < 126
        frame << [(bytes.length | 0x80)].pack("C")
      elsif bytes.length < 65536
        frame << [126 | 0x80].pack("C")
        frame << [bytes.length].pack("n")
      else
        frame << [127 | 0x80].pack("C")
        frame << [bytes.length].pack("Q>")
      end
      frame << mask_key.pack("C*")
      frame << masked.pack("C*")
      ssl.write(frame)
    end

    def send_ws_pong(ssl, payload)
      payload ||= ""
      bytes = payload.bytes
      mask_key = 4.times.map { rand(256) }
      masked = bytes.each_with_index.map { |b, i| b ^ mask_key[i % 4] }

      frame = [0x8A].pack("C") # FIN + pong opcode
      frame << [(bytes.length | 0x80)].pack("C")
      frame << mask_key.pack("C*")
      frame << masked.pack("C*")
      ssl.write(frame)
    end

    def send_ws_ping(ssl)
      mask_key = 4.times.map { rand(256) }
      frame = [0x89].pack("C") # FIN + ping opcode
      frame << [0x80].pack("C") # masked, zero-length payload
      frame << mask_key.pack("C*")
      ssl.write(frame)
    end

    # --- Slack Web API (minimal, uses Net::HTTP) ---

    def slack_api(method, token: @bot_token, **params)
      uri = URI("https://slack.com/api/#{method}")
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true

      if params.empty?
        req = Net::HTTP::Post.new(uri.path)
      else
        req = Net::HTTP::Post.new(uri.path)
        req.body = JSON.generate(params)
        req["Content-Type"] = "application/json; charset=utf-8"
      end
      req["Authorization"] = "Bearer #{token}"

      resp = http.request(req)
      JSON.parse(resp.body)
    rescue => e
      { "ok" => false, "error" => e.message }
    end

    def post_message(channel:, thread_ts:, text:)
      slack_api("chat.postMessage", channel: channel, thread_ts: thread_ts, text: text)
    end

    # --- Event handling ---

    def handle_event(msg)
      event = msg.dig(:payload, :event)
      return unless event
      return unless event[:type] == "message"

      # Ignore bot messages, subtypes (edits/deletes), own messages
      return if event[:bot_id]
      return if event[:user] == @bot_user_id
      return if event[:subtype]

      text = unescape_slack(event[:text])
      return unless text && !text.strip.empty?

      channel_id = event[:channel]
      return unless watched_channel?(channel_id)

      thread_ts = event[:thread_ts] || event[:ts]
      user_id = event[:user]
      user_name = resolve_user_name(user_id)

      allowed_list = Array(RailsConsoleAi.configuration.slack_allowed_usernames).map(&:to_s).map(&:downcase)
      unless allowed_list.include?('all') || allowed_list.include?(user_name.to_s.downcase)
        puts "[#{channel_id}/#{thread_ts}] @#{user_name} << (ignored — not in allowed usernames)"
        post_message(channel: channel_id, thread_ts: thread_ts, text: "Sorry, I don't recognize your username (@#{user_name}). Ask an admin to add you to the allowed usernames list.")
        return
      end

      puts "[#{channel_id}/#{thread_ts}] @#{user_name} << #{text.strip}"

      session = @mutex.synchronize { @sessions[thread_ts] }

      command = text.strip.downcase
      if command == 'cancel' || command == 'stop'
        cancel_session(session, channel_id, thread_ts)
        return
      end

      if command == 'clear'
        count = count_bot_messages(channel_id, thread_ts)
        if count == 0
          post_message(channel: channel_id, thread_ts: thread_ts, text: "No bot messages to clear.")
        else
          post_message(channel: channel_id, thread_ts: thread_ts,
            text: "This will permanently delete #{count} bot message#{'s' unless count == 1} from this thread. Type `clear!` to confirm.")
        end
        return
      end

      if command == 'clear!'
        cancel_session(session, channel_id, thread_ts) if session
        clear_bot_messages(channel_id, thread_ts)
        return
      end

      # Direct code execution: "> User.count" runs code without LLM
      if text.strip.start_with?('>')
        raw_code = text.strip.sub(/\A>\s*/, '')
        unless raw_code.empty?
          handle_direct_code(session, channel_id, thread_ts, raw_code, user_name)
          return
        end
      end

      if session
        handle_thread_reply(session, text.strip)
      else
        # New thread, or existing thread after bot restart — start a fresh session
        start_session(channel_id, thread_ts, text.strip, user_name)
      end
    rescue => e
      RailsConsoleAi.logger.error("SlackBot event handling error: #{e.class}: #{e.message}")
    end

    def start_session(channel_id, thread_ts, text, user_name)
      channel = Channel::Slack.new(
        slack_bot: self,
        channel_id: channel_id,
        thread_ts: thread_ts,
        user_name: user_name
      )

      sandbox_binding = Object.new.instance_eval { binding }
      engine = ConversationEngine.new(
        binding_context: sandbox_binding,
        channel: channel,
        slack_thread_ts: thread_ts
      )

      # Try to restore conversation history from a previous session (e.g. after bot restart)
      restored = restore_from_db(engine, thread_ts)

      session = { channel: channel, engine: engine, thread: nil }
      @mutex.synchronize { @sessions[thread_ts] = session }

      session[:thread] = Thread.new do
        Thread.current.report_on_exception = false
        Thread.current[:log_prefix] = "[#{channel_id}/#{thread_ts}] @#{user_name}"
        begin
          channel.display_dim("_session: #{channel_id}/#{thread_ts}_")
          if restored
            puts "Restored session for thread #{thread_ts} (#{engine.history.length} messages)"
            channel.display_dim("_(session restored — continuing from previous conversation)_")
          end
          engine.process_message(text)
        rescue => e
          channel.display_error("Error: #{e.class}: #{e.message}")
          RailsConsoleAi.logger.error("SlackBot session error: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        ensure
          ActiveRecord::Base.clear_active_connections! if defined?(ActiveRecord::Base)
        end
      end
    end

    def restore_from_db(engine, thread_ts)
      require 'rails_console_ai/session_logger'
      saved = SessionLogger.find_by_slack_thread(thread_ts)
      return false unless saved

      engine.init_interactive
      engine.restore_session(saved)
      true
    rescue => e
      RailsConsoleAi.logger.warn("SlackBot: failed to restore session for #{thread_ts}: #{e.message}")
      false
    end

    def handle_thread_reply(session, text)
      channel = session[:channel]
      engine = session[:engine]

      # If the engine is blocked waiting for user input (ask_user), push to queue
      if waiting_for_reply?(channel)
        channel.receive_reply(text)
        return
      end

      # Otherwise treat as a new message in the conversation
      session[:thread] = Thread.new do
        Thread.current.report_on_exception = false
        Thread.current[:log_prefix] = channel.instance_variable_get(:@log_prefix)
        begin
          engine.process_message(text)
        rescue => e
          channel.display_error("Error: #{e.class}: #{e.message}")
          RailsConsoleAi.logger.error("SlackBot session error: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        ensure
          ActiveRecord::Base.clear_active_connections! if defined?(ActiveRecord::Base)
        end
      end
    end

    def handle_direct_code(session, channel_id, thread_ts, raw_code, user_name)
      # Ensure a session exists for this thread
      unless session
        start_direct_session(channel_id, thread_ts, user_name)
        session = @mutex.synchronize { @sessions[thread_ts] }
      end

      channel = session[:channel]
      engine = session[:engine]

      session[:thread] = Thread.new do
        Thread.current.report_on_exception = false
        Thread.current[:log_prefix] = channel.instance_variable_get(:@log_prefix)
        begin
          engine.execute_direct(raw_code)
          # Post return value to Slack (execute_direct suppresses it via display_result no-op)
          result_value = engine.instance_variable_get(:@last_interactive_result)
          unless result_value.nil?
            display_text = "=> #{result_value}"
            display_text = display_text[0, 3000] + "\n... (truncated)" if display_text.length > 3000
            post_message(channel: channel_id, thread_ts: thread_ts, text: "```#{display_text}```")
          end
          engine.send(:log_interactive_turn)
        rescue => e
          channel.display_error("Error: #{e.class}: #{e.message}")
          RailsConsoleAi.logger.error("SlackBot direct code error: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        ensure
          ActiveRecord::Base.clear_active_connections! if defined?(ActiveRecord::Base)
        end
      end
    end

    def start_direct_session(channel_id, thread_ts, user_name)
      channel = Channel::Slack.new(
        slack_bot: self,
        channel_id: channel_id,
        thread_ts: thread_ts,
        user_name: user_name
      )

      sandbox_binding = Object.new.instance_eval { binding }
      engine = ConversationEngine.new(
        binding_context: sandbox_binding,
        channel: channel,
        slack_thread_ts: thread_ts
      )

      restore_from_db(engine, thread_ts)
      engine.init_interactive unless engine.instance_variable_get(:@interactive_start)

      session = { channel: channel, engine: engine, thread: nil }
      @mutex.synchronize { @sessions[thread_ts] = session }
    end

    def cancel_session(session, channel_id, thread_ts)
      if session
        session[:channel].cancel!
        session[:channel].display("Stopped.")
        puts "[#{channel_id}/#{thread_ts}] cancel requested"

        # Record stop in conversation history so restored sessions know
        # the previous topic was abandoned by the user
        engine = session[:engine]
        engine.history << { role: :user, content: "stop" }
        engine.history << { role: :assistant, content: "Stopped. Awaiting new instructions." }
        begin
          engine.send(:log_interactive_turn)
        rescue => e
          RailsConsoleAi.logger.warn("SlackBot: failed to save cancel state: #{e.message}")
        end
      else
        post_message(channel: channel_id, thread_ts: thread_ts, text: "No active session to stop.")
        puts "[#{channel_id}/#{thread_ts}] cancel: no session"
      end
      @mutex.synchronize { @sessions.delete(thread_ts) }
    end

    def count_bot_messages(channel_id, thread_ts)
      result = slack_get("conversations.replies", channel: channel_id, ts: thread_ts, limit: 200)
      return 0 unless result["ok"]
      (result["messages"] || []).count { |m| m["user"] == @bot_user_id }
    rescue
      0
    end

    def clear_bot_messages(channel_id, thread_ts)
      result = slack_get("conversations.replies", channel: channel_id, ts: thread_ts, limit: 200)
      unless result["ok"]
        puts "[#{channel_id}/#{thread_ts}] clear: failed to fetch replies: #{result["error"]}"
        return
      end

      bot_messages = (result["messages"] || []).select { |m| m["user"] == @bot_user_id }
      bot_messages.each do |m|
        puts "[#{channel_id}/#{thread_ts}] clearing #{channel_id.length} / #{m["ts"]}"
        slack_api("chat.delete", channel: channel_id, ts: m["ts"])
      end
      puts "[#{channel_id}/#{thread_ts}] cleared #{bot_messages.length} bot messages"
    rescue => e
      puts "[#{channel_id}/#{thread_ts}] clear failed: #{e.message}"
    end

    def slack_get(method, **params)
      uri = URI("https://slack.com/api/#{method}")
      uri.query = URI.encode_www_form(params)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = "Bearer #{@bot_token}"
      resp = http.request(req)
      JSON.parse(resp.body)
    rescue => e
      { "ok" => false, "error" => e.message }
    end

    def unescape_slack(text)
      return text unless text
      text.gsub("&amp;", "&").gsub("&lt;", "<").gsub("&gt;", ">")
          .gsub("\u2018", "'").gsub("\u2019", "'")   # smart single quotes → straight
          .gsub("\u201C", '"').gsub("\u201D", '"')    # smart double quotes → straight
    end

    def waiting_for_reply?(channel)
      channel.instance_variable_get(:@reply_queue).num_waiting > 0
    end

    def watched_channel?(channel_id)
      return true if @channel_ids.nil? || @channel_ids.empty?
      @channel_ids.include?(channel_id)
    end

    def resolve_channel_ids
      ids = RailsConsoleAi.configuration.slack_channel_ids || ENV['CONSOLE_AGENT_SLACK_CHANNELS']
      return nil if ids.nil?
      ids = ids.split(',').map(&:strip) if ids.is_a?(String)
      ids
    end

    def resolve_user_name(user_id)
      return @user_cache[user_id] if @user_cache.key?(user_id)

      # users.info requires form-encoded params, not JSON
      uri = URI("https://slack.com/api/users.info")
      uri.query = URI.encode_www_form(user: user_id)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = "Bearer #{@bot_token}"
      resp = http.request(req)
      result = JSON.parse(resp.body)

      name = result.dig("user", "profile", "display_name")
      name = result.dig("user", "real_name") if name.nil? || name.empty?
      name = result.dig("user", "name") if name.nil? || name.empty?
      @user_cache[user_id] = name || user_id
    rescue => e
      RailsConsoleAi.logger.warn("Failed to resolve user name for #{user_id}: #{e.message}")
      @user_cache[user_id] = user_id
    end

    def log_startup
      channel_info = if @channel_ids && !@channel_ids.empty?
                       "channels: #{@channel_ids.join(', ')}"
                     else
                       "all channels"
                     end
      puts "RailsConsoleAi SlackBot started (#{channel_info}, bot: #{@bot_user_id})"

      channel = Channel::Slack.new(slack_bot: self, channel_id: "boot", thread_ts: "boot")
      engine = ConversationEngine.new(
        binding_context: Object.new.instance_eval { binding },
        channel: channel
      )
      puts "\nFull system prompt for Slack sessions:"
      puts "-" * 60
      puts engine.context
      puts "-" * 60
      puts
    end
  end
end
