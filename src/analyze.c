#include "analyze.h"

#include <stdlib.h>
#include <string.h>

/* ---- operator classification ---- */

static int str_in(const char *s, const char *const *set) {
  if (!s) return 0;
  for (int i = 0; set[i]; i++) if (strcmp(s, set[i]) == 0) return 1;
  return 0;
}
static int is_arith_op(const char *op) {
  static const char *const set[] = {"+", "-", "*", "/", "%", "**", NULL};
  return str_in(op, set);
}
static int is_cmp_op(const char *op) {
  static const char *const set[] = {"<", ">", "<=", ">=", NULL};
  return str_in(op, set);
}
static int is_eq_op(const char *op) {
  static const char *const set[] = {"==", "!=", NULL};
  return str_in(op, set);
}
static int is_void_call(const char *name) {
  static const char *const set[] = {
    "puts", "print", "p", "pp", "require", "require_relative",
    "raise", "warn", "printf", NULL};
  return str_in(name, set);
}

/* ---- call inference ---- */

static TyKind infer_call(Compiler *c, int id) {
  const NodeTable *nt = c->nt;
  const char *name = nt_str(nt, id, "name");
  int recv = nt_ref(nt, id, "receiver");
  int args = nt_ref(nt, id, "arguments");
  int argc = 0;
  const int *argv = NULL;
  if (args >= 0) argv = nt_arr(nt, args, "arguments", &argc);
  if (!name) return TY_UNKNOWN;

  TyKind rt = recv >= 0 ? infer_type(c, recv) : TY_UNKNOWN;
  TyKind a0 = argc >= 1 ? infer_type(c, argv[0]) : TY_UNKNOWN;

  /* user-defined method call (no receiver) */
  if (recv < 0) {
    int mi = comp_method_index(c, name);
    if (mi >= 0) return c->scopes[mi].ret;
  }

  /* array receiver methods */
  if (recv >= 0 && ty_is_array(rt)) {
    if (!strcmp(name, "[]"))                          return ty_array_elem(rt);
    if (!strcmp(name, "length") || !strcmp(name, "size") ||
        !strcmp(name, "count") || !strcmp(name, "index")) return TY_INT;
    if (!strcmp(name, "sum"))                         return ty_array_elem(rt);
    if (!strcmp(name, "first") || !strcmp(name, "last") ||
        !strcmp(name, "min") || !strcmp(name, "max")) return ty_array_elem(rt);
    if (!strcmp(name, "join"))                        return TY_STRING;
    if (!strcmp(name, "inspect") || !strcmp(name, "to_s")) return TY_STRING;
    if (!strcmp(name, "empty?") || !strcmp(name, "include?")) return TY_BOOL;
    if (!strcmp(name, "push") || !strcmp(name, "<<") ||
        !strcmp(name, "reverse") || !strcmp(name, "sort") ||
        !strcmp(name, "uniq") || !strcmp(name, "to_a"))   return rt;
    if (!strcmp(name, "[]="))                         return ty_array_elem(rt);
  }

  /* string receiver methods */
  if (recv >= 0 && rt == TY_STRING) {
    if (!strcmp(name, "upcase") || !strcmp(name, "downcase") ||
        !strcmp(name, "capitalize") || !strcmp(name, "reverse") ||
        !strcmp(name, "strip") || !strcmp(name, "lstrip") ||
        !strcmp(name, "rstrip") || !strcmp(name, "chomp") ||
        !strcmp(name, "chop") || !strcmp(name, "chr")) return TY_STRING;
    if (!strcmp(name, "[]"))    return TY_STRING;
    if (!strcmp(name, "index")) return TY_INT;
    if (!strcmp(name, "split")) return TY_STR_ARRAY;
  }
  /* integer receiver methods */
  if (recv >= 0 && rt == TY_INT) {
    if (!strcmp(name, "chr")) return TY_STRING;
  }
  /* float receiver methods */
  if (recv >= 0 && rt == TY_FLOAT) {
    if (!strcmp(name, "floor") || !strcmp(name, "ceil") ||
        !strcmp(name, "round")) return TY_INT;
  }

  if ((!strcmp(name, "-@") || !strcmp(name, "+@")) && recv >= 0 && argc == 0)
    return ty_is_numeric(rt) ? rt : TY_UNKNOWN;
  if (!strcmp(name, "!")) return TY_BOOL;

  if (recv >= 0 && argc == 1 && is_arith_op(name)) {
    if (rt == TY_STRING) {
      if (!strcmp(name, "+") || !strcmp(name, "*")) return TY_STRING;
      return TY_UNKNOWN;
    }
    if (ty_is_numeric(rt) && ty_is_numeric(a0))
      return (rt == TY_FLOAT || a0 == TY_FLOAT) ? TY_FLOAT : TY_INT;
    return TY_UNKNOWN;
  }
  if (recv >= 0 && argc == 1 && is_cmp_op(name)) {
    if (!strcmp(name, "<=>")) return TY_INT;
    return TY_BOOL;
  }
  if (argc == 1 && is_eq_op(name)) return TY_BOOL;

  size_t nl = strlen(name);
  if (nl > 0 && name[nl - 1] == '?') return TY_BOOL;

  if (!strcmp(name, "to_s") || !strcmp(name, "inspect") ||
      !strcmp(name, "chr") || !strcmp(name, "to_str")) return TY_STRING;
  if (!strcmp(name, "to_i") || !strcmp(name, "to_int") ||
      !strcmp(name, "length") || !strcmp(name, "size") ||
      !strcmp(name, "ord") || !strcmp(name, "abs")) return TY_INT;
  if (!strcmp(name, "to_f")) return TY_FLOAT;
  if (!strcmp(name, "to_sym")) return TY_SYMBOL;

  if (is_void_call(name) && recv < 0) return TY_VOID;

  return TY_UNKNOWN;
}

