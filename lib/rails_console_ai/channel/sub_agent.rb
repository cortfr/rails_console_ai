require 'rails_console_ai/channel/base'

module RailsConsoleAi
  module Channel
    class SubAgent < Base
      def initialize(parent_channel:, task_label: nil)
        @parent = parent_channel
        @label = task_label
      end

      def display(text)
        # Swallowed — sub-agent final text is returned as tool result, not displayed
      end

      def display_thinking(text)
        # Swallowed
      end

      def display_status(text)
        stripped = text.to_s.strip
        return if stripped.empty?
        @parent.display_status("  [sub-agent#{@label ? ": #{@label}" : ""}] #{stripped}")
      end

      def display_warning(text)
        # Swallowed
      end

      def display_error(text)
        display_status("error: #{text}")
      end

      def display_tool_call(text)
        display_status("-> #{text}")
      end

      def display_code(code)
        # Swallowed — sub-agent auto-executes, no need to show code
      end

      def display_result_output(output)
        # Swallowed
      end

      def display_result(result)
        # Swallowed
      end

      def prompt(text)
        '(sub-agent cannot ask user)'
      end

      def confirm(text)
        'y'
      end

      def user_identity
        @parent.user_identity
      end

      def mode
        'sub_agent'
      end

      def cancelled?
        @parent.cancelled?
      end

      def supports_danger?
        false  # Sub-agents must never silently bypass safety guards
      end

      def supports_editing?
        false
      end

      def wrap_llm_call(&block)
        yield
      end

      def system_instructions
        nil
      end
    end
  end
end
