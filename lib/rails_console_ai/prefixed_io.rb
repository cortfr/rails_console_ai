module RailsConsoleAi
  class PrefixedIO
    def initialize(io)
      @io = io
    end

    def write(str)
      prefix = Thread.current[:log_prefix]
      if prefix && str.is_a?(String) && !str.strip.empty?
        prefixed = str.gsub(/^(?=.)/, "#{prefix} ")
        @io.write(prefixed)
      else
        @io.write(str)
      end
    end

    def puts(*args)
      prefix = Thread.current[:log_prefix]
      if prefix
        args = [""] if args.empty?
        args.each do |a|
          line = a.to_s
          if line.strip.empty?
            @io.write("\n")
          else
            @io.write("#{prefix} #{line}\n")
          end
        end
      else
        @io.puts(*args)
      end
    end

    def print(*args)
      @io.print(*args)
    end

    def flush
      @io.flush
    end

    def respond_to_missing?(method, include_private = false)
      @io.respond_to?(method, include_private) || super
    end

    def method_missing(method, *args, &block)
      @io.send(method, *args, &block)
    end
  end
end
