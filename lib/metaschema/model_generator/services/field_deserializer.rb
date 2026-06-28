# frozen_string_literal: true

module Metaschema
  class ModelGenerator
    module Services
      # Deserializes a field value from the source format into a model instance.
      # Handles SINGLETON_OR_ARRAY normalization and collapsible field expansion.
      #
      # Pipeline: normalize -> separate -> cast -> validate_collection -> transform
      class FieldDeserializer
        def initialize(model, attr, format, data, group_as:, collapsible:)
          @model = model
          @attribute = model.class.attributes[attr]
          @format = format
          @mapping_rule = model.class.mappings[format].mappings
            .find { |r| r.to == attr }
          @data = data
          @group_as = group_as
          @collapsible = collapsible
        end

        def self.call(...)
          new(...).call
        end

        def call
          data = normalize(@data)
          data = separate(data) if @collapsible
          data = cast(data)
          data = transform(data)
          data = unwrap_singleton(data)
          validate_collection!(data)

          @model.public_send(:"#{@attribute.name}=", data)
        end

        private

        # Wrap non-array data in an array for SINGLETON_OR_ARRAY fields.
        def normalize(data)
          if @group_as == "SINGLETON_OR_ARRAY" && !data.is_a?(Array)
            [data].compact
          else
            data
          end
        end

        # Expand collapsed items back into individual instances.
        # Collapsed data has array-valued non-collapsible attributes;
        # we expand each array position into a separate instance.
        def separate(data)
          data.each_with_object([]) do |item, results|
            size = item.each_value.find { |v| v.is_a?(Array) }&.size

            if size
              size.times do |index|
                results << item.transform_values do |v|
                  v.is_a?(Array) ? v[index] : v
                end
              end
            else
              results << item
            end
          end
        end

        def cast(data)
          opts = { polymorphic: @mapping_rule&.polymorphic }.compact
          @attribute.cast(data, @format, @model.lutaml_register, opts)
        end

        def validate_collection!(data)
          @attribute.valid_collection!(data, @model.class)
        end

        def transform(data)
          Lutaml::Model::ImportTransformer.call(data, @mapping_rule, @attribute)
        end

        # For SINGLETON_OR_ARRAY with non-collection attributes, unwrap
        # a single-element array back to a scalar value.
        def unwrap_singleton(data)
          return data unless data.is_a?(Array)
          return data unless @group_as == "SINGLETON_OR_ARRAY"
          return data if @attribute.collection

          data.one? ? data.first : data
        end
      end
    end
  end
end
