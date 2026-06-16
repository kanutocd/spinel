# RFC: A Minimal Ractor for Spinel

Status: **experimental / Milestone 1**. This document is both the design
rationale and the record of what currently ships. It proposes whether to
graduate to a full implementation (see *Path forward*).

## Why this is cheap here

Spinel's runtime (`lib/sp_runtime.h`) keeps essentially all mutable state in
file-scope `static` globals: the GC heap, the string heap, the dynamic symbol
table, the exception/`throw` `longjmp` stacks, the regex captures, the fiber
pointer, the lambda arena, the at-exit hooks, and the per-class object pools.
Generated code emits `$globals` and `@@cvars` as statics too. That is exactly
why Spinel is single-threaded.

Ractor's whole premise is **isolation + message passing**. Spinel's
"all state is a static global" shape maps onto that almost for free:

> Promote the per-execution-unit mutable globals to thread-local (`__thread`),
> run each Ractor as a pthread, and each Ractor gets its own private GC heap /
> string heap / symbol table / exception stack. Because each heap is private,
> **no global GC lock is needed** — Ractors collect independently. The
> compile-time-`const` class/dispatch tables stay shared and read-only.

A Ractor is, structurally, "a Fiber body run on a pthread, with mailbox/yield
queues instead of resume/yield slots, deep-copied at the boundary."

## The state partition

```
lib/sp_runtime.h globals, reclassified:

(a) __thread  — per-Ractor mutable, NO lock
    GC core (heap/bytes/threshold/old_heap/cycle/buckets), the GC root window
    (a lazily-malloc'd __thread pointer so it doesn't commit 512 KiB of TLS),
    the mark stack, the string heap + lcache, the exception/catch longjmp
    stacks, the regex captures ($~), the fiber root/current/list (both #ifdef
    branches), the lambda arena, the at_exit hooks, and the per-class pools.

(b) shared const, read-only — NO lock
    sp_class_names[] and all dispatch/vtable tables; the static portion of
    sp_sym_names[]; rodata string literals; install-once function-pointer
    hooks (sp_obj_hash_hook); sp_gc_verify.

(c) process-global WITH a lock — genuinely shared (all NEW infra)
    each Ractor's mailbox + outgoing queue (a mutex + condvar each) and the
    reference-counted control block. NOT the GC (private heaps), NOT malloc
    (glibc is already thread-safe).
```

