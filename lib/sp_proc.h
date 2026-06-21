/* sp_proc.h -- Proc / bound Method / Proc#curry / Proc composition.
 *
 * The struct definitions and the hot sp_proc_call are shared between
 * sp_runtime.h (the per-program translation unit) and sp_proc.c (compiled
 * once into libspinel_rt.a). sp_proc_call stays `static inline` so every
 * block invocation in generated code keeps inlining it; the cold lifecycle
 * helpers (new / scan / compose / curry / bound-method) live in sp_proc.c
 * so they are not re-parsed in every generated TU.
 *
 * sp_proc_parameters is NOT here: it builds an sp_PolyArray via the hot
 * static-inline array/box helpers, so it stays in sp_runtime.h.
 */
#ifndef SP_PROC_H
#define SP_PROC_H

#include "sp_types.h"   /* mrb_int, mrb_bool, sp_sym */

typedef struct sp_Proc {
  void *fn;
  void *cap;
  void (*cap_scan)(void *);
  mrb_int arity;
  mrb_bool lambda_p;
  mrb_int param_count;
  const sp_sym *param_kinds;
  const sp_sym *param_names;
} sp_Proc;

/* `obj.method(:foo)` / `method(:foo)`. `self` is the bound receiver (NULL for
   a top-level method), `fn` the function address (cast to the right signature
   at the call site), `name` the method name. Only `self` is GC-managed. */
typedef struct sp_BoundMethod { void *self; mrb_int fn; const char *name; } sp_BoundMethod;

typedef struct { sp_Proc *outer; sp_Proc *inner; } sp_ProcCompose;
typedef struct { sp_Proc *target; mrb_int nargs; mrb_int args[16]; } sp_Curry;

/* Hot: inlined into every block call. */
static inline mrb_int sp_proc_call(sp_Proc *p, mrb_int argc, mrb_int *args) {
  if (!p || !p->fn) return 0;
  if (!args) {
    mrb_int noargs[16] = {0};
    return ((mrb_int (*)(void *, mrb_int, mrb_int *))p->fn)(p->cap, 0, noargs);
  }
  return ((mrb_int (*)(void *, mrb_int, mrb_int *))p->fn)(p->cap, argc, args);
}

/* Cold lifecycle helpers (defined in sp_proc.c). */
void sp_Proc_scan(void *p);
sp_Proc *sp_proc_new_meta(void *fn, void *cap, void (*cap_scan)(void *), mrb_int arity, mrb_bool lambda_p, mrb_int param_count, const sp_sym *param_kinds, const sp_sym *param_names);
sp_Proc *sp_proc_new(void *fn, void *cap, void (*cap_scan)(void *));
mrb_int sp_proc_arity(sp_Proc *p);
mrb_bool sp_proc_lambda_p(sp_Proc *p);
void sp_proc_lambda_arity_check(mrb_int argc, mrb_int req, mrb_int opt, mrb_bool has_rest);
sp_Proc *sp_proc_compose(sp_Proc *outer, sp_Proc *inner);

void sp_BoundMethod_scan(void *p);
sp_BoundMethod *sp_bound_method_new(void *self, mrb_int fn, const char *name);

void sp_curry_scan(void *p);
sp_Curry *sp_curry_new(sp_Proc *p);
sp_Curry *sp_curry_apply(sp_Curry *c, mrb_int arg);
mrb_int sp_curry_to_int(sp_Curry *c);

void sp_hashproc_cap_scan(void *p);

#endif /* SP_PROC_H */