/* ---- core inference ---- */

static TyKind infer_uncached(Compiler *c, int id) {
  const NodeTable *nt = c->nt;
  const char *ty = nt_type(nt, id);
  if (!ty) return TY_UNKNOWN;

  if (!strcmp(ty, "IntegerNode"))             return TY_INT;
  if (!strcmp(ty, "FloatNode"))               return TY_FLOAT;
  if (!strcmp(ty, "StringNode"))              return TY_STRING;
  if (!strcmp(ty, "InterpolatedStringNode"))  return TY_STRING;
  if (!strcmp(ty, "SymbolNode"))              return TY_SYMBOL;
  if (!strcmp(ty, "TrueNode"))                return TY_BOOL;
  if (!strcmp(ty, "FalseNode"))               return TY_BOOL;
  if (!strcmp(ty, "NilNode"))                 return TY_NIL;
  if (!strcmp(ty, "RangeNode"))               return TY_RANGE;

  if (!strcmp(ty, "LocalVariableReadNode")) {
    const char *nm = nt_str(nt, id, "name");
    Scope *s = comp_scope_of(c, id);
    LocalVar *lv = nm ? scope_local(s, nm) : NULL;
    return lv ? lv->type : TY_UNKNOWN;
  }
  if (!strcmp(ty, "ParenthesesNode")) {
    int body = nt_ref(nt, id, "body");
    if (body < 0) return TY_NIL;
    int n = 0;
    const int *b = nt_arr(nt, body, "body", &n);
    return n > 0 ? infer_type(c, b[n - 1]) : TY_NIL;
  }
  if (!strcmp(ty, "StatementsNode")) {
    int n = 0;
    const int *b = nt_arr(nt, id, "body", &n);
    return n > 0 ? infer_type(c, b[n - 1]) : TY_NIL;
  }
  if (!strcmp(ty, "IfNode") || !strcmp(ty, "UnlessNode")) {
    int then_b = nt_ref(nt, id, "statements");
    int else_b = nt_ref(nt, id, "subsequent");
    TyKind tt = then_b >= 0 ? infer_type(c, then_b) : TY_NIL;
    TyKind et = else_b >= 0 ? infer_type(c, else_b) : TY_NIL;
    return ty_unify(tt, et);
  }
  if (!strcmp(ty, "ElseNode")) {
    int s = nt_ref(nt, id, "statements");
    return s >= 0 ? infer_type(c, s) : TY_NIL;
  }
  if (!strcmp(ty, "ArrayNode")) {
    int n = 0;
    const int *els = nt_arr(nt, id, "elements", &n);
    if (n == 0) return TY_POLY_ARRAY;
    TyKind e = TY_UNKNOWN;
    for (int k = 0; k < n; k++) e = ty_unify(e, infer_type(c, els[k]));
    return ty_array_of(e);
  }
  if (!strcmp(ty, "CallNode")) return infer_call(c, id);

  return TY_UNKNOWN;
}

TyKind infer_type(Compiler *c, int id) {
  if (id < 0 || id >= c->nt->count) return TY_UNKNOWN;
  TyKind t = infer_uncached(c, id);
  c->ntype[id] = t;
  return t;
}

/* ---- scope assignment ---- */

