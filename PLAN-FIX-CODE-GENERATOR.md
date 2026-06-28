# Plan: Fix Code Generator for OSCAL JSON/YAML Parsing

## Problem

The metaschema code generator (`ModelGenerator` + `RubySourceEmitter`) produces
Ruby source code that cannot parse NIST-published OSCAL JSON/YAML files. The
generated models work for XML but fail for key-value formats (JSON/YAML) due to
three categories of bugs in the generator.

## Root Causes

### 1. UNWRAPPED inline field delegation missing

**File:** `lib/metaschema/model_generator/assembly_factory.rb:161-166`

`collect_model_child_mappings` checks `in_xml == "UNWRAPPED"` for `model.field`
(referenced fields, line 142) but NOT for `model.define_field` (inline field
definitions, line 161-166). OSCAL uses inline `define-field` with
`in-xml="UNWRAPPED"` for prose content in Part and ParameterGuideline.

Result: prose `<p>` elements inside `<part>` are silently dropped during XML
parsing. The prose field gets `map_element "prose"` instead of delegated inline
elements.

Additionally, `delegate_field_xml_mappings` (line 98-121) adds `map_content`
with `delegate:` to the parent, but the parent's XML block only has `ordered`
(not `mixed_content`). lutaml-model rejects `map_content` inside `ordered`
without `mixed_content`.

### 2. Generated module header missing `require "metaschema"`

**File:** `lib/metaschema/ruby_source_emitter.rb:260-272`

`emit_module_header` generates the `# frozen_string_literal: true` comment and
module/Base class but does NOT emit `require "metaschema"`. The generated code
references `Metaschema::AnchorType` and 10 other Metaschema types at
class-definition time. Without the require, loading the generated file in
isolation causes `NameError`.

### 3. SINGLETON_OR_ARRAY custom methods have string handling bugs

**File:** `lib/metaschema/model_generator/services/field_serializer.rb` and
`field_deserializer.rb`

The generated `json_from_*` custom methods (SINGLETON_OR_ARRAY pattern) have
two bugs:

a. The `elsif value` branch passes raw strings to `Type.of_json(value)` which
   expects a Hash. OSCAL JSON uses plain strings for markup fields (title,
   last-modified, remarks) but the generated code treats them as complex objects.

b. The `json_assembly_soa_from_*` methods always wrap results in an Array via
   `instance.instance_variable_set(:@attr, parsed)` where `parsed` is always
   an Array. For singular attributes (metadata, back_matter), the result should
   be unwrapped.

c. The `json_assembly_soa_to_*` methods only handle Array values
   (`if current.is_a?(Array)`), not singular Serializable objects. After fix (b),
   singular attributes won't serialize.

### 4. Generated `to_yaml` uses `YAML.safe_load` on Ruby-tagged output

**File:** Generated root wrapping methods in `ruby_source_emitter.rb`

The generated `to_yaml` methods call `super` (which produces YAML with Ruby
class tags like `!ruby/object:Oscal::V1_2_1::Link`), then `YAML.safe_load`
the result. `safe_load` rejects Ruby class tags → `Psych::DisallowedClass`.

## Fix Plan

### Card 1: UNWRAPPED inline field delegation (sp:3)
- `assembly_factory.rb:161-166` — add `unwrapped` detection for `define_field`
- `assembly_factory.rb:74-91` — propagate `mixed_content` to parent XML block
  when any unwrapped mapping has a mixed-content child
- `assembly_factory.rb:98-121` — no changes needed (delegation logic is correct)

### Card 2: Emit `require "metaschema"` in generated header (sp:1)
- `ruby_source_emitter.rb:260-272` — add `require "metaschema"` after
  frozen_string_literal in `emit_module_header`

### Card 3: Fix SINGLETON_OR_ARRAY string handling (sp:3)
- Identify where string coercion belongs (field_deserializer.rb or
  field_serializer.rb) — research the custom method generation path
- Fix the `elsif value` branch to coerce strings to content hashes
- Fix `json_assembly_soa_from_*` to unwrap singular attributes
- Fix `json_assembly_soa_to_*` to handle singular Serializable objects

### Card 4: Fix `to_yaml` generation (sp:2)
- Change generated `to_yaml` to use `as_yaml` + `.to_yaml` instead of
  `super` + `YAML.safe_load` re-parse

## Test Strategy

Each card writes failing tests FIRST against the OSCAL complete metaschema
fixture (`spec/fixtures/oscal/src/metaschema/oscal_complete_metaschema.xml`),
then implements the fix. Tests verify the generated Ruby source code contains
the correct patterns.

## Verification

After all cards: regenerate the oscal gem's `all_models.rb` using the fixed
metaschema gem. All 78 oscal tests should pass with 0 pending.
