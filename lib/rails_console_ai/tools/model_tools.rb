module RailsConsoleAi
  module Tools
    class ModelTools
      def list_models
        return "ActiveRecord is not available." unless defined?(ActiveRecord::Base)

        eager_load_app!
        models = find_models
        return "No models found." if models.empty?

        lines = models.map do |model|
          assoc_names = model.reflect_on_all_associations.map { |a| a.name.to_s }
          if assoc_names.empty?
            model.name
          else
            "#{model.name} (#{assoc_names.join(', ')})"
          end
        end

        lines.join("\n")
      rescue => e
        "Error listing models: #{e.message}"
      end

      def describe_model(model_name)
        return "ActiveRecord is not available." unless defined?(ActiveRecord::Base)
        return "Error: model_name is required." if model_name.nil? || model_name.strip.empty?

        eager_load_app!
        model_name = model_name.strip

        model = find_models.detect { |m| m.name == model_name || m.name.underscore == model_name.underscore }
        return "Model '#{model_name}' not found. Use list_models to see available models." unless model

        result = "Model: #{model.name}\n"
        result += "Table: #{model.table_name}\n"

        assocs = model.reflect_on_all_associations.map { |a| "#{a.macro} :#{a.name}" }
        unless assocs.empty?
          result += "Associations:\n"
          assocs.each { |a| result += "  #{a}\n" }
        end

        begin
          validators = model.validators.map { |v|
            attrs = v.attributes.join(', ')
            kind = v.class.name.split('::').last.sub('Validator', '').downcase
            "#{kind} on #{attrs}"
          }.uniq
          unless validators.empty?
            result += "Validations:\n"
            validators.each { |v| result += "  #{v}\n" }
          end
        rescue => e
          # validations may not be accessible
        end

        # Scopes - detect via singleton methods that aren't inherited
        begin
          base = defined?(ApplicationRecord) ? ApplicationRecord : ActiveRecord::Base
          scope_candidates = (model.singleton_methods - base.singleton_methods)
            .reject { |m| m.to_s.start_with?('_') || m.to_s.start_with?('find') }
            .sort
            .first(20)
          unless scope_candidates.empty?
            result += "Possible scopes/class methods:\n"
            scope_candidates.each { |s| result += "  #{s}\n" }
          end
        rescue => e
          # ignore
        end

        result
      rescue => e
        "Error describing model '#{model_name}': #{e.message}"
      end

      private

      def find_models
        base_class = defined?(ApplicationRecord) ? ApplicationRecord : ActiveRecord::Base
        ObjectSpace.each_object(Class).select { |c|
          c < base_class && !c.abstract_class? && c.name && !c.name.start_with?('HABTM_')
        }.sort_by(&:name)
      end

      def eager_load_app!
        return unless defined?(Rails) && Rails.respond_to?(:application)
        Rails.application.eager_load! if Rails.application.respond_to?(:eager_load!)
      rescue => e
        # ignore
      end
    end
  end
end
