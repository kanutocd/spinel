# C-SPINEL: Reimplementing the Spinel compiler in C

## Why

Spinel is an AOT Ruby-to-C compiler that is **self-hosted**: the analyzer and
code generator are written in Ruby (`legacy/spinel_analyze.rb`,
`legacy/spinel_codegen.rb`) and are themselves compiled to C by Spinel. The
problem is build time. Bootstrapping compiles ~93k lines of Ruby through the
whole pipeline into multi-megabyte C files, and the `-O3 -flto` link of that
generated C dominates the dev loop (the reason the memory keeps a "use LTO=0"
note). Every inference change risks a stage-2 self-host cascade because the
compiler is written in the very subset it compiles.

Rewriting the analyzer and code generator **directly in C** removes both costs:
the compiler becomes a small, fast-to-build native program, and an entire class
of self-host hazards disappears (see "What gets easier" below).

## Goal (definition of done)

1. A single C binary in `src/` that compiles a `.rb` file end to end.
2. New Makefile targets `test`, `bench`, `optcarrot` driving that binary, plus
   a `legacy` target that builds the Ruby compiler as a regression oracle.
3. `make test` passes (the 844-case `test/` golden corpus).
4. `make bench` and `make optcarrot` pass.

The ordering in the request is deliberate: stand up the targets (`test`,
`bench`, `optcarrot`, `legacy`), then drive them to green starting with `test`.

## Architecture

### One binary, no intermediate files

Today the pipeline is three programs talking through files on disk:

```
app.rb --[spinel_parse (C)]--> app.ast --[spinel_analyze (Ruby)]--> app.ir --[spinel_codegen (Ruby)]--> app.c --[cc]--> app
```

The C rewrite collapses analyze+codegen into **one process** that holds the
shared compiler state in memory and never serializes the AST or IR for normal
operation:

```
app.rb --[Prism walk]--> node table (in mem) --[analyze]--> Compiler state (in mem) --[codegen]--> app.c --[cc]--> app
```

C source is split across ~8-15 translation units (TUs) for fast incremental
builds, but they **link into one binary**. "Split the source, not the program."

### The front end is already done — reuse it

`spinel_parse.c` (~2500 lines) already walks the full Prism AST and emits the
text node-table format. It parses everything the test corpus needs. We refactor
it to **populate an in-memory node table** (the same node schema) instead of
printing text. That makes the front end ~100% complete on day one.

**Consequence: the entire port surface and all the risk is analyze + codegen.**
The plan below is almost entirely about those two.

### Reuse the runtime library unchanged

`lib/` already contains the full C runtime the generated programs link against:
`sp_runtime.h` (the big header the emitted C `#include`s), `libspinel_rt.a`
(bigint, regexp engine, GC, fiber, pack, strscan, time, net, io, crypto —
~10k lines of C). The generated C is unchanged in shape, so **the runtime is
reused as-is**. Our code generator must emit the same `sp_*` calls the legacy
generator emits (e.g. `sp_int_add`, `SP_GC_SAVE`, the `needs_*` prologue).

### The IR dump is the schema of the central struct

The legacy `.ir` file is a serialization of the analyzer's `@ivar` state — the
whole-program tables the code generator reads back: `needs_*` capability flags,
`@meth_names` / `@meth_param_types` / per-class method tables, inferred node
types, etc. In one binary those stages stop serializing and **share one
`Compiler` struct**. That struct's field inventory is exactly the set of lines
in a representative `.ir` dump.

Design this struct first; it is the backbone of the whole program. Derive its
fields by dumping the IR of a *rich* program (not the 13-line `puts 1+2` case)
and cataloguing every `INT/STR/SA/...` key.

## Type system (highest-risk foundation — design before code)

Spinel's lattice is a set of **string tags**, ported verbatim as interned type
ids (an enum for the closed core, plus parameterized container tags). From the
analyzer the live tag vocabulary is:

- Scalars: `int`, `float`, `string`, `symbol`/`sym`, `bool`, `nil`, `bigint`
- Nullable scalars: `int?`, `string?`, `float?` (sentinel-encoded; see memory)
- Typed arrays: `int_array`, `float_array`, `str_array`, `poly_array`,
  `ptr_array`
- Typed hashes: `int_int_hash`, `str_int_hash`, `str_str_hash`, `int_str_hash`,
  `sym_int_hash`, `sym_str_hash`, ... (key_value naming)
