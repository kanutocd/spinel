# Hash Nullable Semantics

Phase 1 design doc for aligning all typed-hash variants' `[]` lookup
with Ruby semantics (`h[missing_key] == nil`).

## Problem

Of 8 typed-hash variants, 5 violate Ruby semantics by returning a
non-nil sentinel on missing-key lookup:

| Variant | Value type | Missing-key returns | Ruby semantics |
|---|---|---|---|
| `StrIntHash` | `mrb_int` | `0` | nil |
| `SymIntHash` | `mrb_int` | `0` | nil |
| `StrStrHash` | `const char *` | `sp_str_empty` ("") | nil (NULL) |
| `SymStrHash` | `const char *` | `sp_str_empty` ("") | nil (NULL) |
| `IntStrHash` | `const char *` | `sp_str_empty` ("") | nil (NULL) |
| `StrPolyHash` | `sp_RbVal` | `sp_box_nil()` | nil (correct) |
| `SymPolyHash` | `sp_RbVal` | `sp_box_nil()` | nil (correct) |
| `PolyPolyHash` | `sp_RbVal` | `sp_box_nil()` | nil (correct) |

User-visible consequences:

- `if h[:missing]; ... end` — current spinel sees "" / 0 as truthy
  for the string/int variants, contrary to Ruby
- `cached = h[k]; if cached.length > 0` — works around the bug at
  caller-side but pollutes call sites
- The codegen's own `has_key?+[]` fusion bug (uncovered during
  measurement work) was triggered by `StrStrHash_get` returning ""
  on miss instead of NULL

## Sentinel Convention

Reuse spinel's existing dual nullable encoding:

- **Pointer-nullable** (`is_nullable_pointer_type`): `string`,
  `<hash variants>`, `<array variants>`, `<obj_X>`, etc. — `NULL`
  is the nil inhabitant
- **Scalar-nullable** (`is_scalar_nullable_type`): `int?` — uses
  `SP_INT_NIL = INT64_MIN` sentinel via the existing
  `sp_int_is_nil(v)` predicate

Mapping per variant:

| Variant | New `_get` returns on miss | LV slot when `x = h[k]` |
|---|---|---|
| `StrIntHash` | `SP_INT_NIL` | `int?` (mrb_int with sentinel) |
| `SymIntHash` | `SP_INT_NIL` | `int?` |
| `StrStrHash` | `NULL` | `string` (const char *, already nullable) |
| `SymStrHash` | `NULL` | `string` |
| `IntStrHash` | `NULL` | `string` |
| `*PolyHash` | (unchanged) | `poly` (already nullable via box_nil) |

### Sym-valued hashes

spinel currently has no dedicated `*SymHash` variant (no `sym_sym_hash`,
`str_sym_hash`, or `int_sym_hash`). Hash literals with symbol values
(e.g. `{a: :x}`) infer as `sym_poly_hash` / `str_poly_hash` etc. and
box symbols into `sp_RbVal` (SP_TAG_SYM) -- so missing-key already
returns `sp_box_nil()`, Ruby-compatible.

