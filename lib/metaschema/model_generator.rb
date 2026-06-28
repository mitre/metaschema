# frozen_string_literal: true

require_relative "model_generator/utils"
require_relative "model_generator/field_factory"
require_relative "model_generator/assembly_factory"
require_relative "model_generator/services/collapsibles_collapser"
require_relative "model_generator/services/field_serializer"
require_relative "model_generator/services/field_deserializer"

module Metaschema
  # Generates Ruby classes (Lutaml::Model::Serializable subclasses) from
  # NIST Metaschema definitions. The generated classes support XML and JSON
  # round-tripping with full fidelity.
  #
  # Delegates field class creation to FieldFactory and assembly class
  # creation to AssemblyFactory. This class handles import resolution,
  # augment application, and shared utilities.
  class ModelGenerator
    class << self
      def generate_from_file(metaschema_path, base_path: nil)
        base_path ||= File.dirname(File.expand_path(metaschema_path))
        generate_from_xml(File.read(metaschema_path), base_path: base_path)
      end

      def generate_from_xml(xml_string, base_path: nil)
        metaschema = Metaschema::Root.from_xml(xml_string)
        new.generate(metaschema, base_path: base_path)
      end

      def generate_from_metaschema(metaschema, base_path: nil)
        new.generate(metaschema, base_path: base_path)
      end

      def to_ruby_source(metaschema_path, module_name:, base_path: nil,
split: false)
        base_path ||= File.dirname(File.expand_path(metaschema_path))
        metaschema = Metaschema::Root.from_xml(File.read(metaschema_path))
        generator = new
        classes = generator.generate(metaschema, base_path: base_path)
        emitter = RubySourceEmitter.new(classes, module_name, generator)
        split ? emitter.emit_split : emitter.emit
      end
    end

    # Shared state — accessed by FieldFactory and AssemblyFactory via @g
    attr_reader :classes, :field_defs, :assembly_defs, :flag_defs, :namespace
    attr_accessor :current_assembly_name

    def runtime_namespace_class
      return @runtime_namespace_class if defined?(@runtime_namespace_class)

      @runtime_namespace_class = if @namespace && !@namespace.empty?
                                   ns_uri = @namespace
                                   Class.new(Lutaml::Xml::Namespace) do
                                     uri ns_uri
                                     prefix_default ""
                                   end
                                 end
    end

    def generate(metaschema, base_path: nil)
      @classes = {}
      @flag_defs = {}
      @assembly_defs = {}
      @field_defs = {}
      @namespace = metaschema.namespace
      @current_assembly_name = nil

      # Resolve imports — merge definitions from imported modules
      resolve_and_merge_imports(metaschema, base_path)

      collect_flag_definitions(metaschema)
      collect_definition_registries(metaschema)

      # Apply augments — add docs/flags to imported definitions
      apply_augments(metaschema)

      # Phase 1: Create field classes for all definitions (top-level + imported)
      @field_defs.each_value do |fd|
        next if @classes.key?("Field_#{Utils.safe_attr(fd.name)}")

        FieldFactory.new(fd, self).create
      end

      # Phase 1: Create assembly placeholders for all definitions
      # Phase 2: Populate assembly classes for all definitions
      @assembly_defs.each_value do |ad|
        factory = AssemblyFactory.new(ad, self)
        factory.create_placeholder
        factory.populate
      end

      @classes
    end

    # ── XML Element Name Resolution ──────────────────────────────────

    def assembly_xml_element_name(assembly_ref)
      ref_name = assembly_ref.ref
      return ref_name unless ref_name

      return assembly_ref.use_name.content if assembly_ref.use_name&.content

      defn = @assembly_defs[ref_name]
      return defn.use_name.content if defn&.use_name&.content

      ref_name
    end

    def field_xml_element_name(field_ref)
      ref_name = field_ref.ref
      return ref_name unless ref_name

      return field_ref.use_name.content if field_ref.use_name&.content

      defn = @field_defs[ref_name]
      return defn.use_name.content if defn&.use_name&.content

      ref_name
    end

    # ── Shared Utilities (used by both factories) ──────────────────────

    def add_inline_flag(klass, flag_def)
      return unless flag_def.name

      attr_name = Utils.safe_attr(flag_def.name)
      type = TypeMapper.map(flag_def.as_type)
      klass.attribute attr_name, type
    end

    def add_flag_reference(klass, flag_ref)
      return unless flag_ref.ref

      flag_name = flag_ref.ref
      flag_def = @flag_defs[flag_name]
      attr_name = Utils.safe_attr(flag_name)
      type = flag_def ? TypeMapper.map(flag_def.as_type) : :string
      klass.attribute attr_name, type
    end

    def scoped_field_name(field_name)
      base = "Field_#{field_name.gsub('-', '_')}"
      @current_assembly_name ? "#{base}_in_#{@current_assembly_name}" : base
    end

    def create_placeholder_assembly(name)
      key = "Assembly_#{name.gsub('-', '_')}"
      @classes[key] ||= Class.new(Lutaml::Model::Serializable)
    end

    # ── Constraint Validation Integration ──────────────────────────────

    def apply_constraint_validation(klass, constraint_def)
      return unless constraint_def

      klass.instance_variable_set(:@metaschema_constraints, constraint_def)
      klass.define_singleton_method(:metaschema_constraints) do
        @metaschema_constraints
      end

      klass.define_method(:validate_constraints) do
        validator = ConstraintValidator.new
        validator.validate(self, self.class.metaschema_constraints)
      end
    end

    private

    # ── Import Resolution ──────────────────────────────────────────────

    def resolve_and_merge_imports(metaschema, base_path)
      imported_defs = resolve_imports(metaschema, base_path)

      # Merge imported definitions — first definition wins (top-level takes priority)
      imported_defs.each do |defs|
        defs[:flags].each { |name, defn| @flag_defs[name] ||= defn }
        defs[:assemblies].each { |name, defn| @assembly_defs[name] ||= defn }
        defs[:fields].each { |name, defn| @field_defs[name] ||= defn }
      end
    end

    def resolve_imports(metaschema, base_path, visited: Set.new)
      imports = metaschema.import
      return [] unless imports && !imports.empty?

      imports.flat_map do |import_elem|
        href = import_elem.href
        next [] unless href

        # Resolve relative to the importing file's directory
        import_path = if base_path
                        File.expand_path(href,
                                         base_path)
                      else
                        File.expand_path(href)
                      end
        next [] unless File.exist?(import_path)

        # Cycle detection — skip already-visited files
        next [] if visited.include?(import_path)

        visited.add(import_path)

        # Parse the imported metaschema
        imported = Metaschema::Root.from_xml(File.read(import_path))

        # Recursively resolve transitive imports
        transitive = resolve_imports(imported, File.dirname(import_path),
                                     visited: visited)

        # Collect definitions from this imported module
        defs = { flags: {}, assemblies: {}, fields: {} }
        imported.define_flag&.each { |f| defs[:flags][f.name] = f if f.name }
        imported.define_assembly&.each do |a|
          defs[:assemblies][a.name] = a if a.name
        end
        imported.define_field&.each { |f| defs[:fields][f.name] = f if f.name }

        transitive + [defs]
      end
    end

    # ── Augment Application ─────────────────────────────────────────────

    def apply_augments(metaschema)
      return unless metaschema.respond_to?(:augment)

      augments = metaschema.augment
      return unless augments && !augments.empty?

      augments.each do |aug|
        name = aug.name
        next unless name

        # Try to find the definition to augment
        target = @assembly_defs[name] || @field_defs[name] || @flag_defs[name]
        next unless target

        # Apply documentation augmentations
        apply_augment_docs(target, aug)
        apply_augment_flags(target, aug)
      end
    end

    def apply_augment_docs(target, augment)
      if augment.formal_name && !target.formal_name
        target.formal_name = augment.formal_name
      end

      if augment.description && (!target.respond_to?(:description) || !target.description) && target.respond_to?(:description=)
        target.description = augment.description
      end
    end

    def apply_augment_flags(target, augment)
      return unless augment.flag&.any? || augment.define_flag&.any?

      if target.respond_to?(:flag)
        existing_refs = (target.flag || []).map(&:ref)
        augment.flag.each do |fr|
          next if existing_refs.include?(fr.ref)

          target.flag = (target.flag || []) + [fr]
        end
      end

      if target.respond_to?(:define_flag)
        existing_names = (target.define_flag || []).map(&:name)
        augment.define_flag.each do |fd|
          next if existing_names.include?(fd.name)

          target.define_flag = (target.define_flag || []) + [fd]
        end
      end
    end

    # ── Definition Collection ──────────────────────────────────────────

    def collect_flag_definitions(metaschema)
      metaschema.define_flag&.each do |flag_def|
        @flag_defs[flag_def.name] = flag_def if flag_def.name
      end
    end

    def collect_definition_registries(metaschema)
      metaschema.define_assembly&.each do |ad|
        @assembly_defs[ad.name] = ad if ad.name
      end
      metaschema.define_field&.each do |fd|
        @field_defs[fd.name] = fd if fd.name
      end
    end
  end
end
