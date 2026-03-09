require 'fileutils'
require 'rails_console_ai/storage/base'

module RailsConsoleAi
  module Storage
    class FileStorage < Base
      attr_reader :root_path

      def initialize(root_path = nil)
        @root_path = root_path || default_root
      end

      def read(key)
        path = full_path(key)
        return nil unless File.exist?(path)
        File.read(path)
      end

      def write(key, content)
        path = full_path(key)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
        true
      rescue Errno::EACCES, Errno::EROFS, IOError => e
        raise StorageError, "Cannot write #{key}: #{e.message}"
      end

      def list(pattern)
        Dir.glob(File.join(@root_path, pattern)).sort.map do |path|
          path.sub("#{@root_path}/", '')
        end
      end

      def exists?(key)
        File.exist?(full_path(key))
      end

      def delete(key)
        path = full_path(key)
        return false unless File.exist?(path)
        File.delete(path)
        true
      rescue Errno::EACCES, Errno::EROFS, IOError => e
        raise StorageError, "Cannot delete #{key}: #{e.message}"
      end

      private

      def full_path(key)
        sanitized = key.gsub('..', '').gsub(%r{\A/+}, '')
        File.join(@root_path, sanitized)
      end

      def default_root
        if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
          File.join(Rails.root.to_s, '.rails_console_ai')
        else
          File.join(Dir.pwd, '.rails_console_ai')
        end
      end
    end
  end
end
