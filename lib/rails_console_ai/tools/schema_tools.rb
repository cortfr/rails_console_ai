module RailsConsoleAi
  module Tools
    class SchemaTools
      def list_tables
        return "ActiveRecord is not connected." unless ar_connected?

        tables = connection.tables.sort
        tables.reject! { |t| t == 'schema_migrations' || t == 'ar_internal_metadata' }
        return "No tables found." if tables.empty?

        tables.join(", ")
      rescue => e
        "Error listing tables: #{e.message}"
      end

      def describe_table(table_name)
        return "ActiveRecord is not connected." unless ar_connected?
        return "Error: table_name is required." if table_name.nil? || table_name.strip.empty?

        table_name = table_name.strip
        unless connection.tables.include?(table_name)
          return "Table '#{table_name}' not found. Use list_tables to see available tables."
        end

        cols = connection.columns(table_name).map do |c|
          parts = ["#{c.name}:#{c.type}"]
          parts << "nullable" if c.null
          parts << "default=#{c.default}" unless c.default.nil?
          parts.join(" ")
        end

        indexes = connection.indexes(table_name).map do |idx|
          unique = idx.unique ? "UNIQUE " : ""
          "#{unique}INDEX on (#{idx.columns.join(', ')})"
        end

        result = "Table: #{table_name}\n"
        result += "Columns:\n"
        cols.each { |c| result += "  #{c}\n" }
        unless indexes.empty?
          result += "Indexes:\n"
          indexes.each { |i| result += "  #{i}\n" }
        end
        result
      rescue => e
        "Error describing table '#{table_name}': #{e.message}"
      end

      private

      def ar_connected?
        defined?(ActiveRecord::Base) && ActiveRecord::Base.connected?
      end

      def connection
        ActiveRecord::Base.connection
      end
    end
  end
end
