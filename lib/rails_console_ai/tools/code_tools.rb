module RailsConsoleAi
  module Tools
    class CodeTools
      MAX_FILE_LINES = 500
      MAX_LIST_ENTRIES = 100
      MAX_SEARCH_RESULTS = 50

      def list_files(directory = nil)
        directory = sanitize_directory(directory || 'app')
        root = rails_root
        return "Rails.root is not available." unless root

        full_path = File.join(root, directory)
        return "Directory '#{directory}' not found." unless File.directory?(full_path)

        files = Dir.glob(File.join(full_path, '**', '*.rb')).sort
        files = files.map { |f| f.sub("#{root}/", '') }

        if files.length > MAX_LIST_ENTRIES
          truncated = files.first(MAX_LIST_ENTRIES)
          truncated.join("\n") + "\n... and #{files.length - MAX_LIST_ENTRIES} more files"
        elsif files.empty?
          "No Ruby files found in '#{directory}'."
        else
          files.join("\n")
        end
      rescue => e
        "Error listing files: #{e.message}"
      end

      def read_file(path, start_line: nil, end_line: nil)
        return "Error: path is required." if path.nil? || path.strip.empty?

        root = rails_root
        return "Rails.root is not available." unless root

        path = sanitize_path(path)
        full_path = File.expand_path(File.join(root, path))

        # Security: ensure resolved path is under Rails.root
        unless full_path.start_with?(File.expand_path(root))
          return "Error: path must be within the Rails application."
        end

        return "File '#{path}' not found." unless File.exist?(full_path)
        return "Error: '#{path}' is a directory, not a file." if File.directory?(full_path)

        all_lines = File.readlines(full_path)
        total = all_lines.length

        # Apply line range if specified (1-based, inclusive)
        if start_line || end_line
          s = [(start_line || 1).to_i, 1].max
          e = [(end_line || total).to_i, total].min
          return "Error: start_line (#{s}) is beyond end of file (#{total} lines)." if s > total
          lines = all_lines[(s - 1)..(e - 1)] || []
          offset = s - 1
          numbered = lines.each_with_index.map { |line, i| "#{offset + i + 1}: #{line}" }
          header = "Lines #{s}-#{[e, s + lines.length - 1].min} of #{total}:\n"
          header + numbered.join
        elsif total > MAX_FILE_LINES
          numbered = all_lines.first(MAX_FILE_LINES).each_with_index.map { |line, i| "#{i + 1}: #{line}" }
          numbered.join + "\n... truncated (#{total} total lines, showing first #{MAX_FILE_LINES}). Use start_line/end_line to read specific sections."
        else
          all_lines.each_with_index.map { |line, i| "#{i + 1}: #{line}" }.join
        end
      rescue => e
        "Error reading file '#{path}': #{e.message}"
      end

      def search_code(query, directory = nil)
        return "Error: query is required." if query.nil? || query.strip.empty?

        directory = sanitize_directory(directory || 'app')
        root = rails_root
        return "Rails.root is not available." unless root

        full_path = File.join(root, directory)
        return "Directory '#{directory}' not found." unless File.directory?(full_path)

        results = []
        Dir.glob(File.join(full_path, '**', '*.rb')).sort.each do |file|
          break if results.length >= MAX_SEARCH_RESULTS

          relative = file.sub("#{root}/", '')
          File.readlines(file).each_with_index do |line, idx|
            if line.include?(query)
              results << "#{relative}:#{idx + 1}: #{line.strip}"
              break if results.length >= MAX_SEARCH_RESULTS
            end
          end
        rescue => e
          # skip unreadable files
        end

        if results.empty?
          "No matches found for '#{query}' in #{directory}/."
        else
          header = "Found #{results.length} match#{'es' if results.length != 1}:\n"
          header + results.join("\n")
        end
      rescue => e
        "Error searching: #{e.message}"
      end

      private

      def rails_root
        if defined?(Rails) && Rails.respond_to?(:root) && Rails.root
          Rails.root.to_s
        else
          nil
        end
      end

      def sanitize_path(path)
        # Remove leading slashes and ../ sequences
        path.strip.gsub(/\A\/+/, '').gsub(/\.\.\//, '').gsub(/\.\.\\/, '')
      end

      def sanitize_directory(dir)
        sanitize_path(dir || 'app')
      end
    end
  end
end