- Other: `range`, `regexp`, `proc`, `lambda`, `class`, `void`
- `poly` — the union / top type (a value whose static type widened)

`base_type(t)` strips nullability/decoration to the core tag and is called
everywhere; `infer_type(nid)` is the central query. **Before writing the
type module, read the actual representation in `legacy/compiler_helpers.rb`
(`compiler_state_field_type`, `compile_time_literal_type`,
`infer_nil_guard_narrow_type`, `poly_dispatch_*`, `base_type`) and the type
constants in `spinel_analyze.rb`.** This is the foundation and the area where a
wrong model costs the most.

Representation plan: a small `sp_type` value = interned id. Containers and
hashes get a compact encoding (enum kind + element/key/value tags). Provide the
helper surface the passes need: `base_type`, `is_nullable`, `nullable_of`,
`unify`/widen-to-poly, `array_of`, `hash_of`, tag<->string for `--dump-ir`.

## CLI / cc contract

The binary's job for the harness is **`.rb -> C`**; a thin wrapper (or the
binary itself) invokes `cc` to link against `libspinel_rt.a`, mirroring the
existing `spinel` shell script so harness edits stay minimal. Scope for `make
test`:

- Required modes: emit-C-to-file and emit-C-to-stdout; the cc-and-link step.
- Required overflow modes: **`raise`** (default, used by `test`) and **`wrap`**
  (used by `optcarrot`, which routes through `spinel --int-overflow=wrap`).
  `promote` is deferred.
- **Not needed for `make test`** and explicitly out of initial scope: `-e`/`-E`
  run mode, `--emit-rbs`, `--emit-types`, `--emit-symbol-map`, RBS seeding,
  FFI link/cflag scraping, `--debug`/`#line` line-mapping. Add later only if a
  target needs them. (optcarrot/bench/test do not.)

`docs/INCOMPATIBILITIES.md` is part of the behavioral spec — intentional
divergences from CRuby (e.g. `Integer#**` negative exponent = RangeError) must
be preserved, not "fixed."

## Verification strategy

The ratchet is **output equivalence**, exactly what the harness already does:
parse → analyze → codegen → cc → run, then `diff` against `test/<name>.rb.expected`
(and against CRuby for `bench`/`optcarrot`). We do **not** need bit-exact IR
parity with legacy, nor legacy's inference precision, nor its speed — only
inference precise enough to compile and to match *observable* semantics
(nil/nullable behavior, overflow mode, hash defaults, `INCOMPATIBILITIES.md`).

Debugging lens (keep, but never gate on it): retain optional `--dump-ast` /
`--dump-ir` text output in the legacy format. Two payoffs on a 93k-line port:

1. **Localization** — diff our analyzer's IR against legacy's at the stage
   boundary ("node 412 got `poly` not `int_array`") instead of "test N fails
   somewhere downstream."
2. **Cross-execution** — feed legacy's IR into our codegen, or our IR into
   legacy's codegen, to isolate *which stage* diverged.

Bit-exact IR is too brittle to gate on (counters, hash iteration order), so it
stays a lens, not a gate.

`make legacy` builds the Ruby oracle (`spinel_analyze`/`spinel_codegen` via the
existing bootstrap path) so it stays available for these diffs and for any test
whose `.expected` needs regenerating.

## What gets easier (and what doesn't)

Roughly half the hazards in the project memory exist **only because the
compiler was written in the subset it compiles**: stage-2 self-host cascades,
node-id/seed "poison" (`get_args` widening, node-id-as-poly), "widening breaks
bootstrap," the MRI-harness-vs-self-host divergences. In hand-written C these
are **gone** — write the inference straightforwardly, no placeholder-parity or
post-fixpoint re-narrow gymnastics needed to keep a bootstrap alive.

What does **not** get easier: over-widening still changes program output (a
value typed `poly` when it should be `int_array` can pick a different runtime
path), and nullable/overflow/default semantics still have to match. "Relaxed"
is not "free." Correctness is still judged by the goldens.

## Source layout (`src/`)

Target ~8-15 TUs, each budgeted to ~2-3k lines so no single `.c` dominates
compile time. Initial split (will be refined as codegen grows):

