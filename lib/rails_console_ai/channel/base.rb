module RailsConsoleAi
  module Channel
    class Base
      def display(text);            raise NotImplementedError; end
      def display_dim(text);        raise NotImplementedError; end
      def display_warning(text);    raise NotImplementedError; end
      def display_error(text);      raise NotImplementedError; end
      def display_code(code);       raise NotImplementedError; end
      def display_result(text);     raise NotImplementedError; end
      def display_result_output(text); end  # stdout output from code execution
      def prompt(text);             raise NotImplementedError; end
      def confirm(text);            raise NotImplementedError; end
      def user_identity;            raise NotImplementedError; end
      def mode;                     raise NotImplementedError; end
      def cancelled?;               false; end
      def supports_danger?;         true; end
      def supports_editing?;        false; end
      def edit_code(code);          code; end
      def wrap_llm_call(&block);    yield; end
      def system_instructions;      nil; end
    end
  end
end
