/* sp_types.h -- core value-type definitions split out of sp_runtime.h.
 *
 * Holds the primitive typedefs, the small leaf value structs, the GC
 * header, and the typed array / non-poly hash structs. Both
 * sp_runtime.h (which includes this near the top) and libspinel_rt.a
 * sources can include it to see the layouts without pulling in the
 * header's static/inline function bodies. Pure type/macro definitions
 * only -- no function definitions, no global state.
 *
 * Reorganisation step toward slimming sp_runtime.h; sp_RbVal, the poly
 * containers, and the conditional Proc/Fiber/etc. types still live in
 * sp_runtime.h pending a later pass.
 */
#ifndef SP_TYPES_H
#define SP_TYPES_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

typedef int64_t mrb_int;
typedef double mrb_float;
typedef bool mrb_bool;

/* Sentinel value reserved by the int? (scalar-nullable int) type. An
   int? slot is bit-compatible with mrb_int; SP_INT_NIL marks the
   "nil" inhabitant. The chosen pattern is INT64_MIN, which Ruby's
   Integer would auto-promote to Bignum (#597 limitation), so the
   reservation lines up with spinel's existing fast-path-only spec.
   `sp_int_is_nil(v)` is the canonical predicate; treat any int? value
   produced by runtime helpers as opaque outside this macro. */
#define SP_INT_NIL ((mrb_int)INT64_MIN)
#define sp_int_is_nil(v) ((v) == SP_INT_NIL)

/* sp_sym is defined per-program in emit_sym_runtime, but poly helpers
   below need to reference it by forward declaration. */
typedef mrb_int sp_sym;

#ifndef TRUE
#define TRUE true
#endif
#ifndef FALSE
#define FALSE false
#endif

/* ---- Leaf value structs ---- */
typedef struct{mrb_int first;mrb_int last;}sp_Range;
typedef struct{mrb_int cls_id;}sp_Class;
typedef struct{mrb_float re;mrb_float im;}sp_Complex;
typedef struct{mrb_int num;mrb_int den;}sp_Rational;
typedef struct{const char *name;}sp_Encoding;

/* ---- GC headers ---- */
typedef struct sp_gc_hdr { struct sp_gc_hdr *next; void (*finalize)(void *); void (*scan)(void *); size_t size; unsigned marked : 1; unsigned frozen : 1; void (*recycle)(struct sp_gc_hdr *); } sp_gc_hdr;
typedef struct sp_str_hdr { struct sp_str_hdr *next; size_t size; size_t len; } sp_str_hdr;

/* ---- Typed arrays ---- */
#define SP_STRARR_INLINE 4
typedef struct{mrb_int*data;mrb_int start;mrb_int len;mrb_int cap;mrb_int frozen;}sp_IntArray;
typedef struct{mrb_float*data;mrb_int len;mrb_int cap;mrb_int frozen;}sp_FloatArray;
typedef struct{void**data;mrb_int len;mrb_int cap;void(*scan_elem)(void*);mrb_int frozen;}sp_PtrArray;
typedef struct{const char**data;mrb_int len;mrb_int cap;mrb_int frozen;const char*inline_data[SP_STRARR_INLINE];}sp_StrArray;

/* ---- Non-poly typed hashes ---- */
typedef struct{const char**keys;mrb_int*vals;const char**order;mrb_int len;mrb_int cap;mrb_int mask;mrb_int default_v;}sp_StrIntHash;
typedef struct{const char**keys;const char**vals;const char**order;mrb_int len;mrb_int cap;mrb_int mask;const char*default_v;}sp_StrStrHash;
typedef struct{mrb_int*keys;const char**vals;mrb_int*order;mrb_bool*used;mrb_int len;mrb_int cap;mrb_int mask;const char*default_v;}sp_IntStrHash;
typedef struct{mrb_int*keys;mrb_int*vals;mrb_int*order;mrb_bool*used;mrb_int len;mrb_int cap;mrb_int mask;mrb_int default_v;}sp_IntIntHash;

#endif
