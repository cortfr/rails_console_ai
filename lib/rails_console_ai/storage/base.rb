module RailsConsoleAi
  module Storage
    class StorageError < StandardError; end

    class Base
      def read(key)
        raise NotImplementedError
      end

      def write(key, content)
        raise NotImplementedError
      end

      def list(pattern)
        raise NotImplementedError
      end

      def exists?(key)
        raise NotImplementedError
      end

      def delete(key)
        raise NotImplementedError
      end
    end
  end
end
