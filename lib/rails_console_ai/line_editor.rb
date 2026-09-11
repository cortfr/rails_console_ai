module RailsConsoleAi
  # Thin adapters over the two line editors we can drive, so the interactive loop
  # doesn't care which one is underneath.
  #
  # Reline (bundled with Ruby >= 2.7) is preferred: it renders a live completion
  # dropdown as you type, which is what makes "/" discoverable. Readline is the
  # fallback and only offers Tab completion.
  #
  # The two differ in four ways that matter here, all absorbed by the adapters:
  #   - prompt escaping: Readline needs \001..\002 around ANSI so it can compute
  #     the prompt width; Reline parses ANSI itself and would print those literally.
  #   - output: Reline writes through a Ruby IO, so it has to be pointed at the real
  #     stdout — otherwise the dropdown's escape codes land in the captured session log.
  #     Readline writes to its own C-level stream and bypasses $stdout entirely.
  #   - key binding: Readline has parse_and_bind, Reline has add_default_key_binding.
  #   - what a completion candidate may contain: see #matches in each adapter.
  module LineEditor
    # Shift-Tab: jump to line start, kill the line, type /auto, submit.
    # Reline binds real bytes; Readline's inputrc parser wants the escapes
    # un-interpreted, so it gets the backslash form verbatim.
    SHIFT_TAB   = "\e[Z".freeze
    AUTO_MACRO  = "\C-a\C-k/auto\C-m".freeze
    INPUTRC_BIND = '"\e[Z": "\C-a\C-k/auto\C-m"'.freeze

    def self.resolve(preference = nil, output: nil)
      preference = (preference || :auto).to_sym
      editor =
        case preference
        when :readline then readline_adapter
        when :reline   then reline_adapter || readline_adapter
        else reline_adapter || readline_adapter
        end
      editor.output = output if output && editor.respond_to?(:output=)
      editor
    end

    def self.reline_adapter
      require 'reline'
      Reline.respond_to?(:autocompletion=) ? Reline_.new : nil
    rescue LoadError
      nil
    end

    def self.readline_adapter
      require 'readline'
      Readline_.new
    end

    class Base
      def name; self.class.name.split('::').last.chomp('_').downcase; end

      # Candidates come from a proc so the list stays live — skills and agents can
      # be created mid-session. The proc returns [slug, label] pairs, where the
      # label says what kind of thing the slug is ("command", "skill", "agent").
      def complete_with(&candidates); @candidates = candidates; self; end

      def matches(target)
        matching(target).map(&:first)
      end

      private

      def matching(target)
        return [] unless target.to_s.start_with?('/')
        entries = @candidates ? @candidates.call : []
        entries.select { |slug, _| slug.start_with?(target) }
      end
    end

    class Reline_ < Base
      def initialize
        Reline.autocompletion = true
        Reline.completion_append_character = ' '
        Reline.completion_proc = ->(target) { matches(target) }
      end

      def output=(io); Reline.output = io; end

      def prompt(text, color)
        "#{color}#{text}\e[0m"
      end

      def readline(prompt)
        Reline.readline(prompt, false)
      end

      def push_history(line)
        Reline::HISTORY.push(line) unless line == Reline::HISTORY.to_a.last
      end

      def bind_auto_toggle
        Reline.core.config.add_default_key_binding(SHIFT_TAB.bytes, AUTO_MACRO.bytes)
      rescue StandardError
        nil
      end

      # Reline's menu inserts whichever row you arrow onto, verbatim, so a
      # candidate has to be exactly the text that belongs in the buffer. No labels.
    end

    class Readline_ < Base
      def initialize
        Readline.completion_append_character = ' '
        Readline.completion_proc = ->(target) { matches(target) }
      end

      def prompt(text, color)
        "\001#{color}\002#{text}\001\e[0m\002"
      end

      def readline(prompt)
        Readline.readline(prompt, false)
      end

      def push_history(line)
        Readline::HISTORY.push(line) unless line == Readline::HISTORY.to_a.last
      end

      def bind_auto_toggle
        return unless Readline.respond_to?(:parse_and_bind)
        Readline.parse_and_bind(INPUTRC_BIND)
      end

      # Readline only ever inserts the common prefix of the candidates it is given,
      # and displays the rest for the eye alone — so when there is more than one
      # match we can append a kind label without it ever reaching the buffer. That
      # is what makes a built-in command distinguishable from a skill or an agent
      # in the Tab list. The labels sit past the point where the slugs diverge, so
      # they can't lengthen the common prefix either.
      #
      # A lone match is different: there the common prefix IS the whole candidate,
      # so it must be the bare slug, and Readline appends its trailing space.
      def matches(target)
        found = matching(target)
        return found.map(&:first) if found.size <= 1

        width = found.map { |slug, _| slug.length }.max + 2
        found.map { |slug, label| "#{slug.ljust(width)}#{label}" }
      end
    end
  end
end
