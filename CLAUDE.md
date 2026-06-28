# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a Ruby gem implementing a parser and generator for the [NIST Metaschema Information Modeling Framework](https://pages.nist.gov/metaschema). It parses Metaschema XML files and can round-trip them (parse to Ruby objects and back to XML).

## Common Commands

```bash
# Install dependencies
bundle install

# Run full test suite (parallel — preferred)
bundle exec parallel_rspec spec/ -n 4

# Run full test suite (sequential)
bundle exec rake spec

# Run a single test file
bundle exec rspec spec/metaschema_spec.rb

# Run a single test by line
bundle exec rspec spec/model_generator_spec.rb:236

# Run tests matching a pattern
bundle exec rspec -e "UNWRAPPED"

# Run linting
bundle exec rake rubocop

# Auto-correct linting issues
bundle exec rake rubocop:autocorrect_all

# Build the gem
bundle exec rake build
```

## Architecture

The gem uses **lutaml-model** with **Nokogiri** for XML serialization/deserialization. All model classes inherit from `Lutaml::Model::Serializable`.

### Entry Point

`lib/metaschema/root.rb` - The `Metaschema::Root` class is the top-level model representing a complete Metaschema XML document. It contains:
- `schema_name`, `schema_version`, `short_name`, `namespace`, `json_base_uri`
- Top-level definitions: `define_assembly`, `define_field`, `define_flag`
- Imports and namespace bindings

### Type System

The `lib/metaschema/` directory contains ~74 type classes. Key patterns:

- **Definition types** (e.g., `GlobalAssemblyDefinitionType`, `GlobalFieldDefinitionType`) - Define schema structures with `name`, `formal_name`, `description`, `model`, `constraint`
- **Reference types** (e.g., `AssemblyReferenceType`, `FieldReferenceType`) - Reference definitions by name
- **Inline definition types** (e.g., `InlineAssemblyDefinitionType`) - Definitions nested within other definitions
- **Constraint types** (e.g., `DefineAssemblyConstraintsType`, `AllowedValuesType`) - Validation constraints
- **Value types** (e.g., `MarkupLineDatatype`, `FormalName`) - Simple value wrappers

Each type class uses the lutaml-model XML DSL:
```ruby
xml do
  element "ElementName"
  ordered  # children must appear in defined order
  namespace ::Metaschema::Namespace
  map_attribute "attr", to: :attr_name
  map_element "child-element", to: :child_attr
end
```

### Test Fixtures

- `spec/fixtures/metaschema/` - Submoduled NIST Metaschema project containing test schemas
- `spec/fixtures/metaschema/examples/` - Example Metaschema XML files (e.g., `computer-example.xml`)
- `spec/fixtures/metaschema/test-suite/schema-generation/` - Feature-specific test cases

### Loading a Metaschema File

```ruby
require 'metaschema'
ms = Metaschema::Root.from_file("path/to/metaschema.xml")
ms.to_xml  # Returns XML string
```


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->
