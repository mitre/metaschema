# frozen_string_literal: true

require "spec_helper"

RSpec.describe Metaschema::ModelGenerator, ".to_ruby_source" do
  let(:metaschema_path) do
    "spec/fixtures/metaschema/test-suite/worked-examples/everything-metaschema/everything_metaschema.xml"
  end

  let(:oscal_path) do
    "spec/fixtures/oscal/src/metaschema/oscal_catalog_metaschema.xml"
  end

  let(:oscal_complete_path) do
    "spec/fixtures/oscal/src/metaschema/oscal_complete_metaschema.xml"
  end

  describe "with everything_metaschema" do
    let(:files) do
      described_class.to_ruby_source(metaschema_path,
                                     module_name: "TestEverything")
    end

    it "returns a hash with at least one file" do
      expect(files).to be_a(Hash)
      expect(files).not_to be_empty
    end

    it "produces valid Ruby syntax" do
      source = files.values.first
      expect { RubyVM::AbstractSyntaxTree.parse(source) }.not_to raise_error
    end

    it "wraps classes in the specified module" do
      source = files.values.first
      expect(source).to include("module TestEverything")
    end

    it "includes class definitions inheriting from Base" do
      source = files.values.first
      expect(source).to match(/class \w+ < Base/)
    end
  end

  describe "with OSCAL catalog metaschema" do
    let(:files) do
      described_class.to_ruby_source(oscal_path, module_name: "Oscal::V1_2_1")
    end

    it "produces valid Ruby syntax" do
      source = files.values.first
      expect { RubyVM::AbstractSyntaxTree.parse(source) }.not_to raise_error
    end

    it "includes a Catalog class" do
      source = files.values.first
      expect(source).to include("class Catalog < Base")
    end

    it "includes XML mappings" do
      source = files.values.first
      expect(source).to include('element "catalog"')
      expect(source).to include('map_element "metadata"')
    end

    it "includes key-value mappings" do
      source = files.values.first
      expect(source).to include("key_value do")
    end

    it "includes root wrapping for catalog" do
      source = files.values.first
      expect(source).to include("def self.of_json")
      expect(source).to include("def self.to_json")
    end
  end

  describe "with OSCAL complete metaschema" do
    let(:files) do
      described_class.to_ruby_source(oscal_complete_path, module_name: "Oscal::V1_2_1")
    end

    it "produces valid Ruby syntax for all classes" do
      source = files.values.first
      expect { RubyVM::AbstractSyntaxTree.parse(source) }.not_to raise_error
      # 122 named classes + anonymous inline types
      expect(source.scan(/class \w+ < Base/).length).to be >= 122
    end

    it "includes all 8 root model types" do
      source = files.values.first
      %w[Catalog Profile ComponentDefinition SystemSecurityPlan
         AssessmentPlan AssessmentResults PlanOfActionAndMilestones
         MappingCollection].each do |name|
        expect(source).to include("class #{name} < Base")
      end
    end

    it "includes require 'metaschema' in the generated header" do
      source = files.values.first
      lines = source.lines.map(&:strip)
      frozen_idx = lines.index("# frozen_string_literal: true")
      require_idx = lines.index('require "metaschema"')
      module_idx = lines.index { |l| l.start_with?("module ") }

      expect(require_idx).not_to be_nil
      expect(require_idx).to be > frozen_idx
      expect(require_idx).to be < module_idx
    end

    it "generated to_yaml does not use YAML.safe_load" do
      source = files.values.first
      to_yaml_methods = source.scan(/def self\.to_yaml.*?end/m)
      expect(to_yaml_methods).not_to be_empty

      to_yaml_methods.each do |method_source|
        expect(method_source).not_to include("YAML.safe_load")
      end
    end

    it "generated to_yaml uses as_yaml for root wrapping" do
      source = files.values.first
      to_yaml_methods = source.scan(/def self\.to_yaml.*?end/m)
      expect(to_yaml_methods).not_to be_empty

      to_yaml_methods.each do |method_source|
        expect(method_source).to include("as_yaml")
      end
    end

    it "generated json_from elsif branch does not pass raw strings to of_json" do
      source = files.values.first
      scalar_from_methods = source.scan(/def json_from_\w+\(instance, value\).*?^    end/m)
      serializable_methods = scalar_from_methods.select { |m| m.include?(".of_json(") }
      expect(serializable_methods).not_to be_empty

      serializable_methods.each do |m|
        elsif_branch = m[/elsif value\n(.*?)(?=      end)/m, 1]
        next unless elsif_branch&.include?(".of_json(")

        expect(elsif_branch).not_to include(".of_json(value)"),
          "Expected elsif branch to coerce value before of_json, not pass raw:\n#{elsif_branch}"
      end
    end

    it "generated json_assembly_soa_from unwraps singular Hash input" do
      source = files.values.first
      soa_from_methods = source.scan(/def json_assembly_soa_from_\w+\(instance, value\).*?^    end/m)
      expect(soa_from_methods).not_to be_empty

      has_unwrap = soa_from_methods.any? { |m| m.include?("parsed.first") || m.include?("value.is_a?(Hash)") }
      expect(has_unwrap).to be(true), "Expected json_assembly_soa_from methods to unwrap singular Hash to non-Array"
    end

    it "generated json_assembly_soa_to handles singular Serializable objects" do
      source = files.values.first
      soa_to_methods = source.scan(/def json_assembly_soa_to_\w+\(instance, doc\).*?^    end/m)
      expect(soa_to_methods).not_to be_empty

      has_singular = soa_to_methods.any? { |m| m.include?("elsif current.is_a?(Lutaml::Model::Serializable)") }
      expect(has_singular).to be(true), "Expected json_assembly_soa_to methods to handle singular Serializable"
    end

    it "uses symbol type references for class attributes" do
      source = files.values.first
      # Catalog's metadata attribute should use symbol reference
      catalog_start = source.index("class Catalog <")
      catalog_end = source.index("  end", catalog_start)
      catalog_source = source[catalog_start..catalog_end]
      expect(catalog_source).to include("attribute :metadata, :metadata")
    end
  end
end
