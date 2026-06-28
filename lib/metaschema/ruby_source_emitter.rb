# frozen_string_literal: true

module Metaschema
  # Emits Ruby source code from generated metaschema classes.
  #
  # After ModelGenerator#generate creates in-memory classes, this class
  # introspects them and emits equivalent Ruby source code that can be
  # saved to .rb files and loaded with `require`.
  #
  # Handles three kinds of type references:
  # 1. Builtin types (:string, :integer, etc.) — emitted as symbol literals
  # 2. Generated types (in @classes) — emitted as fully-qualified string refs
  # 3. Framework types (named, from other gems) — emitted as bare class refs
  # 4. Anonymous inline types — collected and emitted as separate named classes
  #
  # Usage:
  #   files = Metaschema::ModelGenerator.to_ruby_source(
  #     "oscal_complete_metaschema.xml",
  #     module_name: "Oscal::V1_2_1"
  #   )
  #   files.each { |name, source| File.write(name, source) }
  #
  class RubySourceEmitter
    BUILTIN_TYPES = %i[string integer boolean float date time datetime
                       symbol].freeze
    RESERVED_CLASS_NAMES = %w[Base Hash Method Object Class Module].freeze

    def initialize(classes, module_name, generator)
      @classes = classes
      @module_name = module_name
      @generator = generator
      @class_name_cache = {}
      @anon_name_map = {} # anonymous class → assigned name
    end

    def emit
      sorted = sort_classes
      collect_anonymous_types(sorted)
      files = {}

      source = emit_module_header

      # Emit anonymous types first (they're dependencies of named classes)
      @anon_name_map.each_value do |anon_name|
        anon_class = @anon_name_map.key(anon_name)
        source += "\n#{emit_anonymous_class(anon_name, anon_class)}"
      end

      sorted.each do |key, klass|
        next unless klass.is_a?(Class) && klass < Lutaml::Model::Serializable

        source += "\n#{emit_class(key, klass)}"
      end
      source += emit_module_footer
      files["all_models.rb"] = source

      files
    end

    # Emit as separate files per root model type.
    def emit_split
      sorted = sort_classes
      collect_anonymous_types(sorted)
      root_classes = find_root_classes
      emitted = Set.new
      files = {}

      root_classes.each do |root_key, root_klass|
        deps = find_dependencies(root_key, root_klass)
        all_keys = ([root_key] + deps).uniq

        source = emit_module_header

        # Emit anonymous types needed by this root's dependency tree
        emit_anon_deps_for(all_keys, source)

        all_keys.each do |key|
          klass = @classes[key]
          next unless klass.is_a?(Class) && klass < Lutaml::Model::Serializable
          next if emitted.include?(key)

          source += "\n#{emit_class(key, klass)}"
          emitted.add(key)
        end
        source += emit_module_footer

        filename = clean_class_name(root_key).gsub(/([a-z])([A-Z])/,
                                                   '\1_\2').downcase + ".rb"
        files[filename] = source
      end

      # Emit any remaining classes not covered by roots
      remaining = sorted.except(*emitted)
      unless remaining.empty?
        source = emit_module_header
        remaining.each do |key, klass|
          next unless klass.is_a?(Class) && klass < Lutaml::Model::Serializable

          source += "\n#{emit_class(key, klass)}"
        end
        source += emit_module_footer
        files["common.rb"] = source
      end

      files
    end

    private

    def collect_anonymous_types(sorted)
      used_names = Set.new(sorted.map { |key, _| clean_class_name(key) })

      sorted.each do |key, klass|
        next unless klass.is_a?(Class) && klass < Lutaml::Model::Serializable

        klass.attributes.each do |attr_name, attr|
          type = attr.type
          next unless type.is_a?(Class) && type < Lutaml::Model::Serializable
          next if @anon_name_map.key?(type)
          next if @classes.any? { |_, v| v == type }
          next if type.name && !type.name.empty? # Named framework type

          # Anonymous inline type — assign a name
          parent_name = clean_class_name(key)
          base = "#{parent_name}#{camelize(attr_name.to_s)}"
          name = base
          suffix = 2
          while used_names.include?(name)
            name = "#{base}#{suffix}"
            suffix += 1
          end
          used_names.add(name)
          @anon_name_map[type] = name
        end
      end
    end

    def emit_anon_deps_for(keys, source)
      # Find anonymous types referenced by these classes
      keys.each do |key|
        klass = @classes[key]
        next unless klass

        klass.attributes.each_value do |attr|
          type = attr.type
          next unless type.is_a?(Class) && type < Lutaml::Model::Serializable

          anon_name = @anon_name_map[type]
          next unless anon_name

          source += "\n#{emit_anonymous_class(anon_name, type)}"
        end
      end
    end

    def sort_classes
      flags = []
      fields = []
      assemblies = []

      @classes.each do |key, klass|
        case key
        when /\AFlag_/ then flags << [key, klass]
        when /\AField_/ then fields << [key, klass]
        when /\AAssembly_/ then assemblies << [key, klass]
        end
      end

      flags + fields + assemblies
    end

    def find_root_classes
      @classes.select do |key, klass|
        next unless key.start_with?("Assembly_")

        klass.instance_variable_defined?(:@json_root_name) &&
          klass.instance_variable_get(:@json_root_name)
      end
    end

    def find_dependencies(_root_key, root_klass)
      deps = Set.new
      queue = [root_klass]

      while (klass = queue.shift)
        klass.attributes.each_value do |attr|
          type = attr.type
          next unless type.is_a?(Class) && type < Lutaml::Model::Serializable
          next if type == klass

          type_key = @classes.find { |_k, v| v == type }&.first
          next unless type_key
          next if deps.include?(type_key)

          deps.add(type_key)
          queue << type
        end
      end

      deps.to_a
    end

    def clean_class_name(key)
      parts = key.sub(/\A(Assembly|Field|Flag)_/, "").split("_")
      name = parts.map(&:capitalize).join
      name = "#{name}Field" if RESERVED_CLASS_NAMES.include?(name)
      name
    end

    def camelize(str)
      str.split("_").map(&:capitalize).join
    end

    def type_reference(attr)
      type = attr.type
      if type.is_a?(Symbol) || BUILTIN_TYPES.include?(type)
        ":#{type}"
      elsif type.is_a?(Class) && type < Lutaml::Model::Serializable
        key = @classes.find { |_, v| v == type }&.first
        if key
          # Generated type — use symbol for register-swappability
          ":#{snake_case(clean_class_name(key))}"
        elsif @anon_name_map.key?(type)
          # Anonymous inline type — use symbol with assigned name
          ":#{snake_case(@anon_name_map[type])}"
        elsif type.name && !type.name.empty?
          # Framework type from another gem — use bare class reference
          type.name.to_s
        else
          ":string"
        end
      else
        ":string"
      end
    end

    # Returns fully-qualified class name for use in method bodies (no quotes).
    def type_constant(attr)
      type = attr.type
      if type.is_a?(Class) && type < Lutaml::Model::Serializable
        key = @classes.find { |_, v| v == type }&.first
        if key
          "#{@module_name}::#{clean_class_name(key)}"
        elsif @anon_name_map.key?(type)
          "#{@module_name}::#{@anon_name_map[type]}"
        else
          type_name = type.name
          type_name && !type_name.empty? ? type_name : nil
        end
      end
    end

    def snake_case(str)
      str
        .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
        .gsub(/([a-z\d])([A-Z])/, '\1_\2')
        .downcase
    end

    def emit_module_header
      register_id = derive_register_id
      ns_uri = @generator.namespace
      ns_block = if ns_uri && !ns_uri.empty?
                   <<~NS.gsub(/^/, "  ")

                     class ModuleNamespace < Lutaml::Xml::Namespace
                       uri "#{ns_uri}"
                       prefix_default ""
                     end
                   NS
                 else
                   ""
                 end

      <<~RUBY
        # frozen_string_literal: true

        require "metaschema"

        module #{@module_name}
          class Base < Lutaml::Model::Serializable
            def self.lutaml_default_register
              :#{register_id}
            end
          end
        #{ns_block}
      RUBY
    end

    def derive_register_id
      if @module_name.include?("::")
        parts = @module_name.split("::")
        ns = parts[0].downcase
        ver = parts[1..].join("_").downcase.gsub(/^v/, "")
        "#{ns}_#{ver}"
      else
        @module_name.downcase
      end
    end

    def emit_module_footer
      "\nend\n"
    end

    def emit_class(key, klass)
      name = clean_class_name(key)
      emit_named_class(name, klass)
    end

    def emit_anonymous_class(name, klass)
      emit_named_class(name, klass)
    end

    def emit_named_class(name, klass)
      lines = []
      lines << "  class #{name} < Base"

      # Attributes
      klass.attributes.each do |attr_name, attr|
        type_ref = type_reference(attr)
        opts = []
        opts << "collection: true" if attr.collection
        lines << if opts.any?
                   "    attribute :#{attr_name}, #{type_ref}, #{opts.join(', ')}"
                 else
                   "    attribute :#{attr_name}, #{type_ref}"
                 end
      end

      # XML mapping
      xml_source = emit_xml_mapping(klass)
      lines.concat(xml_source) if xml_source

      # Delegated XML mappings (applied at runtime after register init)
      delegated = emit_delegated_xml_mappings(klass)
      lines.concat(delegated) if delegated

      # Key-value mapping
      kv_source = emit_key_value_mapping(klass)
      lines.concat(kv_source) if kv_source

      # Custom methods for with: callbacks
      custom_methods = emit_custom_methods(klass)
      lines.concat(custom_methods) if custom_methods.any?

      # Root wrapping methods
      root_methods = emit_root_wrapping(klass)
      lines.concat(root_methods) if root_methods.any?

      # Constraint validation methods
      constraint_methods = emit_constraint_methods(klass)
      lines.concat(constraint_methods) if constraint_methods.any?

      # Occurrence validation
      occ_methods = emit_occurrence_validation(klass)
      lines.concat(occ_methods) if occ_methods

      lines << "  end"
      lines.join("\n")
    end

    def emit_xml_mapping(klass)
      xml_map = begin
        klass.mappings_for(:xml)
      rescue StandardError
        nil
      end
      return nil unless xml_map

      lines = []
      lines << ""
      lines << "    xml do"

      element_name = xml_map.instance_variable_get(:@element_name)
      lines << "      element \"#{element_name}\"" if element_name

      ns_uri = @generator.namespace
      lines << "      namespace ModuleNamespace" if ns_uri && !ns_uri.empty?

      if xml_map.instance_variable_get(:@mixed_content)
        lines << "      mixed_content"
      end

      if xml_map.instance_variable_get(:@ordered)
        lines << "      ordered"
      end

      # Content mapping (skip delegated — applied at runtime after register init)
      content = xml_map.instance_variable_get(:@content_mapping)
      if content && !content.delegate
        opts = ["to: :#{content.to}"]
        lines << "      map_content #{opts.join(', ')}"
      end

      # Attribute mappings (skip delegated)
      xml_map.instance_variable_get(:@attributes)&.each do |xml_name, rule|
        next if rule.delegate

        local_name = xml_name.include?(":") ? xml_name.split(":").last : xml_name
        opts = ["\"#{local_name}\"", "to: :#{rule.to}"]
        lines << "      map_attribute #{opts.join(', ')}"
      end

      # Element mappings (skip delegated, strip namespace prefix)
      xml_map.instance_variable_get(:@elements)&.each do |xml_name, rule|
        next if rule.delegate

        local_name = xml_name.include?(":") ? xml_name.split(":").last : xml_name
        opts = ["\"#{local_name}\"", "to: :#{rule.to}"]
        lines << "      map_element #{opts.join(', ')}"
      end

      lines << "    end"
      lines
    end

    def emit_delegated_xml_mappings(klass)
      xml_map = begin
        klass.mappings_for(:xml)
      rescue StandardError
        nil
      end
      return nil unless xml_map

      delegations = []

      content = xml_map.instance_variable_get(:@content_mapping)
      if content&.delegate
        delegations << { type: :content, to: content.to, delegate: content.delegate }
      end

      xml_map.instance_variable_get(:@elements)&.each do |xml_name, rule|
        next unless rule.delegate

        local_name = xml_name.include?(":") ? xml_name.split(":").last : xml_name
        delegations << { type: :element, name: local_name, to: rule.to, delegate: rule.delegate }
      end

      return nil if delegations.empty?

      lines = []
      lines << ""
      lines << "    def self.apply_xml_delegations"
      lines << "      xml_mapping = mappings[:xml]"
      delegations.each do |d|
        if d[:type] == :content
          lines << "      xml_mapping.map_content to: :#{d[:to]}, delegate: :#{d[:delegate]}"
        else
          lines << "      xml_mapping.map_element \"#{d[:name]}\", to: :#{d[:to]}, delegate: :#{d[:delegate]}"
        end
      end
      lines << "    end"
      lines
    end

    def emit_key_value_mapping(klass)
      kv_map = begin
        klass.mappings_for(:json)
      rescue StandardError
        nil
      end
      return nil unless kv_map

      mappings = kv_map.instance_variable_get(:@mappings)
      return nil unless mappings && !mappings.empty?

      lines = []
      lines << ""
      lines << "    key_value do"

      root_name = kv_map.instance_variable_get(:@root_name)
      lines << "      root \"#{root_name}\"" if root_name && !root_name.empty?

      mappings.each do |json_name, rule|
        custom = rule.custom_methods
        if custom && (custom[:from] || custom[:to])
          opts = []
          opts << "to: :#{rule.to}"
          opts_parts = ["with: { "]
          with_parts = []
          with_parts << "to: :#{custom[:to]}" if custom[:to]
          with_parts << "from: :#{custom[:from]}" if custom[:from]
          opts_parts << with_parts.join(", ")
          opts_parts << " }"
          opts << opts_parts.join
          lines << "      map \"#{json_name}\", #{opts.join(', ')}"
        else
          render_empty = rule.instance_variable_get(:@render_empty)
          lines << if render_empty
                     "      map \"#{json_name}\", to: :#{rule.to}, render_empty: true"
                   else
                     "      map \"#{json_name}\", to: :#{rule.to}"
                   end
        end
      end

      lines << "    end"
      lines
    end

    def emit_custom_methods(klass)
      methods = []
      custom_method_names = (klass.instance_methods(false) - Lutaml::Model::Serializable.instance_methods)
        .select { |m| m.to_s.start_with?("json_") }

      return methods if custom_method_names.empty?

      custom_method_names.each do |method_name|
        ms = method_name.to_s
        source = if ms.start_with?("json_assembly_soa_from_")
                   emit_assembly_soa_from_method(klass, method_name)
                 elsif ms.start_with?("json_assembly_soa_to_")
                   emit_assembly_soa_to_method(klass, method_name)
                 elsif ms.start_with?("json_soa_from_")
                   emit_field_soa_from_method(klass, method_name)
                 elsif ms.start_with?("json_soa_to_")
                   emit_field_soa_to_method(klass, method_name)
                 elsif ms.start_with?("json_from_bykey_asm_")
                   emit_bykey_asm_from_method(klass, method_name)
                 elsif ms.start_with?("json_to_bykey_asm_")
                   emit_bykey_asm_to_method(klass, method_name)
                 elsif ms.start_with?("json_from_bykey_")
                   emit_bykey_from_method(klass, method_name)
                 elsif ms.start_with?("json_to_bykey_")
                   emit_bykey_to_method(klass, method_name)
                 elsif ms.start_with?("json_from_vkf_")
                   emit_vkf_from_method(klass, method_name)
                 elsif ms.start_with?("json_to_vkf_")
                   emit_vkf_to_method(klass, method_name)
                 elsif ms.start_with?("json_from_")
                   emit_scalar_from_method(klass, method_name)
                 elsif ms.start_with?("json_to_")
                   emit_scalar_to_method(klass, method_name)
                 end
        methods.concat(source) if source
      end

      methods
    end

    def emit_scalar_from_method(klass, method_name)
      attr_name = find_attr_for_method(klass, method_name)
      return nil unless attr_name

      attr_sym = attr_name.to_sym
      field_attr = klass.attributes[attr_sym]
      return nil unless field_attr

      has_flags = field_attr.type.is_a?(Class) && field_attr.type < Lutaml::Model::Serializable
      tc = type_constant(field_attr)

      lines = []
      lines << ""
      lines << "    def #{method_name}(instance, value)"

      lines << "      if value.is_a?(Array)"
      if has_flags && tc
        lines << "        parsed = value.map { |v| v.is_a?(String) ? #{tc}.new(content: v) : #{tc}.of_json(v) }"
        lines << "        instance.instance_variable_set(:@#{attr_name}, parsed)"
        lines << "      elsif value.is_a?(Hash)"
        lines << "        if value.empty?"
        lines << "          inst = #{tc}.new(content: \"\")"
        lines << "          instance.instance_variable_set(:@#{attr_name}, inst)"
        lines << "        else"
        lines << "          instance.instance_variable_set(:@#{attr_name}, #{tc}.of_json(value))"
        lines << "        end"
        lines << "      elsif value"
        lines << "        instance.instance_variable_set(:@#{attr_name}, #{tc}.new(content: value))"
      else
        lines << "        instance.instance_variable_set(:@#{attr_name}, value.map { |v| #{tc || 'String'}.new(content: v) })"
        lines << "      elsif value"
        lines << "        instance.instance_variable_set(:@#{attr_name}, #{tc || 'String'}.new(content: value))"
      end
      lines << "      end"

      lines << "    end"
      lines
    end

    def emit_scalar_to_method(klass, method_name)
      ms = method_name.to_s
      ms.sub("json_to_", "")

      json_name = find_json_name_for_to_method(klass, method_name)
      attr_name = find_attr_for_method(klass, method_name)
      return nil unless attr_name

      field_attr = klass.attributes[attr_name.to_sym]
      return nil unless field_attr

      has_flags = field_attr.type.is_a?(Class) && field_attr.type < Lutaml::Model::Serializable
      tc = type_constant(field_attr)

      lines = []
      lines << ""
      lines << "    def #{method_name}(instance, doc)"

      lines << "      current = instance.instance_variable_get(:@#{attr_name})"
      lines << "      if current.is_a?(Array)"
      lines << "        doc[\"#{json_name}\"] = current.map { |item| item.respond_to?(:content) ? item.content : item }"
      lines << "      elsif current"
      if has_flags && tc
        lines << "        if current.is_a?(Lutaml::Model::Serializable)"
        lines << "          doc[\"#{json_name}\"] = #{tc}.as_json(current)"
        lines << "        else"
        lines << "          val = current.respond_to?(:content) ? current.content : current"
        lines << "          doc[\"#{json_name}\"] = val"
        lines << "        end"
      else
        lines << "        doc[\"#{json_name}\"] = current.respond_to?(:content) ? current.content : current"
      end
      lines << "      end"

      lines << "    end"
      lines
    end

    def emit_field_soa_from_method(klass, method_name)
      attr_name = find_attr_for_method(klass, method_name)
      return nil unless attr_name

      field_attr = klass.attributes[attr_name.to_sym]
      return nil unless field_attr

      tc = type_constant(field_attr)

      lines = []
      lines << ""
      lines << "    def #{method_name}(instance, value)"
      lines << "      items = case value"
      lines << "              when Hash then [value]"
      lines << "              when Array then value"
      lines << "              when String then [value]"
      lines << "              else return"
      lines << "              end"

      if tc
        lines << "      parsed = items.map do |item|"
        lines << "        case item"
        lines << "        when Hash then #{tc}.of_json(item)"
        lines << "        when String then #{tc}.of_json(item)"
        lines << "        else item"
        lines << "        end"
        lines << "      end"
      else
        # Anonymous/inline type — pass through as-is
        lines << "      parsed = items.map { |item| item.is_a?(Hash) ? item : item }"
      end

      lines << "      instance.instance_variable_set(:@#{attr_name}, parsed)"
      lines << "    end"
      lines
    end

    def emit_field_soa_to_method(klass, method_name)
      attr_name = find_attr_for_method(klass, method_name)
      return nil unless attr_name

      field_attr = klass.attributes[attr_name.to_sym]
      return nil unless field_attr

      json_name = find_json_name_for_to_method(klass, method_name)
      tc = type_constant(field_attr)

      lines = []
      lines << ""
      lines << "    def #{method_name}(instance, doc)"
      lines << "      current = instance.instance_variable_get(:@#{attr_name})"
      lines << "      if current.is_a?(Array)"
      lines << "        result = current.map do |item|"

      if tc
        lines << "          if item.is_a?(Lutaml::Model::Serializable)"
        lines << "            #{tc}.as_json(item)"
        lines << "          else"
        lines << "            item"
        lines << "          end"
      else
        lines << "          item.respond_to?(:to_h) ? item.to_h : item"
      end

      lines << "        end"
      lines << "        doc[\"#{json_name}\"] = result.length == 1 ? result.first : result"
      if tc
        lines << "      elsif current.is_a?(Lutaml::Model::Serializable)"
        lines << "        doc[\"#{json_name}\"] = #{tc}.as_json(current)"
      end
      lines << "      end"
      lines << "    end"
      lines
    end

    def emit_assembly_soa_from_method(klass, method_name)
      attr_name = find_attr_for_method(klass, method_name)
      return nil unless attr_name

      asm_attr = klass.attributes[attr_name.to_sym]
      return nil unless asm_attr

      tc = type_constant(asm_attr)

      lines = []
      lines << ""
      lines << "    def #{method_name}(instance, value)"
      lines << "      items = case value"
      lines << "              when Hash then [value]"
      lines << "              when Array then value"
      lines << "              else return"
      lines << "              end"

      if tc
        lines << "      parsed = items.map { |item| #{tc}.of_json(item.is_a?(Hash) ? item : {}) }"
      else
        lines << "      parsed = items"
      end

      lines << "      result = value.is_a?(Hash) ? parsed.first : parsed"
      lines << "      instance.instance_variable_set(:@#{attr_name}, result)"
      lines << "    end"
      lines
    end

    def emit_assembly_soa_to_method(klass, method_name)
      attr_name = find_attr_for_method(klass, method_name)
      return nil unless attr_name

      asm_attr = klass.attributes[attr_name.to_sym]
      return nil unless asm_attr

      json_name = find_json_name_for_to_method(klass, method_name)
      tc = type_constant(asm_attr)

      lines = []
      lines << ""
      lines << "    def #{method_name}(instance, doc)"
      lines << "      current = instance.instance_variable_get(:@#{attr_name})"
      lines << "      if current.is_a?(Array)"
      lines << "        result = current.map do |item|"

      if tc
        lines << "          if item.is_a?(Lutaml::Model::Serializable)"
        lines << "            #{tc}.as_json(item)"
        lines << "          else"
        lines << "            item"
        lines << "          end"
      else
        lines << "          item.respond_to?(:to_h) ? item.to_h : item"
      end

      lines << "        end"
      lines << "        doc[\"#{json_name}\"] = result.length == 1 ? result.first : result"
      if tc
        lines << "      elsif current.is_a?(Lutaml::Model::Serializable)"
        lines << "        doc[\"#{json_name}\"] = #{tc}.as_json(current)"
      end
      lines << "      end"
      lines << "    end"
      lines
    end

    def emit_bykey_from_method(klass, method_name)
      # Simplified BY_KEY template
      attr_name = find_attr_for_method(klass, method_name)
      return nil unless attr_name

      lines = []
      lines << ""
      lines << "    def #{method_name}(instance, value)"
      lines << "      return unless value.is_a?(Hash)"
      lines << "      # BY_KEY deserialization handled by register"
      lines << "      instance.instance_variable_set(:@#{attr_name}, value.map { |k, v| [k, v] })"
      lines << "    end"
      lines
    end

    def emit_bykey_to_method(klass, method_name)
      attr_name = find_attr_for_method(klass, method_name)
      return nil unless attr_name

      json_name = find_json_name_for_to_method(klass, method_name)

      lines = []
      lines << ""
      lines << "    def #{method_name}(instance, doc)"
      lines << "      current = instance.instance_variable_get(:@#{attr_name})"
      lines << "      doc[\"#{json_name}\"] = current if current"
      lines << "    end"
      lines
    end

    def emit_bykey_asm_from_method(klass, method_name)
      emit_bykey_from_method(klass, method_name)
    end

    def emit_bykey_asm_to_method(klass, method_name)
      emit_bykey_to_method(klass, method_name)
    end

    def emit_vkf_from_method(klass, method_name)
      emit_bykey_from_method(klass, method_name)
    end

    def emit_vkf_to_method(klass, method_name)
      emit_bykey_to_method(klass, method_name)
    end

    def emit_root_wrapping(klass)
      root_name = klass.instance_variable_get(:@json_root_name)
      return [] unless root_name

      lines = []
      lines << ""
      lines << "    def self.of_json(doc, options = {})"
      lines << "      if doc.is_a?(Hash) && doc.key?(\"#{root_name}\")"
      lines << "        super(doc[\"#{root_name}\"], options)"
      lines << "      else"
      lines << "        super(doc, options)"
      lines << "      end"
      lines << "    end"
      lines << ""
      lines << "    def self.to_json(instance, options = {})"
      lines << "      json_str = super(instance, options)"
      lines << "      { \"#{root_name}\" => JSON.parse(json_str) }.to_json"
      lines << "    end"
      lines << ""
      lines << "    def self.of_yaml(doc, options = {})"
      lines << "      if doc.is_a?(Hash) && doc.key?(\"#{root_name}\")"
      lines << "        super(doc[\"#{root_name}\"], options)"
      lines << "      else"
      lines << "        super(doc, options)"
      lines << "      end"
      lines << "    end"
      lines << ""
      lines << "    def self.to_yaml(instance, options = {})"
      lines << "      data = as_yaml(instance, options)"
      lines << "      { \"#{root_name}\" => data }.to_yaml"
      lines << "    end"
      lines << ""
      lines << "    def to_json(options = {})"
      lines << "      self.class.to_json(self, options)"
      lines << "    end"
      lines << ""
      lines << "    def to_yaml(options = {})"
      lines << "      self.class.to_yaml(self, options)"
      lines << "    end"

      lines
    end

    def emit_constraint_methods(klass)
      constraints = klass.instance_variable_get(:@metaschema_constraints)
      return [] unless constraints

      lines = []
      lines << ""
      lines << "    def self.metaschema_constraints"
      lines << "      @metaschema_constraints"
      lines << "    end"
      lines << ""
      lines << "    def validate_constraints"
      lines << "      validator = Metaschema::ConstraintValidator.new"
      lines << "      validator.validate(self, self.class.metaschema_constraints)"
      lines << "    end"

      lines
    end

    def emit_occurrence_validation(klass)
      occ = klass.instance_variable_get(:@occurrence_constraints)
      return nil unless occ && !occ.empty?

      lines = []
      lines << ""
      lines << "    def validate_occurrences"
      lines << "      Metaschema::ConstraintValidator.validate_occurrences(self, self.class.instance_variable_get(:@occurrence_constraints))"
      lines << "    end"

      lines
    end

    # Helper: find the JSON name for a to: callback method
    def find_json_name_for_to_method(klass, method_name)
      kv_map = begin
        klass.mappings_for(:json)
      rescue StandardError
        nil
      end
      return nil unless kv_map

      mappings = kv_map.instance_variable_get(:@mappings)
      mappings&.each do |json_name, rule|
        if rule.custom_methods[:to]&.to_s == method_name.to_s
          return json_name
        end
      end
      nil
    end

    # Helper: find the JSON name for a from: callback method
    def find_json_name_for_from_method(klass, method_name)
      kv_map = begin
        klass.mappings_for(:json)
      rescue StandardError
        nil
      end
      return nil unless kv_map

      mappings = kv_map.instance_variable_get(:@mappings)
      mappings&.each do |json_name, rule|
        if rule.custom_methods[:from]&.to_s == method_name.to_s
          return json_name
        end
      end
      nil
    end

    # Helper: find the attribute name for a callback method
    def find_attr_for_method(klass, method_name)
      kv_map = begin
        klass.mappings_for(:json)
      rescue StandardError
        nil
      end
      return nil unless kv_map

      ms = method_name.to_s
      mappings = kv_map.instance_variable_get(:@mappings)
      mappings&.each_value do |rule|
        custom = rule.custom_methods
        if custom[:to]&.to_s == ms || custom[:from]&.to_s == ms
          return rule.to.to_s
        end
      end
      nil
    end

    def type_reference_short(attr)
      type = attr.type
      if type.is_a?(Symbol) || BUILTIN_TYPES.include?(type)
        type
      elsif type.is_a?(Class) && type < Lutaml::Model::Serializable
        :class_ref
      else
        :string
      end
    end
  end
end