static void scope_add_param(Scope *s, const char *name) {
  if (s->nparams % 8 == 0)
    s->pnames = realloc(s->pnames, sizeof(char *) * (size_t)(s->nparams + 8));
  s->pnames[s->nparams++] = strdup(name);
  LocalVar *lv = scope_local_intern(s, name);
  lv->is_param = 1;
}

static void walk_scope(Compiler *c, int id, int scope_idx) {
  if (id < 0 || id >= c->nt->count) return;
  c->nscope[id] = scope_idx;
  const char *ty = nt_type(c->nt, id);
  int child = scope_idx;

  if (ty && !strcmp(ty, "DefNode")) {
    const char *name = nt_str(c->nt, id, "name");
    Scope *s = comp_scope_new(c, name, id);
    int new_idx = c->nscopes - 1;
    s->body = nt_ref(c->nt, id, "body");
    int pn = nt_ref(c->nt, id, "parameters");
    if (pn >= 0) {
      int rn = 0;
      const int *reqs = nt_arr(c->nt, pn, "requireds", &rn);
      for (int i = 0; i < rn; i++) {
        const char *pname = nt_str(c->nt, reqs[i], "name");
        if (pname) scope_add_param(s, pname);
      }
    }
    child = new_idx;
  }

  int nr = nt_num_refs(c->nt, id);
  for (int i = 0; i < nr; i++) {
    int r = nt_ref_at(c->nt, id, i);
    if (r >= 0) walk_scope(c, r, child);
  }
  int na = nt_num_arrs(c->nt, id);
  for (int i = 0; i < na; i++) {
    int n = 0;
    const int *ids = nt_arr_at(c->nt, id, i, &n);
    for (int j = 0; j < n; j++)
      if (ids[j] >= 0) walk_scope(c, ids[j], child);
  }
}

static void register_locals(Compiler *c) {
  const NodeTable *nt = c->nt;
  for (int id = 0; id < nt->count; id++) {
    const char *ty = nt_type(nt, id);
    if (!ty) continue;
    if (!strcmp(ty, "LocalVariableWriteNode") ||
        !strcmp(ty, "LocalVariableTargetNode") ||
        !strcmp(ty, "LocalVariableReadNode") ||
        !strcmp(ty, "LocalVariableOperatorWriteNode")) {
      const char *nm = nt_str(nt, id, "name");
      if (nm) scope_local_intern(comp_scope_of(c, id), nm);
    }
  }
}

/* ---- fixpoint passes ---- */

static int infer_write_types(Compiler *c) {
  const NodeTable *nt = c->nt;
  int changed = 0;
  for (int id = 0; id < nt->count; id++) {
    const char *ty = nt_type(nt, id);
    if (!ty) continue;
    const char *nm = NULL;
    TyKind newt = TY_UNKNOWN;
    if (!strcmp(ty, "LocalVariableWriteNode")) {
      nm = nt_str(nt, id, "name");
      newt = infer_type(c, nt_ref(nt, id, "value"));
    } else if (!strcmp(ty, "LocalVariableOperatorWriteNode")) {
      nm = nt_str(nt, id, "name");
      Scope *s = comp_scope_of(c, id);
      LocalVar *cur = nm ? scope_local(s, nm) : NULL;
      TyKind vt = infer_type(c, nt_ref(nt, id, "value"));
      TyKind ct = cur ? cur->type : TY_UNKNOWN;
      if (ct == TY_STRING) newt = TY_STRING;
      else if (ty_is_numeric(ct) && ty_is_numeric(vt))
        newt = (ct == TY_FLOAT || vt == TY_FLOAT) ? TY_FLOAT : TY_INT;
      else newt = ct;
    } else {
      continue;
    }
    if (!nm) continue;
    LocalVar *lv = scope_local(comp_scope_of(c, id), nm);
    if (!lv) continue;
    TyKind merged = ty_unify(lv->type, newt);
    if (merged != lv->type) { lv->type = merged; changed = 1; }
  }
  return changed;
}

static int infer_param_types(Compiler *c) {
  const NodeTable *nt = c->nt;
  int changed = 0;
  for (int id = 0; id < nt->count; id++) {
    const char *ty = nt_type(nt, id);
    if (!ty || strcmp(ty, "CallNode")) continue;
    if (nt_ref(nt, id, "receiver") >= 0) continue;
    const char *name = nt_str(nt, id, "name");
    int mi = comp_method_index(c, name);
    if (mi < 0) continue;
    Scope *m = &c->scopes[mi];
    int args = nt_ref(nt, id, "arguments");
    int argc = 0;
    const int *argv = NULL;
    if (args >= 0) argv = nt_arr(nt, args, "arguments", &argc);
    int n = argc < m->nparams ? argc : m->nparams;
    for (int k = 0; k < n; k++) {
      TyKind at = infer_type(c, argv[k]);
      LocalVar *p = scope_local(m, m->pnames[k]);
      if (!p) continue;
      TyKind merged = ty_unify(p->type, at);
      if (merged != p->type) { p->type = merged; changed = 1; }
    }
  }
  return changed;
}