`sp_thread_init()` wires each thread's `sp_fiber_current` to its own synthetic
root fiber (the address of a `__thread` var is not a constant expression, so it
can't be a static initializer). It runs on the main thread via an ELF
constructor and on each Ractor thread from its trampoline. The root array and
mark stack self-allocate lazily on first use.

## Architecture & data flow

```
Ractor.new { ... }  ──pthread_create──►  trampoline:
                                           sp_thread_init()  (fresh TLS heap + fiber root)
                                           set top-level setjmp landing pad
                                           run the block body (_ractor_body_N)
                                           close outbox; release ctrl refcount

parent: r.send(v) / r << v  ── serialize ─►  inbox  (mutex+condvar) ─► Ractor.receive
child:  Ractor.yield(v)     ── serialize ─►  outbox (mutex+condvar) ─► r.take : parent
```

**Boundary = serialize to a heap-neutral buffer.** A sent value is a pointer
into the sender's private heap; the sender's next GC would free it. Copying
directly into the receiver's heap is unavailable, because `sp_gc_alloc` writes
the *running* thread's thread-local GC slots — allocating into another heap
would need a per-heap lock on every send, reintroducing the global GC lock this
design eliminates. So the sender serializes into a malloc'd, pointer-free
buffer; the receiver rebuilds via ordinary `sp_gc_alloc` into its own heap; the
buffer is freed after. This matches CRuby's default deep-copy `send`.

## Public API (conforms to current CRuby Ractor)

```ruby
r = Ractor.new do
  x = Ractor.receive      # pop from this Ractor's inbox (also: Ractor.recv)
  Ractor.yield(x * 2)     # push to this Ractor's outbox
end
r.send(21)                # push to r's inbox (also: r << 21)
puts r.take               # => 42  (pop from r's outbox)
```

Default deep-copy semantics; capturing an unshareable outer variable is a
compile-time `Ractor::IsolationError`.

## Implementation map

- **`lib/sp_runtime.h`** — `__thread` on the bucket-(a) globals (both fiber
  `#ifdef` branches); the lazy `__thread` root pointer; `sp_thread_init()` + a
  main-thread constructor; `__thread` on the `SP_POOL_DEFINE` macro body; and
  the new `sp_Ractor` / `sp_RactorCtrl` (reference-counted, malloc'd control
  block with mutex+condvar mailbox/outgoing queues), the scalar `sp_deep_copy`
  codec (`sp_ractor_serialize`/`_deserialize`/`_shareable`), the
  `sp_ractor_new/_send/_receive/_yield/_take` helpers, and the per-thread
  top-level `setjmp` landing pad that re-raises an uncaught Ractor exception in
  the taker.
- **`spinel_analyze.rb`** — a `"ractor"` base type (added to
  `type_is_pointer` / `is_nullable_pointer_type`); `Ractor.new → "ractor"` in
  `infer_constructor_type`; and early inference arms for
  `receive`/`recv`/`take`/`send`/`<<`/`yield` (placed before the generic
  receiver-method dispatch so `take`/`send` aren't shadowed by `Array#take` /
  the reflective `Object#send`).
- **`spinel_codegen.rb`** — `c_type "ractor" → "sp_Ractor *"` and the matching
  pointer-type lists; `compile_ractor_new` + `_ractor_body_N` (a clone of the
  Fiber body-emission shape); the dispatch arms (with the `send` arm placed
  before the reflective `Object#send`, gated on the ractor receiver type); and
  mirrored cache-miss inference arms.
- **`Makefile`** — `-pthread` in `CFLAGS`.

## Deliberate divergences (where "minimal" buys simplicity)

1. **Value codec carries scalars only** — Integer / Float / true / false / nil.
   Strings, Symbols, and containers (Array/Hash/objects) raise `Ractor::Error`
   at the boundary. Extending the codec is the main follow-up.
2. **Single-slot mailbox with backpressure**, not CRuby's unbounded mailbox.
   `send`/`yield` block while a value is still pending.
3. **`@@cvars` / `$globals` stay `static` (shared)**, not yet `__thread`. CRuby
   isolates them per-Ractor and raises on cross-Ractor mutation; we have not
   thread-local-ized them because class-body cvar initializers would need a
   trampoline replay. Programs that touch cvars/gvars across Ractors are out of
   scope for this milestone.
4. **No spawn args / block params** and **no shareable-by-value capture** yet:
   any captured outer variable or `self` is a compile-time
   `Ractor::IsolationError`. The block's return value is not delivered to
   `take` (only explicit `Ractor.yield` is).

## Verification

- The `__thread` storage-class conversion is behavior-neutral: the full
  existing test suite (831 `.rb` tests) passes unchanged, single-threaded.
- `test/ractor_basic.rb` exercises `Ractor.new` / `receive` / `yield` /
  `send` / `<<` / `take` end-to-end and prints `42` twice.
- The isolation rule rejects a block that captures a mutable outer local with
  `Ractor::IsolationError`.

## Path forward (if this graduates)

In rough dependency order: extend `sp_deep_copy` to strings → arrays → hashes →
objects (symbols travel by name, re-interned on receive); make the mailbox
unbounded; thread-local-ize `@@cvars`/`$globals` with a class-body initializer
replay on the child; add spawn args and shareable-by-value capture; and a
`Ractor::Port`-style multi-consumer surface. None of these change the core
partition above — they extend it.