If a future memory-optimization Phase introduces dedicated
`*SymHash` variants (sp_sym = mrb_int storage, 8 bytes/entry vs
sp_RbVal's 16 bytes), the natural nil sentinel is
`((sp_sym)-1)` -- which already serves as `c_default_val("symbol")`
in spinel_codegen.rb. The intern table's index 0 is reserved for
the first symbol, so -1 is unambiguously "no symbol". A
`sym?` scalar-nullable type would follow the same shape as
`int?` (sentinel-based, not pointer-based), gated on
`is_scalar_nullable_type`. Out of scope for the current rollout.

## Call-site Audit

### Internal-safe callers (no change needed)

These iterate `h->order[i]` which holds **existing** keys, so they
never trigger the missing-key path:

- `*Hash_values()` — values list from order
- `*Hash_dup()` — clone via order walk
- `*Hash_merge()` — combine two hashes, key from order
- `*Hash_eq()` — compare; checks `has_key?` first per-key
- `*Hash_update()` — copy values from order
- `*Hash_invert()` — swap k/v, key from order
- `*Hash_inspect()` — render via order
- `*Hash_to_<other_variant>()` — convert via order walk
- `*Hash_from_<other_variant>()` — likewise

### `fetch(k, default)` callers (already correct)

The `Hash#fetch(k, default)` codegen path already wraps with
`has_key?` and supplies the user's `default`:

```c
sp_StrIntHash_has_key(h, k) ? sp_StrIntHash_get(h, k) : <user_default>
```

When user passes `nil`, the codegen emits `SP_INT_NIL` for the int
variants or `NULL` for the str variants (issues #671 / #682 wired
these up). Phase A is orthogonal — `fetch` keeps working.

### `h[k]` direct callers (THE TARGET)

5 sites in `spinel_codegen.rb` emit raw `sp_<Hash>_get(...)`:

| Line | Variant |
|---|---|
| 20579, 20628 | `SymIntHash` |
| 20758, 20794 | `SymStrHash` |
| 21131, 21190 | `StrIntHash` |
| 21302, 21336 | `IntStrHash` |
| 21379, 21436 | `StrStrHash` |

Each currently lowers `h[k]` to:

```c
sp_<Hash>_get(rc, key)   // returns 0 / "" on miss — wrong
```

The Phase A change makes these return the correct sentinel without
needing a wrapper `has_key? ? get : SENTINEL` (because `_get` itself
is the wrapper now).

### iter-with-key callers (no change needed)

These read `h->order[i]` (existing keys) inside `each` / `keys` etc.
walks — they don't hit miss:

- 20650, 21241, 21253, 21292, 21350, 21416 — all `h->order[i]` reads

### `_eq` callers (no change needed)

`*Hash_eq` walks a's keys, checks `has_key?(b, k)` first, then
compares values. The `_get` calls inside `_eq` are guarded — never
miss.

### `_inspect` callers (no change needed)

Inspect walks `h->order[i]` — existing keys only.

## Analyzer `[]` Return Type Table

Located at `spinel_analyze.rb:5304-5328` (the `mname == "[]"` arm).
Current mapping:

| Recv type | `[]` returns |
|---|---|
| `str_int_hash` | `int` |
| `str_str_hash` | `string` |
| `int_str_hash` | `string` |
| `sym_int_hash` | `int` |
| `sym_str_hash` | `string` |
| `sym_poly_hash` | `poly` |
| `str_poly_hash` | `poly` |
| `poly_poly_hash` | `poly` |

Phase A change:

| Recv type | New `[]` returns |
|---|---|
| `str_int_hash` | `int?` |
| `str_str_hash` | `string` (already nullable via NULL) |
| `int_str_hash` | `string` |
| `sym_int_hash` | `int?` |
| `sym_str_hash` | `string` |
| `sym_poly_hash` | `poly` (unchanged) |
| `str_poly_hash` | `poly` (unchanged) |
| `poly_poly_hash` | `poly` (unchanged) |

The `int` → `int?` widening is the main analyzer change. Strings
keep their type label because the storage (`const char *`) is
already nullable; only the runtime miss return changes.

## Downstream Codegen — NULL / SP_INT_NIL Propagation

Once `_get` returns NULL / SP_INT_NIL on miss, every downstream
operation on the result needs nullable-aware handling.

### String operations (mostly already NULL-safe)

- `sp_str_length(NULL)` returns 0 (NULL-safe per lib/sp_runtime.h:475)
- `sp_str_eq(NULL, NULL)` returns 1; `sp_str_eq(NULL, "x")` returns 0
  (NULL-safe per lib/sp_runtime.h:494)
- `sp_str_concat(NULL, "x")` falls back to `sp_str_empty` for NULL
  (NULL-safe coalesce per lib/sp_runtime.h:1129)

These produce silently-not-Ruby-but-safe behavior (Ruby's
`nil.length` raises NoMethodError; spinel returns 0). Phase A keeps
the silent-coalesce behavior — only the **truthy check** changes.

`if h[:missing]; ... end`:
- Before: `if (sp_str_empty)` — non-NULL pointer is truthy in C —
  WRONG (Ruby says nil is falsy)
- After: `if (NULL)` — falsy in C — CORRECT

### Int operations on int?

The codegen already has helpers for int? from prior work
(`compile_expr_int_opt_*`, sp_int_is_nil, etc.). Need to extend the
inference walk to mark `x = h[k]` as widening x's slot to `int?`
when h is a typed int-valued hash.

Truthy check on int? sentinel (already implemented for
sp_str_index_opt etc., spinel_codegen.rb:12290+):

```c
if (sp_int_is_nil(lv_x)) /* falsy */
```

### Arithmetic on SP_INT_NIL

Out of scope for Phase A — same constraint as the existing `int?`
work: arithmetic on SP_INT_NIL silently produces garbage (the
sentinel is a real `int64_t` value, so `SP_INT_NIL + 1` is just
`INT64_MIN + 1` — surprising but not a crash). Documented in
existing int? work (commit f6c3b6d era).

## Phase 2 Scope

Implement only the `*StrHash` variants first:

1. `lib/sp_runtime.h`:
   - `sp_StrStrHash_get`: `return h->default_v ? h->default_v : sp_str_empty;`
     → `return h->default_v ? h->default_v : NULL;`
   - `sp_IntStrHash_get`: same
2. `spinel_codegen.rb` `emit_*_runtime` for `SymStrHash`:
   - `sp_SymStrHash_get`: same NULL change
3. Verify no internal caller depends on `_get` returning non-NULL
   (the `_values`, `_dup`, etc. paths — they read `h->order[i]`
   which are existing keys, so the return is always non-NULL from
   `h->vals[idx]`, not the miss fallback)
4. `make test` + bootstrap + optcarrot regression checks

Phase 3 widens analyze's `[]` return type for string-valued hashes
(no real change since `string` is already nullable at the C level —
mostly tightens up call-site emit where it assumed non-NULL).

## Phase 4 Scope — DEFERRED (2026-05-25)

Implementing `*IntHash` → SP_INT_NIL is significantly more invasive
than initially scoped. First attempt (16:00-16:40 JST) hit three
cascading issues, all reverted before commit:

### Cascade 1: Self-host bootstrap breaks via inferred-LV typing

Changing `analyze`'s `[]` return for `str_int_hash` from `"int"` to
`"int?"` propagates "int?" through spinel_analyze.rb's OWN type
inference. Specifically `unify_return_type` and `unify_call_types`
treat `"int?"` as a distinct type from `"int"`, widening many
internal calls (like `not_in(name, arr)`) to poly. Mitigations
attempted:

- `unify_hash_value_types`: treat `int?` as `int` (added)
- `unify_return_type`: treat `int?` as `int` for fallback (added)

These alone aren't enough — `unify_call_types`'s
`base_type(old_pt) == base_type(at)` check at line 11568 still
diverges for `("string", "int?")` pairs, which then fall through
to the trailing "incompatible → poly" branch. The bootstrap fails
with `lv_kt = sp_box_nil()` typing (poly) on locals that should
be `const char *` (the result of `infer_type(...)`).

### Cascade 2: `&&=` / `||=` codegen treats `SP_INT_NIL` as truthy

The compound-assignment codegen lowers `counts[k] &&= v` to:

```c
if (sp_StrIntHash_get(counts, k)) {
  sp_StrIntHash_set(counts, k, v);
}
```

The `if (...)` is C-truthy on the raw mrb_int. After Phase 4,
missing-key returns `SP_INT_NIL = INT64_MIN`, which is **non-zero**
and therefore C-truthy. Ruby says nil is falsy. The fix requires
the codegen to emit `if (!sp_int_is_nil(...))` for typed-int-hash
sources — a parallel arm in `compile_index_and_assign` /
`compile_index_or_assign`.

### Cascade 3: Existing test assumptions

`test/sym_int_hash_merge.rb` line 10 expects `puts h3[:q]` after
`h3.delete(:q)` to output `0`. Updating to empty line (Ruby's
`puts nil`) requires the int? puts arm AND propagation through
the analyze type so the call site dispatches to it. Without all
cascades fixed, the test produces the raw `-9223372036854775808`
output.

### Re-planned Phase 4 (alternative: poly wrapper)

The cleaner approach, mirroring `Array#index` (commit e46ec54):

1. Add `sp_StrIntHash_get_poly(h, k)` runtime helper that returns
   `sp_RbVal` (sp_box_nil() for missing, sp_box_int(v) for present).
2. Same for `sp_SymIntHash_get_poly`.
3. Codegen `h[k]` direct dispatch for `str_int_hash` / `sym_int_hash`
   routes to `_get_poly` (returns sp_RbVal).
4. Analyze `[]` returns `"poly"` for these variants.
5. Compound writes (`&&=`/`||=`) read via `_get_poly`, write via
   `_set` after unboxing.

The poly route reuses existing infrastructure (sp_poly_truthy,
sp_poly_inspect, etc.) and avoids the int? cascade. Cost: boxing
on every `[]` lookup. For frameworks heavy in typed-int hash use,
profile before committing.

### Status

Phase 4 deferred until either:
- A focused session implements the poly-wrapper route end-to-end, or
- The int? cascade is fixed at all sites (3+ places in
  spinel_analyze.rb plus the compound-assignment codegen)

Until then, `*IntHash[missing]` returns the value-type zero (`0`)
— a known Ruby semantic violation, but stable.

## Phase 5 Scope

- Add regression tests:
  - `test/str_str_hash_missing_returns_nil.rb` — `if h["missing"]; ...; end` falsy path
  - `test/str_int_hash_missing_returns_nil.rb` — `if h["missing"]; ...; end` falsy
  - `test/sym_int_hash_missing_arithmetic.rb` — document SP_INT_NIL arith caveat
- `make test` (all pass)
- `make bootstrap` (gen2 == gen3)
- `make optcarrot` (checksum 59662)

## Risks

1. **Bootstrap self-host**: spinel_analyze.rb + spinel_codegen.rb
   use typed hashes extensively. Per-phase bootstrap convergence
   required.
2. **optcarrot regression**: prior body-driven-widening cascade
   (memory: body_usage_widening_optcarrot) warns that even
   post-fixpoint widening can cascade-break optcarrot. Phase 4's
   `int?` widening is the highest-risk step.
3. **Test-suite assumptions**: any existing test that asserts
   `h[missing] == ""` or `h[missing] == 0` semantics needs update.
   Survey via `grep -rE 'Hash.*\[".*"\].*== "?"' test/`.

## Order of Operations

```
Phase 1 — survey + this doc                    [current]
Phase 2 — *StrHash → NULL                      next
Phase 3 — *StrHash codegen tightening          
Phase 4 — *IntHash → SP_INT_NIL                bigger surgery
Phase 5 — regression tests + final verify      
```

Each phase ends with a green CI before the next begins. If Phase 4
regresses optcarrot, fall back to Phase 4a (per-variant rollout
with feature flag).
