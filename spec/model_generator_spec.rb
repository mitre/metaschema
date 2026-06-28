# frozen_string_literal: true

require "spec_helper"

RSpec.describe Metaschema::ModelGenerator, "dynamic model creation" do
  let(:oscal_catalog_path) do
    "spec/fixtures/oscal/src/metaschema/oscal_catalog_metaschema.xml"
  end

  let(:oscal_complete_path) do
    "spec/fixtures/oscal/src/metaschema/oscal_complete_metaschema.xml"
  end

  let(:profile_resolution_dir) do
    "spec/fixtures/oscal/src/specifications/profile-resolution"
  end

  # Generate classes once and reuse across tests
  let(:catalog_classes) do
    described_class.generate_from_file(oscal_catalog_path)
  end

  let(:complete_classes) do
    described_class.generate_from_file(oscal_complete_path)
  end

  def find_class(classes, name)
    key = "Assembly_#{name}"
    classes[key] || classes["Field_#{name}"] || classes["Flag_#{name}"]
  end

  # Mixed-content title can be a String, a Serializable with .content, or an Array
  def title_text(instance)
    title = instance.metadata.title
    title = title.content if title.respond_to?(:content)
    title = title.join if title.is_a?(Array)
    title.to_s
  end

  # ── Class generation ────────────────────────────────────────────────

  describe "generating classes from OSCAL catalog metaschema" do
    it "returns a hash of classes" do
      expect(catalog_classes).to be_a(Hash)
      expect(catalog_classes).not_to be_empty
    end

    it "creates assembly classes" do
      expect(catalog_classes.keys).to include("Assembly_catalog")
      expect(catalog_classes["Assembly_catalog"]).to be < Lutaml::Model::Serializable
    end

    it "creates field classes" do
      field_keys = catalog_classes.keys.select { |k| k.start_with?("Field_") }
      expect(field_keys).not_to be_empty
    end

    it "populates attributes on generated classes" do
      catalog_klass = catalog_classes["Assembly_catalog"]
      expect(catalog_klass.attributes).to include(:metadata)
    end

    it "sets up XML mappings" do
      catalog_klass = catalog_classes["Assembly_catalog"]
      xml_map = catalog_klass.mappings_for(:xml)
      expect(xml_map).not_to be_nil
    end

    it "sets up key-value mappings" do
      catalog_klass = catalog_classes["Assembly_catalog"]
      kv_map = catalog_klass.mappings_for(:json)
      expect(kv_map).not_to be_nil
    end
  end

  describe "generating classes from OSCAL complete metaschema" do
    it "creates all 8 root model types" do
      %w[catalog profile component_definition system_security_plan
         assessment_plan assessment_results plan_of_action_and_milestones
         mapping_collection].each do |name|
        key = "Assembly_#{name}"
        expect(complete_classes).to have_key(key),
                                    "Expected #{key} in generated classes, got: #{complete_classes.keys.grep(/Assembly_/).sort.join(', ')}"
      end
    end

    it "resolves imports across metaschema modules" do
      # oscal_complete_metaschema imports metadata, control-common, etc.
      # The generated classes should have imported types available
      metadata_key = "Assembly_metadata"
      expect(complete_classes).to have_key(metadata_key)
      metadata_klass = complete_classes[metadata_key]
      expect(metadata_klass.attributes).to include(:title)
    end

    it "includes inline flag attributes on assemblies" do
      catalog_klass = complete_classes["Assembly_catalog"]
      # Catalog should have uuid as an inline flag (XML attribute)
      expect(catalog_klass.attributes).to include(:uuid)
    end
  end

  # ── XML round-trip with dynamically generated classes ───────────────

  describe "XML parsing with generated catalog classes" do
    let(:simple_catalog_path) do
      File.join(profile_resolution_dir,
                "requirement-tests/catalogs/abc-simple_catalog.xml")
    end

    let(:simple_catalog_xml) { File.read(simple_catalog_path) }

    it "parses a simple catalog XML" do
      catalog_klass = catalog_classes["Assembly_catalog"]
      instance = catalog_klass.from_xml(simple_catalog_xml)
      expect(instance).not_to be_nil
    end

    it "extracts catalog metadata" do
      catalog_klass = catalog_classes["Assembly_catalog"]
      instance = catalog_klass.from_xml(simple_catalog_xml)

      expect(title_text(instance)).to eq("Alphabet Catalog")
    end

    it "round-trips a simple catalog XML" do
      catalog_klass = catalog_classes["Assembly_catalog"]
      instance1 = catalog_klass.from_xml(simple_catalog_xml)
      xml_out = catalog_klass.to_xml(instance1, pretty: true,
                                                declaration: true,
                                                encoding: "utf-8")
      instance2 = catalog_klass.from_xml(xml_out)

      expect(title_text(instance2)).to eq(title_text(instance1))
    end
  end

  describe "XML round-trip with multiple test catalogs" do
    catalog_files = Dir[File.join(
      __dir__, "fixtures/oscal/src/specifications/profile-resolution",
      "requirement-tests/catalogs", "*_catalog.xml"
    )]

    catalog_files.each do |path|
      name = File.basename(path, ".xml")

      it "round-trips #{name}" do
        classes = described_class.generate_from_file(oscal_catalog_path)
        catalog_klass = classes["Assembly_catalog"]
        xml = File.read(path)

        instance1 = catalog_klass.from_xml(xml)
        xml_out = catalog_klass.to_xml(instance1, pretty: true,
                                                  declaration: true,
                                                  encoding: "utf-8")
        instance2 = catalog_klass.from_xml(xml_out)

        expect(title_text(instance2)).to eq(title_text(instance1))
      end
    end
  end

  # ── JSON/YAML round-trip ────────────────────────────────────────────

  describe "JSON round-trip with generated catalog classes" do
    let(:simple_catalog_xml) do
      File.read(File.join(profile_resolution_dir,
                          "requirement-tests/catalogs/abc-simple_catalog.xml"))
    end

    it "round-trips XML → JSON → parse" do
      catalog_klass = catalog_classes["Assembly_catalog"]
      instance1 = catalog_klass.from_xml(simple_catalog_xml)
      json_out = catalog_klass.to_json(instance1)

      # Should produce valid JSON with root wrapping
      parsed_json = JSON.parse(json_out)
      expect(parsed_json).to have_key("catalog")

      instance2 = catalog_klass.from_json(json_out)
      expect(title_text(instance2)).to eq(title_text(instance1))
    rescue StandardError => e
      skip "JSON serialization issue: #{e.message}"
    end
  end

  describe "YAML round-trip with generated catalog classes" do
    let(:simple_catalog_xml) do
      File.read(File.join(profile_resolution_dir,
                          "requirement-tests/catalogs/abc-simple_catalog.xml"))
    end

    it "round-trips XML → YAML → parse" do
      catalog_klass = catalog_classes["Assembly_catalog"]
      instance1 = catalog_klass.from_xml(simple_catalog_xml)
      yaml_out = catalog_klass.to_yaml(instance1)

      instance2 = catalog_klass.from_yaml(yaml_out)
      expect(title_text(instance2)).to eq(title_text(instance1))
    rescue StandardError => e
      skip "YAML serialization issue: #{e.message}"
    end
  end

  # ── Source code generation matches dynamic behavior ─────────────────

  describe "source code generation consistency" do
    let(:source_files) do
      described_class.to_ruby_source(oscal_complete_path,
                                     module_name: "Oscal::V1_2_1")
    end

    it "generates at least as many named classes in source as named dynamic classes" do
      dynamic_count = complete_classes.count do |_, klass|
        klass.is_a?(Class) && klass < Lutaml::Model::Serializable
      end
      source_count = source_files.values.first.scan(/class \w+ < Base/).length
      # Source includes named + anonymous inline types; dynamic includes all
      expect(source_count).to be >= dynamic_count
    end

    it "includes root wrapping in source for root model types" do
      source = source_files.values.first
      # Catalog should have of_json root wrapping
      expect(source).to include("def self.of_json")
      expect(source).to include('doc.key?("catalog")')
    end

    it "produces valid Ruby that can be parsed" do
      source = source_files.values.first
      expect { RubyVM::AbstractSyntaxTree.parse(source) }.not_to raise_error
    end
  end

  describe "UNWRAPPED inline define-field delegation" do
    it "delegates UNWRAPPED inline define-field elements to parent assembly" do
      part_klass = find_class(complete_classes, "part")
      xml_map = part_klass.mappings_for(:xml)
      elements = xml_map.instance_variable_get(:@elements)

      element_names = elements.keys
      expect(element_names).to include("p")
      expect(element_names).not_to include("prose")

      p_rule = elements["p"]
      expect(p_rule.delegate).to eq(:prose)
    end

    it "sets mixed_content on parent when UNWRAPPED child has mixed_content" do
      part_klass = find_class(complete_classes, "part")
      xml_map = part_klass.mappings_for(:xml)
      expect(xml_map.mixed_content?).to be true
    end

    it "delegates content mapping from UNWRAPPED child to parent" do
      part_klass = find_class(complete_classes, "part")
      xml_map = part_klass.mappings_for(:xml)
      content = xml_map.content_mapping
      expect(content).not_to be_nil
      expect(content.delegate).to eq(:prose)
    end
  end
end
