/* sp_proc.c -- cold Proc / bound Method / curry / composition helpers,
 * compiled once into libspinel_rt.a instead of re-parsed in every generated
 * translation unit. The hot sp_proc_call stays inline in sp_proc.h.
 *
 * Like the other lib units, this does not include sp_runtime.h (to avoid
 * re-defining its static helpers); it declares the few externals it calls.
 */
#include <stddef.h>
#include "sp_proc.h"

/* Externals provided by the per-program runtime (sp_runtime.h / sp_gc.h),
   resolved at link time against the generated program / libspinel_rt.a. */
extern void *sp_gc_alloc(size_t sz, void (*fin)(void *), void (*scn)(void *));
extern void sp_gc_mark(void *obj);
extern void sp_raise_cls(const char *cls, const char *msg);

void sp_Proc_scan(void *p) {
  sp_Proc *pr = (sp_Proc *)p;
  if (pr->cap && pr->cap_scan) pr->cap_scan(pr->cap);
}

sp_Proc *sp_proc_new_meta(void *fn, void *cap, void (*cap_scan)(void *), mrb_int arity, mrb_bool lambda_p, mrb_int param_count, const sp_sym *param_kinds, const sp_sym *param_names) {
  sp_Proc *p = (sp_Proc *)sp_gc_alloc(sizeof(sp_Proc), NULL, sp_Proc_scan);
  p->fn = fn; p->cap = cap; p->cap_scan = cap_scan; p->arity = arity;
  p->lambda_p = lambda_p; p->param_count = param_count;
  p->param_kinds = param_kinds; p->param_names = param_names;
  return p;
}

sp_Proc *sp_proc_new(void *fn, void *cap, void (*cap_scan)(void *)) {
  return sp_proc_new_meta(fn, cap, cap_scan, 0, FALSE, 0, NULL, NULL);
}

mrb_int sp_proc_arity(sp_Proc *p) { return p ? p->arity : 0; }
mrb_bool sp_proc_lambda_p(sp_Proc *p) { return p ? p->lambda_p : FALSE; }

/* Lambda strict-arity check: raise ArgumentError if argc is outside
   [req, req+opt] (no upper bound with a rest param). Procs are lenient. */
void sp_proc_lambda_arity_check(mrb_int argc, mrb_int req, mrb_int opt, mrb_bool has_rest) {
  if (argc < req || (!has_rest && argc > req + opt)) sp_raise_cls("ArgumentError", "wrong number of arguments");
}

void sp_BoundMethod_scan(void *p) {
  sp_BoundMethod *m = (sp_BoundMethod *)p;
  if (m->self) sp_gc_mark(m->self);
}

sp_BoundMethod *sp_bound_method_new(void *self, mrb_int fn, const char *name) {
  sp_BoundMethod *m = (sp_BoundMethod *)sp_gc_alloc(sizeof(sp_BoundMethod), NULL, sp_BoundMethod_scan);
  m->self = self; m->fn = fn; m->name = name;
  return m;
}

/* Proc#<< / Proc#>> composition: `(f << g).call(x)` == f(g(x)). */
static void sp_proc_compose_scan(void *p) {
  sp_ProcCompose *c = (sp_ProcCompose *)p;
  if (c->outer) sp_gc_mark(c->outer);
  if (c->inner) sp_gc_mark(c->inner);
}
static mrb_int sp_proc_compose_fn(void *cap, mrb_int argc, mrb_int *args) {
  sp_ProcCompose *c = (sp_ProcCompose *)cap;
  mrb_int inner_args[16] = {0};
  if (args && argc > 0) inner_args[0] = args[0];
  mrb_int mid = sp_proc_call(c->inner, 1, inner_args);
  mrb_int outer_args[16] = {0};
  outer_args[0] = mid;
  return sp_proc_call(c->outer, 1, outer_args);
}
sp_Proc *sp_proc_compose(sp_Proc *outer, sp_Proc *inner) {
  sp_ProcCompose *c = (sp_ProcCompose *)sp_gc_alloc(sizeof(sp_ProcCompose), NULL, sp_proc_compose_scan);
  c->outer = outer;
  c->inner = inner;
  return sp_proc_new_meta((void *)sp_proc_compose_fn, c, sp_proc_compose_scan, 1, TRUE, 1, NULL, NULL);
}

/* Proc#curry: an immutable argument accumulator over an sp_Proc target. */
void sp_curry_scan(void *p) {
  sp_Curry *c = (sp_Curry *)p;
  if (c->target) sp_gc_mark(c->target);
}
sp_Curry *sp_curry_new(sp_Proc *p) {
  sp_Curry *c = (sp_Curry *)sp_gc_alloc(sizeof(sp_Curry), NULL, sp_curry_scan);
  c->target = p; c->nargs = 0;
  return c;
}
sp_Curry *sp_curry_apply(sp_Curry *c, mrb_int arg) {
  sp_Curry *n = (sp_Curry *)sp_gc_alloc(sizeof(sp_Curry), NULL, sp_curry_scan);
  *n = *c;
  if (n->nargs < 16) n->args[n->nargs++] = arg;
  return n;
}
mrb_int sp_curry_to_int(sp_Curry *c) {
  if (!c || !c->target) return 0;
  return sp_proc_call(c->target, c->nargs, c->args);
}

/* Hash#to_proc cap-scan: the proc's `cap` IS the source hash (one GC pointer). */
void sp_hashproc_cap_scan(void *p) { sp_gc_mark(p); }
