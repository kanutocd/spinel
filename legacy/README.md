# legacy

This directory holds the current Ruby implementation of Spinel.

- `spinel_analyze.rb`: self-hosted analyzer
- `spinel_codegen.rb`: self-hosted code generator
- `compiler_helpers.rb`: shared Ruby helpers for the compiler passes
- `node_table_loader.rb`: AST loader used by the Ruby backend

The active compiler migration work should happen in `src/`.
