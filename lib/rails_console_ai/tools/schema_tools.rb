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
        conn = connection_for_table(table_name)
        unless conn.tables.include?(table_name)
          return "Table '#{table_name}' not found. Use list_tables to see available tables."
        end

        cols = conn.columns(table_name).map do |c|
          parts = ["#{c.name}:#{c.type}"]
          parts << "nullable" if c.null
          parts << "default=#{c.default}" unless c.default.nil?
          parts.join(" ")
        end

        indexes = conn.indexes(table_name).map do |idx|
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

      # Find the best connection for a table by checking if any model maps to it.
      # Models may use a different connection (e.g. sharded databases).
      def connection_for_table(table_name)
        if defined?(ActiveRecord::Base) && ActiveRecord::Base.is_a?(Class)
          base = defined?(ApplicationRecord) ? ApplicationRecord : ActiveRecord::Base
          model = ObjectSpace.each_object(Class).detect { |c|
            c < base && !c.abstract_class? && c.name &&
              begin; c.table_name == table_name; rescue; false; end
          }
          return model.connection if model
        end
        connection
      rescue
        connection
      end

      def connection
        ActiveRecord::Base.connection
      end
    end
  end
end
