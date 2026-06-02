# Fast Bootstrap

Spinel is self-hosting: the compiler backend (`spinel_analyze.rb` and
`spinel_codegen.rb`) is itself compiled to native binaries. The reliable way to
build those binaries from scratch is the CRuby round: run the two `.rb` sources
under `miniruby` to emit C, then compile. That round is the trustworthy
authority, but on a machine that already has working compiler binaries it is
slow, because CRuby re-interprets the whole backend every time the sources
change.

Fast bootstrap rebuilds the compiler from the *previous* compiled binaries
("stage0") instead of from CRuby. On this codebase a stage0 round is about 3.5x
faster than the CRuby round (the type-inference pass dominates either way, but
the compiled inferencer is far faster than the interpreted one).

## Modes

`make` reads one variable:

- `FAST_BOOTSTRAP=auto` (default): `make all` rebuilds the compiler from stage0
  via `tools/fast-bootstrap`. If stage0 is missing or cannot compile the current
  source, the helper falls back to the CRuby round automatically.
- `FAST_BOOTSTRAP=0`: always use the CRuby authority round. `make bootstrap`
  forces this regardless of the default.

## Targets

- `make all` / `make spinel_analyze spinel_codegen`: fast path by default,
  gated on the compiler-source content stamps. Unchanged source rebuilds
  nothing.
- `make fast-bootstrap`: run the stage0 path explicitly.
- `make bootstrap`: the authority. Forces `FAST_BOOTSTRAP=0`, runs the
  CRuby-seeded self-host fixpoint (round2 built by round1, round3 built by
  round2), and requires round2 == round3 byte-for-byte for both sources before
  promoting. Use this for releases, for CI, and whenever a byte-canonical
  compiler is wanted.

## What the helper does

`tools/fast-bootstrap` is a small POSIX shell script (no CRuby in the policy
layer, to keep the fast path self-hosting). On each run:

1. **Eligibility.** Require executable `spinel_analyze`, `spinel_codegen`,
   `spinel_parse` and the runtime library `lib/libspinel_rt.a`. If any is
   missing, fall back to the CRuby Make rules.
2. **Generate.** Parse both compiler sources with the current parser and run
   stage0 to emit IR and C, all isolated under `build/fast-bootstrap/`.
3. **Compile** the stage1 binaries there, leaving the top-level binaries
   untouched.
4. **Smoke check.** The fresh stage1 must analyze and code-generate the large
   `codegen` AST and emit non-empty C. This catches a stage1 that links but
   crashes or emits junk.
5. **Promote.** Only on full success: publish the intermediates into the
   canonical `build/` (so Make's dependency graph stays consistent) and
   atomically `mv` the stage1 binaries over the top-level ones.

Any failure at any step leaves the previous working binaries in place and
delegates to the CRuby authority path, so a failed fast bootstrap never destroys
the last good compiler.

## Correctness model

The fast path does **not** run a self-host fixpoint; that is `make bootstrap`.
stage0 is the immediately-previous self-hosted compiler, and for ordinary edits
it compiles the current source correctly. The residual risk, stage0 silently
miscompiling the new source without erroring, is covered by `make test`,
`make bootstrap`, and CI, which always exercise the authority path.

Because the fixpoint is skipped, a fast-bootstrapped binary is functionally
correct for the current source but not byte-canonical: its own machine code
carries the compilation style of whatever stage0 produced it. This does not
compound into incorrectness, since every stage0 is itself a correct compiler.
To obtain a reproducible, byte-canonical compiler, run `make bootstrap`, which
re-converges through the round2/round3 fixpoint.
