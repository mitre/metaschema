# frozen_string_literal: true

module Metaschema
  class ModelGenerator
    # Creates assembly classes from Metaschema assembly definitions.
    # Handles placeholder creation, population with XML/JSON mappings,
    # model processing (fields, assemblies, choices), and custom
    # serialization callbacks (BY_KEY, SINGLETON_OR_ARRAY, json-value-key-flag).
    class AssemblyFactory
      def initialize(assembly_def, generator)
        @assembly_def = assembly_def
        @g = generator
      end

      def create_placeholder
        ad = @assembly_def
        return unless ad.name

        klass_name = "Assembly_#{ad.name.gsub('-', '_')}"
        @g.classes[klass_name] ||= Class.new(Lutaml::Model::Serializable)
      end

      def populate
        ad = @assembly_def
        return unless ad.name

        klass_name = "Assembly_#{ad.name.gsub('-', '_')}"
        klass = @g.classes[klass_name]
        return unless klass

        @g.current_assembly_name = ad.name.gsub("-", "_")

        ad.define_flag&.each { |f| @g.add_inline_flag(klass, f) }
        ad.flag&.each { |f| @g.add_flag_reference(klass, f) }

        process_model(klass, ad.model) if ad.model

        root_name = ad.root_name&.content || ad.name
        build_assembly_xml(klass, root_name, ad)
        build_assembly_json(klass, root_name, ad)

        if ad.root_name&.content
          add_json_root_handling(klass, root_name)
        end

        @g.apply_constraint_validation(klass, ad.constraint)
        klass.instance_variable_set(:@populated, true)
      ensure
        @g.current_assembly_name = nil
      end

      private

      attr_reader :assembly_def

      # ── XML Building ─────────────────────────────────────────────────

      def build_assembly_xml(klass, root_name, assembly_def)
        flag_defs = assembly_def.define_flag || []
        flag_refs = assembly_def.flag || []
        child_mappings = collect_child_mappings(assembly_def)

        flag_attr_maps = flag_defs.filter_map do |f|
          [f.name, Utils.safe_attr(f.name)] if f.name
        end
        flag_ref_maps = flag_refs.filter_map do |f|
          [f.ref, Utils.safe_attr(f.ref)] if f.ref
        end

        unwrapped_mappings, wrapped_mappings = child_mappings.partition do |m|
          m[:unwrapped]
        end

        needs_mixed_content = unwrapped_mappings.any? do |m|
          attr_obj = klass.attributes[m[:attr_name]]
          next false unless attr_obj

          field_type = attr_obj.type
          next false unless field_type.respond_to?(:mappings)

          field_xml = field_type.mappings[:xml]
          field_xml&.mixed_content?
        end

        klass.class_eval do
          xml do
            element root_name
            mixed_content if needs_mixed_content
            ordered

            flag_attr_maps.each do |xml_name, attr_name|
              map_attribute xml_name, to: attr_name
            end

            flag_ref_maps.each do |xml_name, attr_name|
              map_attribute xml_name, to: attr_name
            end

            wrapped_mappings.each do |mapping|
              map_element mapping[:xml_name], to: mapping[:attr_name]
            end
          end
        end

        unwrapped_mappings.each do |mapping|
          delegate_field_xml_mappings(mapping[:attr_name], klass)
        end
      end

      def delegate_field_xml_mappings(attr_name, parent_klass)
        attr_obj = parent_klass.attributes[attr_name]
        field_type = attr_obj&.type if attr_obj
        return unless field_type && field_type < Lutaml::Model::Serializable

        mapping = field_type.mappings[:xml]
        return unless mapping

        mapping.attributes.each do |rule|
          parent_klass.mappings[:xml].map_attribute rule.name, to: rule.to,
                                                               delegate: attr_name
        end

        content_rule = mapping.content_mapping
        if content_rule
          parent_klass.mappings[:xml].map_content to: content_rule.to,
                                                  delegate: attr_name
        end

        mapping.elements.each do |rule|
          parent_klass.mappings[:xml].map_element rule.name, to: rule.to,
                                                             delegate: attr_name
        end
      end

      def collect_child_mappings(assembly_def)
        mappings = []
        model = assembly_def.model
        return mappings unless model

        mappings.concat(collect_model_child_mappings(model))
        mappings
      end

      def collect_model_child_mappings(model)
        mappings = []

        model.field&.each do |field_ref|
          ref_name = field_ref.ref
          next unless ref_name

          xml_name = field_ref.use_name&.content || ref_name
          group_as = field_ref.group_as
          grouped = group_as&.in_xml == "GROUPED"
          unwrapped = !grouped && field_ref.in_xml == "UNWRAPPED"

          mappings << build_child_mapping(xml_name, group_as, grouped, ref_name,
                                          unwrapped: unwrapped)
        end

        model.assembly&.each do |assembly_ref|
          ref_name = assembly_ref.ref
          next unless ref_name

          xml_name = @g.assembly_xml_element_name(assembly_ref)
          group_as = assembly_ref.group_as
          grouped = group_as&.in_xml == "GROUPED"

          attr_name = grouped ? Utils.safe_attr(group_as.name) : Utils.safe_attr(ref_name)
          mappings << { xml_name: grouped ? group_as.name : xml_name,
                        attr_name: attr_name, grouped: grouped }
        end

        model.define_field&.each do |inline_def|
          next unless inline_def.name

          unwrapped = inline_def.respond_to?(:in_xml) && inline_def.in_xml == "UNWRAPPED"
          mappings << { xml_name: inline_def.name,
                        attr_name: Utils.safe_attr(inline_def.name), grouped: false,
                        unwrapped: unwrapped }
        end

        model.define_assembly&.each do |inline_def|
          next unless inline_def.name

          mappings << { xml_name: inline_def.name,
                        attr_name: Utils.safe_attr(inline_def.name), grouped: false }
        end

        model.choice&.each do |c|
          mappings.concat(collect_choice_child_mappings(c))
        end
        model.choice_group&.each do |cg|
          mappings.concat(collect_choice_group_child_mappings(cg))
        end

        mappings
      end

      def collect_choice_child_mappings(choice)
        mappings = []

        choice.field&.each do |field_ref|
          ref_name = field_ref.ref
          next unless ref_name

          xml_name = field_ref.use_name&.content || ref_name
          group_as = field_ref.group_as
          grouped = group_as&.in_xml == "GROUPED"
          unwrapped = !grouped && field_ref.in_xml == "UNWRAPPED"

          mappings << build_child_mapping(xml_name, group_as, grouped, ref_name,
                                          unwrapped: unwrapped)
        end

        choice.assembly&.each do |assembly_ref|
          ref_name = assembly_ref.ref
          next unless ref_name

          xml_name = @g.assembly_xml_element_name(assembly_ref)
          group_as = assembly_ref.group_as
          grouped = group_as&.in_xml == "GROUPED"

          attr_name = grouped ? Utils.safe_attr(group_as.name) : Utils.safe_attr(ref_name)
          mappings << { xml_name: grouped ? group_as.name : xml_name,
                        attr_name: attr_name, grouped: grouped }
        end

        choice.define_field&.each do |inline_def|
          next unless inline_def.name

          mappings << { xml_name: inline_def.name,
                        attr_name: Utils.safe_attr(inline_def.name), grouped: false }
        end

        choice.define_assembly&.each do |inline_def|
          next unless inline_def.name

          mappings << { xml_name: inline_def.name,
                        attr_name: Utils.safe_attr(inline_def.name), grouped: false }
        end

        mappings
      end

      def collect_choice_group_child_mappings(choice_group)
        mappings = []

        choice_group.field&.each do |field_ref|
          ref_name = field_ref.ref
          next unless ref_name

          xml_name = field_ref.use_name&.content || ref_name
          group_as = choice_group.group_as
          grouped = group_as&.in_xml == "GROUPED"
          unwrapped = !grouped && field_ref.in_xml == "UNWRAPPED"
          mappings << build_child_mapping(xml_name, group_as, grouped, ref_name,
                                          unwrapped: unwrapped)
        end

        choice_group.assembly&.each do |assembly_ref|
          ref_name = assembly_ref.ref
          next unless ref_name

          xml_name = @g.assembly_xml_element_name(assembly_ref)
          group_as = choice_group.group_as
          grouped = group_as&.in_xml == "GROUPED"
          attr_name = grouped ? Utils.safe_attr(group_as.name) : Utils.safe_attr(ref_name)
          mappings << { xml_name: grouped ? group_as.name : xml_name,
                        attr_name: attr_name, grouped: grouped }
        end

        choice_group.define_field&.each do |inline_def|
          next unless inline_def.name

          mappings << { xml_name: inline_def.name,
                        attr_name: Utils.safe_attr(inline_def.name), grouped: false }
        end

        choice_group.define_assembly&.each do |inline_def|
          next unless inline_def.name

          mappings << { xml_name: inline_def.name,
                        attr_name: Utils.safe_attr(inline_def.name), grouped: false }
        end

        mappings
      end

      def build_child_mapping(xml_name, group_as, grouped, ref_name = nil,
                             unwrapped: false)
        if grouped
          { xml_name: group_as.name, attr_name: Utils.safe_attr(group_as.name),
            grouped: true, unwrapped: false }
        else
          attr_name = Utils.safe_attr(ref_name || xml_name)
          { xml_name: xml_name, attr_name: attr_name, grouped: false,
            unwrapped: unwrapped }
        end
      end

      # ── JSON Building ─────────────────────────────────────────────────

      def build_assembly_json(klass, root_name, assembly_def)
        flag_defs = assembly_def.define_flag || []
        flag_refs = assembly_def.flag || []

        flag_attr_maps = flag_defs.filter_map do |f|
          [f.name, Utils.safe_attr(f.name)] if f.name
        end
        flag_ref_maps = flag_refs.filter_map do |f|
          [f.ref, Utils.safe_attr(f.ref)] if f.ref
        end

        json_field_mappings = collect_json_field_mappings(assembly_def)
        json_assembly_mappings = collect_json_assembly_mappings(assembly_def)

        vk_flag_mappings = json_field_mappings.select { |m| m[:vk_flag] }
        by_key_mappings = json_field_mappings.select { |m| m[:by_key] }
        soa_mappings = json_field_mappings.select { |m| m[:singleton_or_array] }
        regular_field_mappings = json_field_mappings.reject do |m|
          m[:vk_flag] || m[:by_key] || m[:singleton_or_array]
        end

        assembly_by_key_mappings = json_assembly_mappings.select do |m|
          m[:by_key]
        end
        assembly_soa_mappings = json_assembly_mappings.select do |m|
          m[:singleton_or_array]
        end
        regular_assembly_mappings = json_assembly_mappings.reject do |m|
          m[:by_key] || m[:singleton_or_array]
        end

        klass.class_eval do
          key_value do
            root root_name

            flag_attr_maps.each do |xml_name, attr_name|
              map xml_name, to: attr_name
            end

            flag_ref_maps.each do |xml_name, attr_name|
              map xml_name, to: attr_name
            end

            regular_field_mappings.each do |mapping|
              if mapping[:scalar]
                map mapping[:json_name], to: mapping[:attr_name],
                                         with: { to: mapping[:to_method], from: mapping[:from_method] }
              else
                map mapping[:json_name], to: mapping[:attr_name],
                                         render_empty: true
              end
            end

            regular_assembly_mappings.each do |mapping|
              map mapping[:json_name], to: mapping[:attr_name],
                                       render_empty: true
            end
          end
        end

        regular_field_mappings.each do |mapping|
          next unless mapping[:scalar]

          field_klass = mapping[:field_klass]
          attr_sym = mapping[:attr_name]
          has_flags = mapping[:has_flags]

          klass.define_method(mapping[:from_method]) do |instance, value|
            if value.is_a?(Array)
              parsed = value.map do |v|
                has_flags ? field_klass.of_json(v) : field_klass.new(content: v)
              end
              instance.instance_variable_set("@#{attr_sym}", parsed)
            elsif value.is_a?(Hash)
              if value.empty?
                inst = field_klass.new(content: "")
                inst.instance_variable_set(:@_was_empty_hash, true)
                instance.instance_variable_set("@#{attr_sym}", inst)
              else
                instance.instance_variable_set("@#{attr_sym}",
                                               field_klass.of_json(value))
              end
            elsif value
              instance.instance_variable_set("@#{attr_sym}",
                                             has_flags ? field_klass.of_json(value) : field_klass.new(content: value))
            end
          end

          klass.define_method(mapping[:to_method]) do |instance, doc|
            current = instance.instance_variable_get("@#{attr_sym}")
            if current.is_a?(Array)
              result = current.map do |item|
                if has_flags && item.is_a?(Lutaml::Model::Serializable)
                  field_klass.as_json(item)
                else
                  item.respond_to?(:content) ? item.content : item
                end
              end
              doc[mapping[:json_name]] = result
            elsif current
              if current.instance_variable_get(:@_was_empty_hash)
                doc[mapping[:json_name]] = {}
              elsif has_flags && current.is_a?(Lutaml::Model::Serializable)
                doc[mapping[:json_name]] = field_klass.as_json(current)
              else
                val = current.respond_to?(:content) ? current.content : current
                doc[mapping[:json_name]] = val
              end
            end
          end
        end

        soa_mappings.each do |mapping|
          attr_sym = mapping[:attr_name]
          json_name = mapping[:json_name]
          from_m = mapping[:from_method]
          to_m = mapping[:to_method]

          klass.define_method(from_m) do |instance, value|
            Services::FieldDeserializer.call(instance, attr_sym, :json, value,
                                             group_as: "SINGLETON_OR_ARRAY", collapsible: false)
          end

          klass.define_method(to_m) do |instance, doc|
            Services::FieldSerializer.call(instance, attr_sym, :json, doc,
                                           group_as: "SINGLETON_OR_ARRAY", collapsible: false)
          end

          klass.class_eval do
            key_value do
              map json_name, to: attr_sym,
                             with: { to: to_m, from: from_m }
            end
          end

          if mapping[:alt_json_name]
            klass.class_eval do
              key_value do
                map mapping[:alt_json_name], to: attr_sym,
                                             with: { to: to_m, from: from_m }
              end
            end
          end
        end

        vk_flag_mappings.each do |mapping|
          callbacks = build_vk_flag_field_callbacks(
            klass, mapping[:field_klass], mapping[:json_name], mapping[:attr_name]
          )
          klass.class_eval do
            key_value do
              map mapping[:json_name], to: mapping[:attr_name],
                                       with: { to: callbacks[:to_method], from: callbacks[:from_method] }
            end
          end
        end

        by_key_mappings.each do |mapping|
          unless klass.attributes.key?(mapping[:attr_name])
            klass.attribute mapping[:attr_name], mapping[:field_klass],
                            collection: true
          end
          callbacks = build_by_key_field_callbacks(
            klass, mapping[:field_klass], mapping[:json_name],
            mapping[:attr_name], mapping[:json_key_flag]
          )
          klass.class_eval do
            key_value do
              map mapping[:json_name], to: mapping[:attr_name],
                                       with: { to: callbacks[:to_method], from: callbacks[:from_method] }
            end
          end
        end

        assembly_by_key_mappings.each do |mapping|
          unless klass.attributes.key?(mapping[:attr_name])
            asm_type = mapping[:asm_klass] || Lutaml::Model::Serializable
            klass.attribute mapping[:attr_name], asm_type, collection: true
          end
          callbacks = build_by_key_assembly_callbacks(
            klass, mapping[:asm_klass], mapping[:json_name],
            mapping[:attr_name], mapping[:json_key_flag],
            grouped: mapping[:grouped] || false,
            child_attr: mapping[:child_attr]
          )
          klass.class_eval do
            key_value do
              map mapping[:json_name], to: mapping[:attr_name],
                                       with: { to: callbacks[:to_method], from: callbacks[:from_method] }
            end
          end
        end

        assembly_soa_mappings.each do |mapping|
          attr_sym = mapping[:attr_name]
          json_name = mapping[:json_name]
          from_m = mapping[:from_method]
          to_m = mapping[:to_method]

          klass.define_method(from_m) do |instance, value|
            Services::FieldDeserializer.call(instance, attr_sym, :json, value,
                                             group_as: "SINGLETON_OR_ARRAY", collapsible: false)
          end

          klass.define_method(to_m) do |instance, doc|
            Services::FieldSerializer.call(instance, attr_sym, :json, doc,
                                           group_as: "SINGLETON_OR_ARRAY", collapsible: false)
          end

          klass.class_eval do
            key_value do
              map json_name, to: attr_sym, render_empty: true,
                             with: { to: to_m, from: from_m }
            end
          end
        end

        if flag_defs.empty? && flag_refs.empty? &&
            json_assembly_mappings.length == 1 &&
            json_assembly_mappings.first[:by_key]

          by_key_json_name = json_assembly_mappings.first[:json_name]

          orig_of_json = klass.method(:of_json)
          klass.define_singleton_method(:of_json) do |data, options = {}|
            if data.is_a?(Hash) && !data.key?(by_key_json_name)
              orig_of_json.call({ by_key_json_name => data }, options)
            else
              orig_of_json.call(data, options)
            end
          end

          orig_as_json = klass.method(:as_json)
          klass.define_singleton_method(:as_json) do |instance, options = {}|
            result = orig_as_json.call(instance, options)
            if result.is_a?(Hash) && result.key?(by_key_json_name)
              result[by_key_json_name]
            else
              result
            end
          end
        end
      end

      # ── JSON Mapping Collectors ────────────────────────────────────────

      def collect_json_field_mappings(assembly_def)
        mappings = []
        model = assembly_def.model
        return mappings unless model

        mappings.concat(collect_model_json_field_mappings(model))
        mappings
      end

      def collect_model_json_field_mappings(model)
        mappings = []

        model.field&.each { |fr| mappings << build_field_json_mapping(fr) }
        model.define_field&.each do |fd|
          mappings << build_inline_field_json_mapping(fd) if fd.name
        end
        model.choice&.each do |c|
          c.field&.each { |fr| mappings << build_field_json_mapping(fr) }
          c.define_field&.each do |fd|
            mappings << build_inline_field_json_mapping(fd) if fd.name
          end
        end
        model.choice_group&.each do |cg|
          cg.field&.each do |fr|
            mappings << build_field_json_mapping(fr, cg.group_as)
          end
          cg.define_field&.each do |fd|
            mappings << build_inline_field_json_mapping(fd) if fd.name
          end
        end

        mappings
      end

      def build_field_json_mapping(field_ref, override_group_as = nil)
        ref_name = field_ref.ref
        return nil unless ref_name

        group_as = override_group_as || field_ref.group_as
        field_def = @g.field_defs[ref_name]
        field_klass = @g.classes["Field_#{ref_name.gsub('-', '_')}"]
        has_flags = field_has_flags?(field_def)

        json_name = if group_as
                      group_as.name
                    else
                      field_ref.use_name&.content || ref_name
                    end
        attr_name = Utils.safe_attr(ref_name)

        if group_as&.in_json == "BY_KEY"
          json_key_flag = field_def&.json_key&.flag_ref
          return {
            json_name: json_name, attr_name: attr_name,
            by_key: true, field_klass: field_klass,
            json_key_flag: json_key_flag
          }
        end

        if field_klass&.instance_variable_get(:@json_vk_flag_key_attr)
          return {
            json_name: json_name, attr_name: attr_name,
            vk_flag: true, field_klass: field_klass
          }
        end

        if has_flags
          is_soa = group_as && ["SINGLETON_OR_ARRAY",
                                "ARRAY"].include?(group_as.in_json)
          method_suffix = "#{attr_name}_#{json_name.gsub('-', '_')}"
          if is_soa
            result = {
              json_name: json_name, attr_name: attr_name, scalar: false,
              singleton_or_array: true, field_klass: field_klass,
              to_method: :"json_soa_to_#{method_suffix}",
              from_method: :"json_soa_from_#{method_suffix}"
            }
            if group_as && ref_name != json_name
              result[:alt_json_name] = ref_name
            end
            result
          else
            {
              json_name: json_name, attr_name: attr_name, scalar: true,
              has_flags: true, field_klass: field_klass,
              to_method: :"json_to_#{method_suffix}",
              from_method: :"json_from_#{method_suffix}"
            }
          end
        else
          method_suffix = "#{attr_name}_#{json_name.gsub('-', '_')}"
          {
            json_name: json_name, attr_name: attr_name, scalar: true,
            field_klass: field_klass,
            to_method: :"json_to_#{method_suffix}",
            from_method: :"json_from_#{method_suffix}"
          }
        end
      end

      def build_inline_field_json_mapping(field_def)
        json_name = field_def.name
        attr_name = Utils.safe_attr(field_def.name)
        has_flags = field_has_flags?(field_def)

        if has_flags
          field_klass = @g.classes[@g.scoped_field_name(field_def.name)]
          method_suffix = "#{attr_name}_#{json_name.gsub('-', '_')}"
          {
            json_name: json_name, attr_name: attr_name, scalar: false,
            singleton_or_array: true, field_klass: field_klass,
            to_method: :"json_soa_to_#{method_suffix}",
            from_method: :"json_soa_from_#{method_suffix}"
          }
        else
          { json_name: json_name, attr_name: attr_name, scalar: false }
        end
      end

      def field_has_flags?(field_def, _field_ref = nil)
        return false unless field_def

        field_def.define_flag&.any? || field_def.flag&.any? || field_def.json_value_key || field_def.json_value_key_flag
      end

      def collect_json_assembly_mappings(assembly_def)
        mappings = []
        model = assembly_def.model
        return mappings unless model

        mappings.concat(collect_model_json_assembly_mappings(model))
        mappings
      end

      def collect_model_json_assembly_mappings(model)
        mappings = []

        model.assembly&.each do |ar|
          ref_name = ar.ref
          next unless ref_name

          group_as = ar.group_as
          json_name = group_as&.name || ar.use_name&.content || ref_name
          attr_name = group_as&.in_xml == "GROUPED" ? Utils.safe_attr(group_as.name) : Utils.safe_attr(ref_name)
          mapping = { json_name: json_name, attr_name: attr_name }
          if group_as&.in_json == "BY_KEY"
            asm_def = @g.assembly_defs[ref_name]
            json_key_flag = asm_def&.json_key&.flag_ref
            asm_klass = @g.classes["Assembly_#{ref_name.gsub('-', '_')}"]
            mapping[:by_key] = true
            mapping[:asm_klass] = asm_klass
            mapping[:json_key_flag] = json_key_flag
            mapping[:grouped] = true if group_as&.in_xml == "GROUPED"
            if group_as&.in_xml == "GROUPED"
              mapping[:child_attr] = Utils.safe_attr(ref_name)
            end
          else
            check_assembly_soa(mapping, group_as, attr_name, json_name)
          end
          mappings << mapping
        end

        model.define_assembly&.each do |ad|
          next unless ad.name

          group_as = ad.group_as
          json_name = group_as&.name || ad.name
          attr_name = Utils.safe_attr(ad.name)
          mapping = { json_name: json_name, attr_name: attr_name }
          if group_as&.in_json == "BY_KEY"
            json_key_flag = ad.json_key&.flag_ref
            mapping[:by_key] = true
            mapping[:json_key_flag] = json_key_flag
          else
            check_assembly_soa(mapping, group_as, attr_name, json_name)
          end
          mappings << mapping
        end

        model.choice&.each do |c|
          c.assembly&.each do |ar|
            ref_name = ar.ref
            next unless ref_name

            group_as = ar.group_as
            json_name = group_as&.name || ar.use_name&.content || ref_name
            attr_name = Utils.safe_attr(ref_name)
            mapping = { json_name: json_name, attr_name: attr_name }
            check_assembly_soa(mapping, group_as, attr_name, json_name)
            mappings << mapping
          end
          c.define_assembly&.each do |ad|
            next unless ad.name

            group_as = ad.group_as
            json_name = group_as&.name || ad.name
            attr_name = Utils.safe_attr(ad.name)
            mapping = { json_name: json_name, attr_name: attr_name }
            check_assembly_soa(mapping, group_as, attr_name, json_name)
            mappings << mapping
          end
        end

        model.choice_group&.each do |cg|
          group_as = cg.group_as
          json_name = group_as&.name
          cg.assembly&.each do |ar|
            ref_name = ar.ref
            next unless ref_name

            name = json_name || ar.use_name&.content || ref_name
            attr_name = Utils.safe_attr(ref_name)
            mapping = { json_name: name, attr_name: attr_name }
            check_assembly_soa(mapping, group_as, attr_name, name)
            mappings << mapping
          end
          cg.define_assembly&.each do |ad|
            next unless ad.name

            name = json_name || ad.name
            attr_name = Utils.safe_attr(ad.name)
            mapping = { json_name: name, attr_name: attr_name }
            check_assembly_soa(mapping, group_as, attr_name, name)
            mappings << mapping
          end
        end

        mappings
      end

      def check_assembly_soa(mapping, group_as, attr_name, json_name)
        is_soa = group_as&.in_json == "SINGLETON_OR_ARRAY" || group_as.nil?
        return unless is_soa

        method_suffix = "#{attr_name}_#{json_name.gsub('-', '_')}"
        mapping[:singleton_or_array] = true
        mapping[:to_method] = :"json_assembly_soa_to_#{method_suffix}"
        mapping[:from_method] = :"json_assembly_soa_from_#{method_suffix}"
        asm_klass = @g.classes["Assembly_#{attr_name.to_s.gsub('-', '_')}"]
        mapping[:asm_klass] = asm_klass if asm_klass
      end

      # ── Custom Callback Builders ──────────────────────────────────────

      def build_vk_flag_field_callbacks(parent_klass, field_klass, json_name,
attr_sym)
        key_attr = field_klass.instance_variable_get(:@json_vk_flag_key_attr)
        other_flag_maps = field_klass.instance_variable_get(:@json_vk_flag_other_flag_maps)
        known_json_keys = other_flag_maps.map(&:first)

        from_method = :"json_from_vkf_#{attr_sym}_#{json_name.gsub('-', '_')}"
        to_method = :"json_to_vkf_#{attr_sym}_#{json_name.gsub('-', '_')}"

        parent_klass.define_method(from_method) do |instance, value|
          items = case value
                  when Array then value
                  when Hash then [value]
                  when nil then []
                  else [value]
                  end
          parsed = items.map do |item|
            item = item.dup
            key_val = nil
            content_val = nil
            item.each do |k, v|
              unless known_json_keys.include?(k)
                key_val = k
                content_val = v
              end
            end
            obj = field_klass.allocate
            obj.instance_variable_set(:@using_default, {})
            obj.instance_variable_set(:@lutaml_register, :default)
            obj.instance_variable_set("@#{key_attr}", key_val)
            obj.instance_variable_set(:@content, content_val)
            other_flag_maps.each do |json_key, attr_name|
              if item.key?(json_key)
                obj.instance_variable_set("@#{attr_name}", item[json_key])
              end
            end
            obj
          end
          instance.instance_variable_set("@#{attr_sym}", parsed)
        end

        parent_klass.define_method(to_method) do |instance, doc|
          current = instance.instance_variable_get("@#{attr_sym}")
          if current.is_a?(Array)
            doc[json_name] = current.map do |item|
              key_val = item.instance_variable_get("@#{key_attr}")
              content_val = item.instance_variable_get(:@content)
              result = { key_val => content_val }
              other_flag_maps.each do |json_key, attr_name|
                val = item.instance_variable_get("@#{attr_name}")
                result[json_key] = val if val
              end
              result
            end
          end
        end

        { from_method: from_method, to_method: to_method }
      end

      def build_by_key_field_callbacks(parent_klass, field_klass, json_name,
attr_sym, json_key_flag)
        key_attr = Utils.safe_attr(json_key_flag)
        field_klass && field_klass.instance_variable_get(:@json_vk_flag_key_attr).nil? &&
          field_klass.attributes.any? do |k, _|
            k != :content && k.to_s != key_attr.to_s
          end

        from_method = :"json_from_bykey_#{attr_sym}_#{json_name.gsub('-', '_')}"
        to_method = :"json_to_bykey_#{attr_sym}_#{json_name.gsub('-', '_')}"

        parent_klass.define_method(from_method) do |instance, value|
          return unless value.is_a?(Hash)

          parsed = value.map do |k, v|
            obj = if field_klass
                    field_klass.allocate.tap do |o|
                      o.instance_variable_set(:@using_default, {})
                      o.instance_variable_set(:@lutaml_register, :default)
                      o.instance_variable_set("@#{key_attr}", k)
                      if v.is_a?(Hash)
                        v.each do |vk, vv|
                          attr_sym_local = vk.gsub("-", "_").to_sym
                          begin
                            o.instance_variable_set("@#{attr_sym_local}", vv)
                          rescue StandardError
                          end
                        end
                      else
                        o.instance_variable_set(:@content, v)
                      end
                    end
                  else
                    k
                  end
            obj
          end
          instance.instance_variable_set("@#{attr_sym}", parsed)
        end

        parent_klass.define_method(to_method) do |instance, doc|
          current = instance.instance_variable_get("@#{attr_sym}")
          if current.is_a?(Array)
            result = {}
            current.each do |item|
              if field_klass
                key_val = item.instance_variable_get("@#{key_attr}")
                content_val = item.instance_variable_get(:@content)
                if field_klass.attributes.keys.any? do |k|
                  k != :content && k.to_s != key_attr.to_s && item.instance_variable_get("@#{k}")
                end
                  obj = {}
                  field_klass.attributes.each_key do |attr_k|
                    next if attr_k.to_s == key_attr.to_s

                    v = item.instance_variable_get("@#{attr_k}")
                    obj[attr_k.to_s] = v if v
                  end
                  result[key_val] = obj
                else
                  result[key_val] = content_val
                end
              end
            end
            doc[json_name] = result
          end
        end

        { from_method: from_method, to_method: to_method }
      end

      def build_by_key_assembly_callbacks(parent_klass, asm_klass, json_name,
attr_sym, json_key_flag, grouped: false, child_attr: nil)
        key_attr = Utils.safe_attr(json_key_flag)

        from_method = :"json_from_bykey_asm_#{attr_sym}_#{json_name.gsub('-',
                                                                         '_')}"
        to_method = :"json_to_bykey_asm_#{attr_sym}_#{json_name.gsub('-', '_')}"

        parent_klass.define_method(from_method) do |instance, value|
          return unless value.is_a?(Hash)

          parsed = value.map do |k, v|
            if asm_klass
              obj = if v.is_a?(Hash)
                      asm_klass.of_json(v)
                    else
                      asm_klass.new
                    end
              obj.instance_variable_set("@#{key_attr}", k)
              obj
            else
              k
            end
          end

          if grouped && child_attr
            wrapper = instance.instance_variable_get("@#{attr_sym}")
            unless wrapper
              attr_type = instance.class.attributes[attr_sym]
              wrapper = attr_type.type.new
            end
            wrapper.instance_variable_set("@#{child_attr}", parsed)
            instance.instance_variable_set("@#{attr_sym}", wrapper)
          else
            instance.instance_variable_set("@#{attr_sym}", parsed)
          end
        end

        parent_klass.define_method(to_method) do |instance, doc|
          current = instance.instance_variable_get("@#{attr_sym}")
          items = if grouped && current && child_attr
                    current.send(child_attr)
                  else
                    current
                  end

          if items.is_a?(Array)
            result = {}
            items.each do |item|
              next unless asm_klass

              key_val = item.instance_variable_get("@#{key_attr}")
              if item.is_a?(Lutaml::Model::Serializable)
                sub = asm_klass.as_json(item)
                key_json_name = asm_klass.mappings_for(:json).instance_variable_get(:@mappings)
                  .find do |_map_key, rule|
                  rule.to.to_s == key_attr.to_s
                end&.first
                sub.delete(key_json_name) if key_json_name
                result[key_val] = sub.empty? ? {} : sub
              else
                result[key_val] = {}
              end
            end
            doc[json_name] = result
          end
        end

        { from_method: from_method, to_method: to_method }
      end

      def define_scalar_field_callbacks(klass, field_mappings)
        field_mappings.each do |mapping|
          next unless mapping[:scalar]

          field_klass = mapping[:field_klass]
          attr_sym = mapping[:attr_name]

          klass.define_method(mapping[:from_method]) do |instance, value|
            if value.is_a?(Array)
              instance.instance_variable_set("@#{attr_sym}", value.map do |v|
                field_klass.new(content: v)
              end)
            elsif value
              instance.instance_variable_set("@#{attr_sym}",
                                             field_klass.new(content: value))
            end
          end

          klass.define_method(mapping[:to_method]) do |instance, doc|
            current = instance.instance_variable_get("@#{attr_sym}")
            if current.is_a?(Array)
              doc[mapping[:json_name]] = current.map do |item|
                item.respond_to?(:content) ? item.content : item
              end
            elsif current
              doc[mapping[:json_name]] =
                current.respond_to?(:content) ? current.content : current
            end
          end
        end
      end

      # ── Model Processing ──────────────────────────────────────────────

      def process_model(klass, model)
        unless klass.instance_variable_defined?(:@occurrence_constraints)
          klass.instance_variable_set(:@occurrence_constraints, {})
        end
        occ = klass.instance_variable_get(:@occurrence_constraints)

        model.field&.each do |fr|
          add_field_reference(klass, fr)
          record_occurrence_constraint(occ, fr)
        end
        model.assembly&.each do |ar|
          add_assembly_reference(klass, ar)
          record_occurrence_constraint(occ, ar)
        end
        model.define_field&.each { |fd| add_inline_field(klass, fd) }
        model.define_assembly&.each { |ad| add_inline_assembly(klass, ad) }
        model.choice&.each { |c| process_choice(klass, c) }
        model.choice_group&.each { |cg| process_choice_group(klass, cg) }
        add_any_content(klass) if model.any

        unless klass.method_defined?(:validate_occurrences)
          occ_ref = klass.instance_variable_get(:@occurrence_constraints)
          klass.define_method(:validate_occurrences) do
            ConstraintValidator.validate_occurrences(self, occ_ref)
          end
        end
      end

      def record_occurrence_constraint(occ, ref)
        ref_name = ref.ref
        return unless ref_name

        attr_name = Utils.safe_attr(ref_name)
        min = ref.min_occurs.to_i
        max_raw = ref.max_occurs
        max = max_raw == "unbounded" ? nil : max_raw&.to_i

        occ[attr_name] = { min: min, max: max } if min.positive? || max
      end

      def add_field_reference(klass, field_ref)
        ref_name = field_ref.ref
        return unless ref_name

        field_klass = @g.classes["Field_#{ref_name.gsub('-', '_')}"]
        return unless field_klass

        collection = Utils.unbounded?(field_ref.max_occurs)
        group_as = field_ref.group_as

        if group_as&.in_xml == "GROUPED"
          group_attr = Utils.safe_attr(group_as.name)
          wrapper_klass = Class.new(Lutaml::Model::Serializable)
          child_attr = Utils.safe_attr(ref_name)
          wrapper_klass.attribute child_attr, field_klass, collection: true
          wrapper_klass.class_eval do
            xml do
              element group_as.name
              map_element ref_name, to: child_attr
            end
          end
          klass.attribute group_attr, wrapper_klass
        else
          attr_name = Utils.safe_attr(ref_name)
          klass.attribute attr_name, field_klass, collection: collection
        end
      end

      def add_assembly_reference(klass, assembly_ref)
        ref_name = assembly_ref.ref
        return unless ref_name

        assembly_klass = @g.classes["Assembly_#{ref_name.gsub('-', '_')}"] ||
          @g.create_placeholder_assembly(ref_name)

        collection = Utils.unbounded?(assembly_ref.max_occurs)
        group_as = assembly_ref.group_as
        xml_name = @g.assembly_xml_element_name(assembly_ref)

        if group_as&.in_xml == "GROUPED"
          group_attr = Utils.safe_attr(group_as.name)
          child_attr = Utils.safe_attr(ref_name)
          wrapper_klass = Class.new(Lutaml::Model::Serializable)
          wrapper_klass.attribute child_attr, assembly_klass, collection: true
          wrapper_klass.class_eval do
            xml do
              element group_as.name
              map_element xml_name, to: child_attr
            end
          end
          klass.attribute group_attr, wrapper_klass
        else
          attr_name = Utils.safe_attr(ref_name)
          klass.attribute attr_name, assembly_klass, collection: collection
        end
      end

      def add_inline_field(klass, field_def)
        return unless field_def.name

        attr_name = Utils.safe_attr(field_def.name)
        is_markup = TypeMapper.markup?(field_def.as_type)
        is_multiline = TypeMapper.multiline?(field_def.as_type)
        content_type = TypeMapper.map(field_def.as_type)
        collection = Utils.unbounded?(field_def.max_occurs)
        has_flags = field_def.define_flag&.any? || field_def.flag&.any?

        if is_markup || is_multiline
          inline_klass = Class.new(Lutaml::Model::Serializable)
          if is_multiline
            FieldFactory.apply_markup_multiline_attributes(inline_klass)
          else
            FieldFactory.apply_markup_attributes(inline_klass)
          end

          field_def.define_flag&.each do |f|
            @g.add_inline_flag(inline_klass, f)
          end
          field_def.flag&.each { |f| @g.add_flag_reference(inline_klass, f) }

          inline_name = field_def.name
          inline_flag_defs = field_def.define_flag || []
          inline_flag_refs = field_def.flag || []
          inline_flag_attr_maps = inline_flag_defs.filter_map do |f|
            [f.name, Utils.safe_attr(f.name)] if f.name
          end
          inline_flag_ref_maps = inline_flag_refs.filter_map do |f|
            [f.ref, Utils.safe_attr(f.ref)] if f.ref
          end

          inline_klass.class_eval do
            xml do
              element inline_name
              mixed_content
              ordered
              map_content to: :content
              map_element "a", to: :a
              map_element "insert", to: :insert
              map_element "br", to: :br
              map_element "code", to: :code
              map_element "em", to: :em
              map_element "i", to: :i
              map_element "b", to: :b
              map_element "strong", to: :strong
              map_element "sub", to: :sub
              map_element "sup", to: :sup
              map_element "q", to: :q
              map_element "img", to: :img

              if is_multiline
                map_element "p", to: :p
                map_element "h1", to: :h1
                map_element "h2", to: :h2
                map_element "h3", to: :h3
                map_element "h4", to: :h4
                map_element "h5", to: :h5
                map_element "h6", to: :h6
                map_element "ul", to: :ul
                map_element "ol", to: :ol
                map_element "pre", to: :pre
                map_element "hr", to: :hr
                map_element "blockquote", to: :blockquote
                map_element "table", to: :table
              end

              inline_flag_attr_maps.each do |xml_name, attr_sym|
                map_attribute xml_name, to: attr_sym
              end

              inline_flag_ref_maps.each do |xml_name, attr_sym|
                map_attribute xml_name, to: attr_sym
              end
            end
          end

          klass.attribute attr_name, inline_klass, collection: collection
        elsif has_flags
          inline_klass = Class.new(Lutaml::Model::Serializable)
          inline_klass.attribute :content, content_type
          field_def.define_flag&.each do |f|
            @g.add_inline_flag(inline_klass, f)
          end
          field_def.flag&.each { |f| @g.add_flag_reference(inline_klass, f) }

          flag_attr_maps = field_def.define_flag&.filter_map do |f|
            [f.name, Utils.safe_attr(f.name)] if f.name
          end || []
          flag_ref_maps = field_def.flag&.filter_map do |f|
            [f.ref, Utils.safe_attr(f.ref)] if f.ref
          end || []

          inline_vk = field_def.json_value_key || TypeMapper.json_value_key(field_def.as_type)
          inline_name = field_def.name
          inline_klass.class_eval do
            xml do
              element inline_name
              map_content to: :content
              flag_attr_maps.each do |xml_name, attr_sym|
                map_attribute xml_name, to: attr_sym
              end
              flag_ref_maps.each do |xml_name, attr_sym|
                map_attribute xml_name, to: attr_sym
              end
            end
            key_value do
              root inline_name
              map inline_vk, to: :content
              flag_attr_maps.each do |xml_name, attr_sym|
                map xml_name, to: attr_sym
              end
              flag_ref_maps.each do |xml_name, attr_sym|
                map xml_name, to: attr_sym
              end
            end
          end

          klass_name = @g.scoped_field_name(field_def.name)
          @g.classes[klass_name] = inline_klass

          klass.attribute attr_name, inline_klass, collection: collection
        else
          klass.attribute attr_name, content_type, collection: collection
        end
      end

      def add_inline_assembly(klass, assembly_def)
        return unless assembly_def.name

        attr_name = Utils.safe_attr(assembly_def.name)
        collection = Utils.unbounded?(assembly_def.max_occurs)

        inline_klass = Class.new(Lutaml::Model::Serializable)

        assembly_def.define_flag&.each do |f|
          @g.add_inline_flag(inline_klass, f)
        end
        assembly_def.flag&.each { |f| @g.add_flag_reference(inline_klass, f) }

        process_model(inline_klass, assembly_def.model) if assembly_def.model

        inline_name = assembly_def.name
        inline_flag_defs = assembly_def.define_flag || []
        inline_flag_refs = assembly_def.flag || []
        inline_child_mappings = assembly_def.model ? collect_inline_child_mappings(assembly_def) : []
        inline_flag_attr_maps = inline_flag_defs.filter_map do |f|
          [f.name, Utils.safe_attr(f.name)] if f.name
        end
        inline_flag_ref_maps = inline_flag_refs.filter_map do |f|
          [f.ref, Utils.safe_attr(f.ref)] if f.ref
        end

        inline_klass.class_eval do
          xml do
            element inline_name
            ordered

            inline_flag_attr_maps.each do |xml_name, attr_name|
              map_attribute xml_name, to: attr_name
            end

            inline_flag_ref_maps.each do |xml_name, attr_name|
              map_attribute xml_name, to: attr_name
            end

            inline_child_mappings.each do |mapping|
              map_element mapping[:xml_name], to: mapping[:attr_name]
            end
          end
        end

        klass.attribute attr_name, inline_klass, collection: collection

        build_inline_assembly_json(klass, inline_klass, inline_name,
                                   assembly_def)
      end

      def collect_inline_child_mappings(assembly_def)
        model = assembly_def.model
        return [] unless model

        collect_model_child_mappings(model)
      end

      def build_inline_assembly_json(_parent_klass, inline_klass, inline_name,
assembly_def)
        flag_defs = assembly_def.define_flag || []
        flag_refs = assembly_def.flag || []

        inline_flag_attr_maps = flag_defs.filter_map do |f|
          [f.name, Utils.safe_attr(f.name)] if f.name
        end
        inline_flag_ref_maps = flag_refs.filter_map do |f|
          [f.ref, Utils.safe_attr(f.ref)] if f.ref
        end

        json_field_mappings = collect_json_field_mappings(assembly_def)
        json_assembly_mappings = collect_json_assembly_mappings(assembly_def)

        has_nested_asm = json_assembly_mappings.any?

        if has_nested_asm
          build_inline_assembly_json_custom(
            inline_klass, inline_name, inline_flag_attr_maps, inline_flag_ref_maps,
            json_field_mappings, json_assembly_mappings
          )
        else
          build_inline_assembly_json_standard(
            inline_klass, inline_name, inline_flag_attr_maps, inline_flag_ref_maps,
            json_field_mappings
          )
        end
      end

      def build_inline_assembly_json_standard(inline_klass, inline_name,
                                             inline_flag_attr_maps, inline_flag_ref_maps,
                                             json_field_mappings)
        regular_field_mappings = json_field_mappings.reject do |m|
          m[:vk_flag] || m[:by_key]
        end
        vk_flag_mappings = json_field_mappings.select { |m| m[:vk_flag] }
        by_key_mappings = json_field_mappings.select { |m| m[:by_key] }

        inline_klass.class_eval do
          key_value do
            root inline_name

            inline_flag_attr_maps.each do |xml_name, attr_name|
              map xml_name, to: attr_name
            end

            inline_flag_ref_maps.each do |xml_name, attr_name|
              map xml_name, to: attr_name
            end

            regular_field_mappings.each do |mapping|
              if mapping[:scalar]
                map mapping[:json_name], to: mapping[:attr_name],
                                         with: { to: mapping[:to_method], from: mapping[:from_method] }
              else
                map mapping[:json_name], to: mapping[:attr_name],
                                         render_empty: true
              end
            end
          end
        end

        define_scalar_field_callbacks(inline_klass, regular_field_mappings)

        vk_flag_mappings.each do |mapping|
          callbacks = build_vk_flag_field_callbacks(
            inline_klass, mapping[:field_klass], mapping[:json_name], mapping[:attr_name]
          )
          inline_klass.class_eval do
            key_value do
              map mapping[:json_name], to: mapping[:attr_name],
                                       with: { to: callbacks[:to_method], from: callbacks[:from_method] }
            end
          end
        end

        by_key_mappings.each do |mapping|
          callbacks = build_by_key_field_callbacks(
            inline_klass, mapping[:field_klass], mapping[:json_name],
            mapping[:attr_name], mapping[:json_key_flag]
          )
          inline_klass.class_eval do
            key_value do
              map mapping[:json_name], to: mapping[:attr_name],
                                       with: { to: callbacks[:to_method], from: callbacks[:from_method] }
            end
          end
        end
      end

      def build_inline_assembly_json_custom(inline_klass, inline_name,
                                           inline_flag_attr_maps, inline_flag_ref_maps,
                                           json_field_mappings, json_assembly_mappings)
        regular_field_mappings = json_field_mappings.reject do |m|
          m[:vk_flag] || m[:by_key]
        end
        vk_flag_mappings = json_field_mappings.select { |m| m[:vk_flag] }
        by_key_mappings = json_field_mappings.select { |m| m[:by_key] }

        json_assembly_mappings.each do |mapping|
          json_name = mapping[:json_name]
          attr_sym = mapping[:attr_name]
          mapping[:to_method] =
            :"json_to_asm_#{attr_sym}_#{json_name.gsub('-', '_')}"
        end

        inline_klass.class_eval do
          key_value do
            root inline_name

            inline_flag_attr_maps.each do |xml_name, attr_name|
              map xml_name, to: attr_name
            end

            inline_flag_ref_maps.each do |xml_name, attr_name|
              map xml_name, to: attr_name
            end

            regular_field_mappings.each do |mapping|
              if mapping[:scalar]
                map mapping[:json_name], to: mapping[:attr_name],
                                         with: { to: mapping[:to_method], from: mapping[:from_method] }
              else
                map mapping[:json_name], to: mapping[:attr_name],
                                         render_empty: true
              end
            end

            json_assembly_mappings.each do |mapping|
              map mapping[:json_name], to: mapping[:attr_name],
                                       with: { to: mapping[:to_method] }
            end
          end
        end

        define_scalar_field_callbacks(inline_klass, regular_field_mappings)

        vk_flag_mappings.each do |mapping|
          callbacks = build_vk_flag_field_callbacks(
            inline_klass, mapping[:field_klass], mapping[:json_name], mapping[:attr_name]
          )
          inline_klass.class_eval do
            key_value do
              map mapping[:json_name], to: mapping[:attr_name],
                                       with: { to: callbacks[:to_method], from: callbacks[:from_method] }
            end
          end
        end

        by_key_mappings.each do |mapping|
          callbacks = build_by_key_field_callbacks(
            inline_klass, mapping[:field_klass], mapping[:json_name],
            mapping[:attr_name], mapping[:json_key_flag]
          )
          inline_klass.class_eval do
            key_value do
              map mapping[:json_name], to: mapping[:attr_name],
                                       with: { to: callbacks[:to_method], from: callbacks[:from_method] }
            end
          end
        end

        json_assembly_mappings.each do |mapping|
          attr_sym = mapping[:attr_name]
          to_method = mapping[:to_method]
          json_name = mapping[:json_name]

          inline_klass.define_method(to_method) do |instance, doc|
            current = instance.instance_variable_get("@#{attr_sym}")
            if current
              if current.is_a?(Lutaml::Model::Serializable)
                sub = {}
                current.class.mappings_for(:json).instance_variable_get(:@mappings).each do |key, rule|
                  val = current.send(rule.to)
                  next if val.nil?

                  sub[key] = val.respond_to?(:content) ? val.content : val
                end
                doc[json_name] = sub.empty? ? {} : sub
              else
                doc[json_name] = current
              end
            end
          end
        end
      end

      # ── Choice Handling ───────────────────────────────────────────────

      def process_choice(klass, choice)
        choice.assembly&.each { |ar| add_assembly_reference(klass, ar) }
        choice.field&.each { |fr| add_field_reference(klass, fr) }
        choice.define_assembly&.each { |ad| add_inline_assembly(klass, ad) }
        choice.define_field&.each { |fd| add_inline_field(klass, fd) }
      end

      def process_choice_group(klass, choice_group)
        choice_group.assembly&.each do |ar|
          add_grouped_assembly_reference(klass, ar)
        end
        choice_group.field&.each { |fr| add_grouped_field_reference(klass, fr) }
        choice_group.define_assembly&.each do |ad|
          add_inline_assembly(klass, ad)
        end
        choice_group.define_field&.each { |fd| add_inline_field(klass, fd) }
      end

      def add_grouped_assembly_reference(klass, grouped_ref)
        ref_name = grouped_ref.ref
        return unless ref_name

        assembly_klass = @g.classes["Assembly_#{ref_name.gsub('-', '_')}"] ||
          @g.create_placeholder_assembly(ref_name)

        attr_name = Utils.safe_attr(ref_name)
        klass.attribute attr_name, assembly_klass
      end

      def add_grouped_field_reference(klass, grouped_ref)
        ref_name = grouped_ref.ref
        return unless ref_name

        field_klass = @g.classes["Field_#{ref_name.gsub('-', '_')}"]
        return unless field_klass

        attr_name = Utils.safe_attr(ref_name)
        klass.attribute attr_name, field_klass
      end

      def add_any_content(klass)
        klass.attribute :any_content, :string
      end

      # ── JSON Root Handling ────────────────────────────────────────────

      def add_json_root_handling(klass, json_root)
        klass.instance_variable_set(:@json_root_name, json_root)
        class << klass
          attr_reader :json_root_name
        end

        original_of_json = klass.method(:of_json)
        klass.define_singleton_method(:of_json) do |doc, options = {}|
          if doc.is_a?(Hash) && doc.key?(json_root_name)
            original_of_json.call(doc[json_root_name], options)
          else
            original_of_json.call(doc, options)
          end
        end

        original_to_json = klass.method(:to_json)
        klass.define_singleton_method(:to_json) do |instance, options = {}|
          json_str = original_to_json.call(instance, options)
          { json_root_name => JSON.parse(json_str) }.to_json
        end

        klass.send(:define_method, :to_json) do |options = {}|
          self.class.to_json(self, options)
        end

        original_of_yaml = klass.method(:of_yaml)
        klass.define_singleton_method(:of_yaml) do |doc, options = {}|
          if doc.is_a?(Hash) && doc.key?(json_root_name)
            original_of_yaml.call(doc[json_root_name], options)
          else
            original_of_yaml.call(doc, options)
          end
        end

        original_to_yaml = klass.method(:to_yaml)
        klass.define_singleton_method(:to_yaml) do |instance, options = {}|
          yaml_str = original_to_yaml.call(instance, options)
          data = YAML.safe_load(yaml_str,
                                permitted_classes: [Date, DateTime, Time,
                                                    Symbol])
          { json_root_name => data }.to_yaml
        end

        klass.send(:define_method, :to_yaml) do |options = {}|
          self.class.to_yaml(self, options)
        end
      end
    end
  end
end