/* Name of a block's idx-th required parameter, or NULL. */
const char *block_param_name(Compiler *c, int block, int idx) {
  int bp = nt_ref(c->nt, block, "parameters");      /* BlockParametersNode */
  if (bp < 0) return NULL;
  int pn = nt_ref(c->nt, bp, "parameters");          /* ParametersNode */
  if (pn < 0) return NULL;
  int n = 0;
  const int *reqs = nt_arr(c->nt, pn, "requireds", &n);
  if (idx < n) return nt_str(c->nt, reqs[idx], "name");
  return NULL;
}

/* Bind block parameter types for supported iteration methods. */
static int infer_block_params(Compiler *c) {
  const NodeTable *nt = c->nt;
  int changed = 0;
  for (int id = 0; id < nt->count; id++) {
    const char *ty = nt_type(nt, id);
    if (!ty || strcmp(ty, "CallNode")) continue;
    int block = nt_ref(nt, id, "block");
    if (block < 0) continue;
    const char *name = nt_str(nt, id, "name");
    int recv = nt_ref(nt, id, "receiver");
    if (!name || recv < 0) continue;
    TyKind rt = infer_type(c, recv);
    const char *p0 = block_param_name(c, block, 0);
    if (!p0) continue;

    TyKind pt = TY_UNKNOWN;
    if ((!strcmp(name, "times") || !strcmp(name, "upto") ||
         !strcmp(name, "downto") || !strcmp(name, "step")) && rt == TY_INT)
      pt = TY_INT;
    else if (!strcmp(name, "each") && rt == TY_RANGE)
      pt = TY_INT;
    else if ((!strcmp(name, "each") || !strcmp(name, "map") ||
              !strcmp(name, "select") || !strcmp(name, "reject") ||
              !strcmp(name, "find") || !strcmp(name, "each_with_index")) &&
             ty_is_array(rt))
      pt = ty_array_elem(rt);

    if (pt == TY_UNKNOWN) continue;
    Scope *s = comp_scope_of(c, block);
    LocalVar *lv = scope_local_intern(s, p0);
    TyKind merged = ty_unify(lv->type, pt);
    if (merged != lv->type) { lv->type = merged; changed = 1; }
  }
  return changed;
}

/* Value type of an explicit `return expr` (or nil for bare return). */
static TyKind return_node_type(Compiler *c, int id) {
  int args = nt_ref(c->nt, id, "arguments");
  if (args < 0) return TY_NIL;
  int n = 0;
  const int *a = nt_arr(c->nt, args, "arguments", &n);
  return n > 0 ? infer_type(c, a[0]) : TY_NIL;
}

static int infer_return_types(Compiler *c) {
  const NodeTable *nt = c->nt;
  int changed = 0;
  /* implicit return: the body's value */
  for (int s = 1; s < c->nscopes; s++) {
    Scope *sc = &c->scopes[s];
    TyKind r = sc->body >= 0 ? infer_type(c, sc->body) : TY_NIL;
    /* explicit returns within this scope */
    for (int id = 0; id < nt->count; id++) {
      const char *ty = nt_type(nt, id);
      if (ty && !strcmp(ty, "ReturnNode") && comp_scope_of(c, id) == sc)
        r = ty_unify(r, return_node_type(c, id));
    }
    if (r != sc->ret) { sc->ret = r; changed = 1; }
  }
  return changed;
}

void analyze_program(Compiler *c) {
  /* scope 0 = top level */
  Scope *top = comp_scope_new(c, NULL, -1);
  top->body = nt_ref(c->nt, c->nt->root_id, "statements");

  walk_scope(c, c->nt->root_id, 0);
  register_locals(c);

  for (int iter = 0; iter < 128; iter++) {
    int ch = 0;
    ch |= infer_write_types(c);
    ch |= infer_param_types(c);
    ch |= infer_block_params(c);
    ch |= infer_return_types(c);
    if (!ch) break;
  }

  /* finalize: gc-root needs + full node type cache */
  for (int s = 0; s < c->nscopes; s++)
    for (int i = 0; i < c->scopes[s].nlocals; i++)
      c->scopes[s].locals[i].gc_root = (c->scopes[s].locals[i].type == TY_STRING);

  for (int id = 0; id < c->nt->count; id++)
    infer_type(c, id);
}
