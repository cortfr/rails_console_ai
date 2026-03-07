require 'json'
require 'uri'
require 'net/http'
require 'openssl'
require 'console_agent/channel/slack'
require 'console_agent/conversation_engine'
require 'console_agent/context_builder'
require 'console_agent/providers/base'
require 'console_agent/executor'

module ConsoleAgent
  class SlackBot
    def initialize
      @bot_token = ConsoleAgent.configuration.slack_bot_token || ENV['SLACK_BOT_TOKEN']
      @app_token = ConsoleAgent.configuration.slack_app_token || ENV['SLACK_APP_TOKEN']
      @channel_ids = resolve_channel_ids

      raise ConfigurationError, "SLACK_BOT_TOKEN is required" unless @bot_token
      raise ConfigurationError, "SLACK_APP_TOKEN is required (Socket Mode)" unless @app_token

      @bot_user_id = nil
      @sessions = {}       # thread_ts → { channel:, engine:, thread: }
      @user_cache = {}     # slack user_id → display_name
      @mutex = Mutex.new
    end

    def start
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

      # Main read loop
      loop do
        data = read_ws_frame(ssl)
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
        send_ws_pong(ssl, payload)
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

      text = event[:text]
      return unless text && !text.strip.empty?

      channel_id = event[:channel]
      return unless watched_channel?(channel_id)

      thread_ts = event[:thread_ts] || event[:ts]
      user_id = event[:user]
      user_name = resolve_user_name(user_id)

      puts "[#{channel_id}/#{thread_ts}] @#{user_name} << #{text.strip}"

      session = @mutex.synchronize { @sessions[thread_ts] }

      if text.strip.downcase == 'cancel' || text.strip.downcase == 'stop'
        cancel_session(session, channel_id, thread_ts)
        return
      end

      if session
        handle_thread_reply(session, text.strip)
      else
        # New thread, or existing thread after bot restart — start a fresh session
        start_session(channel_id, thread_ts, text.strip, user_name)
      end
    rescue => e
      ConsoleAgent.logger.error("SlackBot event handling error: #{e.class}: #{e.message}")
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
        begin
          channel.display_dim("_session: #{channel_id}/#{thread_ts}_")
          if restored
            puts "Restored session for thread #{thread_ts} (#{engine.history.length} messages)"
            channel.display_dim("_(session restored — continuing from previous conversation)_")
          end
          engine.process_message(text)
        rescue => e
          channel.display_error("Error: #{e.class}: #{e.message}")
          ConsoleAgent.logger.error("SlackBot session error: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        ensure
          ActiveRecord::Base.clear_active_connections! if defined?(ActiveRecord::Base)
        end
      end
    end

    def restore_from_db(engine, thread_ts)
      require 'console_agent/session_logger'
      saved = SessionLogger.find_by_slack_thread(thread_ts)
      return false unless saved

      engine.init_interactive
      engine.restore_session(saved)
      true
    rescue => e
      ConsoleAgent.logger.warn("SlackBot: failed to restore session for #{thread_ts}: #{e.message}")
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
        begin
          engine.process_message(text)
        rescue => e
          channel.display_error("Error: #{e.class}: #{e.message}")
          ConsoleAgent.logger.error("SlackBot session error: #{e.class}: #{e.message}\n#{e.backtrace.first(5).join("\n")}")
        ensure
          ActiveRecord::Base.clear_active_connections! if defined?(ActiveRecord::Base)
        end
      end
    end

    def cancel_session(session, channel_id, thread_ts)
      if session
        session[:channel].cancel!
        session[:channel].display("Stopped.")
        puts "[#{channel_id}/#{thread_ts}] cancel requested"
      else
        post_message(channel: channel_id, thread_ts: thread_ts, text: "No active session to stop.")
        puts "[#{channel_id}/#{thread_ts}] cancel: no session"
      end
      @mutex.synchronize { @sessions.delete(thread_ts) }
    end

    def waiting_for_reply?(channel)
      channel.instance_variable_get(:@reply_queue).num_waiting > 0
    end

    def watched_channel?(channel_id)
      return true if @channel_ids.nil? || @channel_ids.empty?
      @channel_ids.include?(channel_id)
    end

    def resolve_channel_ids
      ids = ConsoleAgent.configuration.slack_channel_ids || ENV['CONSOLE_AGENT_SLACK_CHANNELS']
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
      ConsoleAgent.logger.warn("Failed to resolve user name for #{user_id}: #{e.message}")
      @user_cache[user_id] = user_id
    end

    def log_startup
      channel_info = if @channel_ids && !@channel_ids.empty?
                       "channels: #{@channel_ids.join(', ')}"
                     else
                       "all channels"
                     end
      puts "ConsoleAgent SlackBot started (#{channel_info}, bot: #{@bot_user_id})"

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
