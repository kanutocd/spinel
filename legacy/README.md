# legacy

This directory holds the original Ruby implementation of Spinel. The
compiler is now the C `spinel` binary (`../src/`); this tree is kept solely
as a headless regression oracle.

- `spinel_analyze.rb`: self-hosted analyzer
- `spinel_codegen.rb`: self-hosted code generator
- `compiler_helpers.rb`: shared Ruby helpers for the compiler passes
- `node_table_loader.rb`: AST loader used by the Ruby backend
- `Makefile`: builds the backend + runs the self-host fixpoint

The active compiler work happens in `../src/`.

There is no user-facing driver here anymore — the C `spinel` replaced it.
This tree is exercised only through `make` targets that run from the parent:

- `make bootstrap` — the self-host fixpoint authority (the Ruby compiler
  compiles itself; round 2 must equal round 3 byte-for-byte).
- `make analyze-fail-test` — checks the analyzer's rejection diagnostics.

`make legacy` / `make bootstrap` build everything under `build/` (i.e.
`legacy/build/`: binaries + bootstrap intermediates), borrowing the parser
and runtime library from the parent tree; nothing here is installed. The
normal C build never touches this directory's sources.
