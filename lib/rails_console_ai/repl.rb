require 'rails_console_ai/channel/console'
require 'rails_console_ai/conversation_engine'

module RailsConsoleAi
  class Repl
    def initialize(binding_context)
      @binding_context = binding_context
      @channel = Channel::Console.new
      @engine = ConversationEngine.new(binding_context: binding_context, channel: @channel)
    end

    def one_shot(query)
      @engine.one_shot(query)
    end

    def explain(query)
      @engine.explain(query)
    end

    def init_guide
      @engine.init_guide
    end

    def interactive
      @channel.interactive_loop(@engine)
    end

    def resume(session)
      @channel.resume_interactive(@engine, session)
    end

    # Expose engine internals for specs that inspect state
    def instance_variable_get(name)
      case name
      when :@history
        @engine.history
      when :@executor
        @engine.instance_variable_get(:@executor)
      else
        super
      end
    end

    # Allow specs to set internal state
    def instance_variable_set(name, value)
      case name
      when :@history
        @engine.instance_variable_set(:@history, value)
      else
        super
      end
    end

    private

    # Expose send methods for spec compatibility
    def send_query(query, conversation: nil)
      @engine.send(:send_query, query, conversation: conversation)
    end

    def trim_old_outputs(messages)
      @engine.send(:trim_old_outputs, messages)
    end
  end
end