| File | Responsibility |
|------|----------------|
| `main.c` | CLI parsing, mode dispatch, cc invocation |
| `node_table.{c,h}` | AST node storage (parallel arrays: type, string/int/ref/array fields), the schema Prism populates |
| `parse.c` | Prism walk → node table (adapted from `spinel_parse.c`) |
| `compiler.{c,h}` | the shared `Compiler` state struct (= IR schema) + lifecycle |
| `types.{c,h}` | type lattice: tags, `base_type`, unify, container/hash encoding, tag<->string |
| `analyze.c` + `analyze_*.c` | inference passes, split by area (literals, methods, classes, hashes/containers, fixpoint driver) |
| `codegen.c` + `codegen_*.c` | C emission, split by area (expr, stmt, class/method, builtins: string / array / hash, runtime prologue & `needs_*`) |
| `emit.{c,h}` | output buffer + formatting helpers shared by codegen |
| `irdump.c` | optional `--dump-ast`/`--dump-ir` (debug lens) |

Build: per-module `.o`, relink-only-changed. Modular incremental compilation is
**the deliverable's actual value** and a first-class design constraint, not an
afterthought.

## Build / Makefile changes

Confirmed directional decisions (2026-06-08):

- **Front end:** reuse `spinel_parse.c`'s Prism walk, refactored to fill the
  in-memory node table; keep its text output as `--dump-ast`.
- **CLI/cc:** the C binary does `.rb -> C` only; a thin driver (the existing
  `spinel` script, repointed) invokes `cc`/link. Minimal harness change.
- **Targets:** repoint `test`/`bench`/`optcarrot` at the C binary **from the
  start** — no interim parallel target. The trade-off is accepted: these main
  targets are red until parity is reached. `legacy` is added for the oracle.

Concretely:

- **`test`/`bench`/`optcarrot`** are repointed at the new C binary immediately.
  Until M4 they will report failures; that is the expected state during the
  climb, and the failing-test count is the progress metric.
- **New `legacy` target:** build the Ruby `spinel_analyze`/`spinel_codegen`
  oracle (the current bootstrap path), used for IR diffs and `.expected` regen.
  This preserves access to the oracle even after the main targets move.
- New `src/`-driven object rules with a per-file size budget; one final link.
- Keep `parse`/`regexp`/runtime rules as-is (reused unchanged).

## Milestone ladder (test-driven, vertical slices)

Each milestone is gated by a growing subset of the 844-test corpus; the legacy
oracle localizes any regression.

- **M0 — Scaffolding.** `src/` builds and links one binary against Prism +
  `libspinel_rt.a`. Refactor `spinel_parse.c`'s Prism walk to fill the
  in-memory node table. Stub analyze + a trivial codegen that handles
  `puts <int>` and integer arithmetic, emitting the same prologue/`sp_*` calls
  as legacy. Wire `make legacy` and repoint `test`/`bench`/`optcarrot` at the C
  binary (they go red — expected). **Exit:** `puts 1 + 2` compiles, links, and
  prints `3`.
- **M1 — Core expressions & statements.** Locals, conditionals, loops,
  string/float/bool/nil/symbol literals, method calls on core types, `def`/
  return. Climb the easy slice of `test/`. **Exit:** a few hundred scalar tests
  green.
- **M2 — Type inference parity where it affects output.** Containers (typed
  arrays/hashes), nullable scalars, the fixpoint driver, `poly` dispatch.
  Localize divergences via `--dump-ir` against legacy. **Exit:** container &
  inference tests green.
- **M3 — Classes, modules, blocks, exceptions.** Method tables, `attr_*`,
  inheritance/`include`, blocks/`yield`, `begin/rescue` (setjmp model, matching
  legacy), regexp. **Exit:** the structural slice green.
- **M4 — Full `test` green** (the targets are already pointed here), then
  `bench` (vs CRuby) and `optcarrot` (`--int-overflow=wrap`, `checksum: 59662`).
  Close the long tail of builtins.
- **M5 — Cleanup.** Document the new build in README; decide the fate of the
  legacy Ruby sources / bootstrap path now that the C compiler is primary.

## Open risks

- **Scale.** ~37k lines of analyzer + ~54k of codegen of behavior to
  reproduce. Mitigation: vertical slices, the golden corpus as a ratchet, and
  the legacy oracle for localization. We reproduce *observable behavior*, not
  source structure — large stretches of the Ruby (self-host workarounds,
  defensive poly handling) have no C counterpart.
- **Inference precision drift.** Too narrow → miscompiles; too wide → wrong
  runtime path. Caught by output diffs; localized by IR diffs.
- **Builtin breadth.** The string/array/hash/enumerable method surface is
  large. Drive it demand-first from failing tests rather than enumerating
  upfront.
