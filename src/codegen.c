/* M2 code generator: the M1 scalar/control-flow subset plus user-defined
 * methods (required params, inferred param/return types, recursion, tail-
 * position implicit returns). Emits the same runtime ABI as the legacy
 * generator. Unsupported constructs abort loudly.
 */
#include "codegen.h"
#include "compiler.h"
#include "analyze.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

/* ---- output buffer ---- */

typedef struct { char *p; size_t len, cap; } Buf;

static void buf_putn(Buf *b, const char *s, size_t n) {
  if (b->len + n + 1 > b->cap) {
    size_t nc = b->cap ? b->cap * 2 : 256;
    while (nc < b->len + n + 1) nc *= 2;
    b->p = realloc(b->p, nc);
    b->cap = nc;
  }
  memcpy(b->p + b->len, s, n);
  b->len += n;
  b->p[b->len] = '\0';
}
static void buf_puts(Buf *b, const char *s) { buf_putn(b, s, strlen(s)); }
static void buf_printf(Buf *b, const char *fmt, ...) {
  char tmp[512];
  va_list ap; va_start(ap, fmt);
  int n = vsnprintf(tmp, sizeof(tmp), fmt, ap);
  va_end(ap);
  if (n < 0) return;
  if ((size_t)n < sizeof(tmp)) { buf_putn(b, tmp, (size_t)n); return; }
  char *big = malloc((size_t)n + 1);
  va_start(ap, fmt); vsnprintf(big, (size_t)n + 1, fmt, ap); va_end(ap);
  buf_putn(b, big, (size_t)n); free(big);
}
static void emit_indent(Buf *b, int n) { for (int i = 0; i < n; i++) buf_puts(b, "  "); }

/* Statement prelude: some expressions (array/hash literals) lower to
   temp-variable construction that must run before the statement that
   uses them. While a statement line is being built, g_pre collects those
   setup lines at g_indent; the statement wrapper flushes g_pre before the
   line. g_tmp hands out unique temp ids. */
static Buf *g_pre = NULL;
static int  g_indent = 0;
static int  g_tmp = 0;

/* ---- diagnostics ---- */

static void unsupported(Compiler *c, int id, const char *what) {
  const char *ty = nt_type(c->nt, id);
  fprintf(stderr, "spinelc: unsupported %s: node %d (%s)\n",
          what, id, ty ? ty : "?");
  exit(1);
}

/* ---- type -> C ---- */

static const char *c_type_name(TyKind t) {
  switch (t) {
    case TY_INT:         return "mrb_int";
    case TY_FLOAT:       return "mrb_float";
    case TY_BOOL:        return "mrb_bool";
    case TY_STRING:      return "const char *";
    case TY_INT_ARRAY:   return "sp_IntArray *";
    case TY_FLOAT_ARRAY: return "sp_FloatArray *";
    case TY_STR_ARRAY:   return "sp_StrArray *";
    default:             return NULL;
  }
}
static int is_scalar_ret(TyKind t) {
  return t == TY_INT || t == TY_FLOAT || t == TY_BOOL || t == TY_STRING ||
         t == TY_INT_ARRAY || t == TY_FLOAT_ARRAY || t == TY_STR_ARRAY;
}
static const char *default_value(TyKind t) {
  switch (t) {
    case TY_INT:    return "0";
    case TY_FLOAT:  return "0.0";
    case TY_BOOL:   return "0";
    case TY_STRING: return "(&(\"\\xff\")[1])";
    case TY_INT_ARRAY:
    case TY_FLOAT_ARRAY:
    case TY_STR_ARRAY: return "NULL";
    default:        return "0";
  }
}
/* "Int" / "Str" / "Float" for the sp_<K>Array_* runtime family. */
static const char *array_kind(TyKind t) {
  switch (t) {
    case TY_INT_ARRAY:   return "Int";
    case TY_FLOAT_ARRAY: return "Float";
    case TY_STR_ARRAY:   return "Str";
    default:             return NULL;
  }
}

/* ---- C string literals ---- */

static void emit_c_escaped(Buf *b, const char *s) {
  for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
    unsigned char ch = *p;
    if (ch == '\\' || ch == '"') buf_printf(b, "\\%c", ch);
    else if (ch == '\n') buf_puts(b, "\\n");
    else if (ch == '\t') buf_puts(b, "\\t");
    else if (ch == '\r') buf_puts(b, "\\r");
    else if (ch >= 0x20 && ch < 0x7f) buf_printf(b, "%c", ch);
    else buf_printf(b, "\\%03o", ch);
  }
}
static void emit_str_literal(Buf *b, const char *content) {
  if (!content || !*content) { buf_puts(b, "(&(\"\\xff\")[1])"); return; }
  buf_puts(b, "(&(\"\\xff\" \"");
  emit_c_escaped(b, content);
  buf_puts(b, "\")[1])");
}

/* ---- forward decls ---- */

static void emit_expr(Compiler *c, int id, Buf *b);
static void emit_stmt(Compiler *c, int id, Buf *b, int indent);
static void emit_stmts(Compiler *c, int id, Buf *b, int indent);
static void emit_stmts_tail(Compiler *c, int id, Buf *b, int indent);
static int  emit_array_mutate_stmt(Compiler *c, int id, Buf *b, int indent);
static int  emit_output_call(Compiler *c, int id, Buf *b, int indent);
static int  emit_iteration_stmt(Compiler *c, int id, Buf *b, int indent);

/* Strip ParenthesesNode wrappers to reach the inner expression. */
static int unwrap_parens(Compiler *c, int id) {
  while (id >= 0) {
    const char *ty = nt_type(c->nt, id);
    if (!ty || strcmp(ty, "ParenthesesNode")) break;
    int body = nt_ref(c->nt, id, "body");
    int n = 0;
    const int *bd = body >= 0 ? nt_arr(c->nt, body, "body", &n) : NULL;
    if (n != 1) break;
    id = bd[0];
  }
  return id;
}

/* ---- calls ---- */

static const char *int_arith_fn(const char *op) {
  if (!strcmp(op, "+"))  return "sp_int_add";
  if (!strcmp(op, "-"))  return "sp_int_sub";
  if (!strcmp(op, "*"))  return "sp_int_mul";
  if (!strcmp(op, "/"))  return "sp_idiv";
  if (!strcmp(op, "%"))  return "sp_imod";
  if (!strcmp(op, "**")) return "sp_int_pow";
  return NULL;
}

static void emit_method_call(Compiler *c, int id, Buf *b) {
  const NodeTable *nt = c->nt;
  const char *name = nt_str(nt, id, "name");
  int args = nt_ref(nt, id, "arguments");
  int argc = 0;
  const int *argv = NULL;
  if (args >= 0) argv = nt_arr(nt, args, "arguments", &argc);
  buf_printf(b, "sp_%s(", name);
  for (int k = 0; k < argc; k++) {
    if (k) buf_puts(b, ", ");
    emit_expr(c, argv[k], b);
  }
  buf_puts(b, ")");
}

static void emit_call(Compiler *c, int id, Buf *b) {
  const NodeTable *nt = c->nt;
  const char *name = nt_str(nt, id, "name");
  int recv = nt_ref(nt, id, "receiver");
  int args = nt_ref(nt, id, "arguments");
  int argc = 0;
  const int *argv = NULL;
  if (args >= 0) argv = nt_arr(nt, args, "arguments", &argc);
  if (!name) unsupported(c, id, "call (no name)");

  if (recv < 0 && comp_method_index(c, name) >= 0) { emit_method_call(c, id, b); return; }

  TyKind rt = recv >= 0 ? comp_ntype(c, recv) : TY_UNKNOWN;
  TyKind a0 = argc >= 1 ? comp_ntype(c, argv[0]) : TY_UNKNOWN;
  TyKind res = comp_ntype(c, id);

  if ((!strcmp(name, "-@") || !strcmp(name, "+@")) && recv >= 0 && argc == 0) {
    buf_puts(b, name[0] == '-' ? "(-" : "(+");
    emit_expr(c, recv, b); buf_puts(b, ")");
    return;
  }
  if (!strcmp(name, "!") && recv >= 0 && argc == 0) {
    buf_puts(b, "(!"); emit_expr(c, recv, b); buf_puts(b, ")");
    return;
  }

  if (recv >= 0 && argc == 1 && int_arith_fn(name)) {
    if (rt == TY_STRING && !strcmp(name, "+")) {
      buf_puts(b, "sp_str_concat(");
      emit_expr(c, recv, b); buf_puts(b, ", "); emit_expr(c, argv[0], b);
      buf_puts(b, ")");
      return;
    }
    if (res == TY_INT) {
      buf_printf(b, "%s(", int_arith_fn(name));
      emit_expr(c, recv, b); buf_puts(b, ", "); emit_expr(c, argv[0], b);
      buf_puts(b, ")");
      return;
    }
    if (res == TY_FLOAT && strcmp(name, "%") && strcmp(name, "**")) {
      buf_puts(b, "(");
      emit_expr(c, recv, b);
      buf_printf(b, " %s ", name);
      emit_expr(c, argv[0], b);
      buf_puts(b, ")");
      return;
    }
    unsupported(c, id, "arithmetic");
  }

  if (recv >= 0 && argc == 1 &&
      (!strcmp(name, "<") || !strcmp(name, ">") ||
       !strcmp(name, "<=") || !strcmp(name, ">="))) {
    if (ty_is_numeric(rt)) {
      buf_puts(b, "(");
      emit_expr(c, recv, b);
      buf_printf(b, " %s ", name);
      emit_expr(c, argv[0], b);
      buf_puts(b, ")");
      return;
    }
    unsupported(c, id, "comparison");
  }

  if (argc == 1 && (!strcmp(name, "==") || !strcmp(name, "!="))) {
    int eq = !strcmp(name, "==");
    if (rt == TY_STRING || a0 == TY_STRING) {
      buf_puts(b, eq ? "sp_str_eq(" : "(!sp_str_eq(");
      emit_expr(c, recv, b); buf_puts(b, ", "); emit_expr(c, argv[0], b);
      buf_puts(b, eq ? ")" : "))");
      return;
    }
    if (ty_is_numeric(rt) || rt == TY_BOOL) {
      buf_puts(b, "(");
      emit_expr(c, recv, b);
      buf_printf(b, " %s ", eq ? "==" : "!=");
      emit_expr(c, argv[0], b);
      buf_puts(b, ")");
      return;
    }
    unsupported(c, id, "equality");
  }

  /* array value methods */
  if (recv >= 0 && ty_is_array(rt)) {
    const char *k = array_kind(rt);
    if (k) {
      if (!strcmp(name, "[]") && argc == 1) {
        buf_printf(b, "sp_%sArray_get(", k);
        emit_expr(c, recv, b); buf_puts(b, ", "); emit_expr(c, argv[0], b);
        buf_puts(b, ")");
        return;
      }
      if ((!strcmp(name, "length") || !strcmp(name, "size")) && argc == 0) {
        buf_printf(b, "sp_%sArray_length(", k); emit_expr(c, recv, b); buf_puts(b, ")");
        return;
      }
      if (!strcmp(name, "empty?") && argc == 0) {
        buf_printf(b, "(sp_%sArray_length(", k); emit_expr(c, recv, b); buf_puts(b, ") == 0)");
        return;
      }
      if (!strcmp(name, "sum") && argc == 0) {
        buf_printf(b, "sp_%sArray_sum(", k); emit_expr(c, recv, b); buf_puts(b, ", 0)");
        return;
      }
      if (!strcmp(name, "join") && rt == TY_STR_ARRAY && argc == 1) {
        buf_puts(b, "sp_StrArray_join("); emit_expr(c, recv, b); buf_puts(b, ", ");
        emit_expr(c, argv[0], b); buf_puts(b, ")");
        return;
      }
      if ((!strcmp(name, "inspect") || !strcmp(name, "to_s")) && argc == 0) {
        buf_printf(b, "sp_%sArray_inspect(", k); emit_expr(c, recv, b); buf_puts(b, ")");
        return;
      }
    }
  }

  /* scalar receiver methods: evaluate the receiver once into rs, then
     splice its text (so a literal/complex receiver isn't rebuilt). */
  if (recv >= 0 && (rt == TY_STRING || rt == TY_INT || rt == TY_FLOAT)) {
    Buf rs; memset(&rs, 0, sizeof rs);
    emit_expr(c, recv, &rs);
    const char *r = rs.p ? rs.p : "";
    int handled = 1;

    if (rt == TY_STRING) {
      if      (!strcmp(name, "length") || !strcmp(name, "size")) buf_printf(b, "sp_str_length(%s)", r);
      else if (!strcmp(name, "upcase"))     buf_printf(b, "sp_str_upcase(%s)", r);
      else if (!strcmp(name, "downcase"))   buf_printf(b, "sp_str_downcase(%s)", r);
      else if (!strcmp(name, "capitalize")) buf_printf(b, "sp_str_capitalize(%s)", r);
      else if (!strcmp(name, "reverse"))    buf_printf(b, "sp_str_reverse(%s)", r);
      else if (!strcmp(name, "strip"))      buf_printf(b, "sp_str_strip(%s)", r);
      else if (!strcmp(name, "lstrip"))     buf_printf(b, "sp_str_lstrip(%s)", r);
      else if (!strcmp(name, "rstrip"))     buf_printf(b, "sp_str_rstrip(%s)", r);
      else if (!strcmp(name, "chomp"))      buf_printf(b, "sp_str_chomp(%s)", r);
      else if (!strcmp(name, "chop"))       buf_printf(b, "sp_str_chop(%s)", r);
      else if (!strcmp(name, "to_s") || !strcmp(name, "to_str") || !strcmp(name, "dup")) buf_puts(b, r);
      else if (!strcmp(name, "empty?"))     buf_printf(b, "(sp_str_length(%s) == 0)", r);
      else if (!strcmp(name, "include?") && argc == 1) {
        buf_printf(b, "sp_str_include(%s, ", r); emit_expr(c, argv[0], b); buf_puts(b, ")");
      } else if (!strcmp(name, "start_with?") && argc == 1) {
        buf_printf(b, "sp_str_start_with(%s, ", r); emit_expr(c, argv[0], b); buf_puts(b, ")");
      } else if (!strcmp(name, "end_with?") && argc == 1) {
        buf_printf(b, "sp_str_end_with(%s, ", r); emit_expr(c, argv[0], b); buf_puts(b, ")");
      } else if (!strcmp(name, "index") && argc == 1) {
        buf_printf(b, "sp_str_index(%s, ", r); emit_expr(c, argv[0], b); buf_puts(b, ")");
      } else if (!strcmp(name, "[]") && argc == 1) {
        buf_printf(b, "sp_str_char_at_or_nil(%s, ", r); emit_expr(c, argv[0], b); buf_puts(b, ")");
      } else if (!strcmp(name, "split") && argc == 1) {
        buf_printf(b, "sp_str_split_drop_trailing(%s, ", r); emit_expr(c, argv[0], b); buf_puts(b, ")");
      } else handled = 0;
    } else if (rt == TY_INT) {
      if      (!strcmp(name, "to_s"))   buf_printf(b, "sp_int_to_s(%s)", r);
      else if (!strcmp(name, "to_f"))   buf_printf(b, "((mrb_float)(%s))", r);
      else if (!strcmp(name, "to_i") || !strcmp(name, "to_int") || !strcmp(name, "floor") ||
               !strcmp(name, "ceil") || !strcmp(name, "round")) buf_printf(b, "(%s)", r);
      else if (!strcmp(name, "abs"))    buf_printf(b, "((%s) < 0 ? -(%s) : (%s))", r, r, r);
      else if (!strcmp(name, "chr"))    buf_printf(b, "sp_int_chr(%s)", r);
      else if (!strcmp(name, "even?"))  buf_printf(b, "((%s) %% 2 == 0)", r);
      else if (!strcmp(name, "odd?"))   buf_printf(b, "((%s) %% 2 != 0)", r);
      else if (!strcmp(name, "zero?"))  buf_printf(b, "((%s) == 0)", r);
      else if (!strcmp(name, "positive?")) buf_printf(b, "((%s) > 0)", r);
      else if (!strcmp(name, "negative?")) buf_printf(b, "((%s) < 0)", r);
      else handled = 0;
    } else { /* TY_FLOAT */
      if      (!strcmp(name, "floor")) buf_printf(b, "((mrb_int)floor(%s))", r);
      else if (!strcmp(name, "ceil"))  buf_printf(b, "((mrb_int)ceil(%s))", r);
      else if (!strcmp(name, "round")) buf_printf(b, "((mrb_int)round(%s))", r);
      else if (!strcmp(name, "to_i"))  buf_printf(b, "((mrb_int)(%s))", r);
      else if (!strcmp(name, "to_f"))  buf_printf(b, "(%s)", r);
      else if (!strcmp(name, "to_s"))  buf_printf(b, "sp_float_to_s(%s)", r);
      else if (!strcmp(name, "abs"))   buf_printf(b, "((%s) < 0 ? -(%s) : (%s))", r, r, r);
      else if (!strcmp(name, "zero?")) buf_printf(b, "((%s) == 0.0)", r);
      else handled = 0;
    }
    free(rs.p);
    if (handled) return;
  }

  unsupported(c, id, "call");
}

/* Array-mutating calls emitted as statements: a[i]=v, a.push(v), a<<v.
   Returns 1 if handled. */
static int emit_array_mutate_stmt(Compiler *c, int id, Buf *b, int indent) {
  const NodeTable *nt = c->nt;
  const char *name = nt_str(nt, id, "name");
  int recv = nt_ref(nt, id, "receiver");
  if (!name || recv < 0) return 0;
  TyKind rt = comp_ntype(c, recv);
  if (!ty_is_array(rt)) return 0;
  const char *k = array_kind(rt);
  if (!k) return 0;
  int args = nt_ref(nt, id, "arguments");
  int argc = 0;
  const int *argv = NULL;
  if (args >= 0) argv = nt_arr(nt, args, "arguments", &argc);

  if (!strcmp(name, "[]=") && argc == 2) {
    emit_indent(b, indent);
    buf_printf(b, "sp_%sArray_set(", k);
    emit_expr(c, recv, b); buf_puts(b, ", ");
    emit_expr(c, argv[0], b); buf_puts(b, ", ");
    emit_expr(c, argv[1], b); buf_puts(b, ");\n");
    return 1;
  }
  if ((!strcmp(name, "push") || !strcmp(name, "<<")) && argc == 1) {
    emit_indent(b, indent);
    buf_printf(b, "sp_%sArray_push(", k);
    emit_expr(c, recv, b); buf_puts(b, ", ");
    emit_expr(c, argv[0], b); buf_puts(b, ");\n");
    return 1;
  }
  return 0;
}

/* Block iteration lowered to an inline C for-loop. Handles n.times,
   array.each, range.each, n.upto/downto. Returns 1 if handled. */
static int emit_iteration_stmt(Compiler *c, int id, Buf *b, int indent) {
  const NodeTable *nt = c->nt;
  int block = nt_ref(nt, id, "block");
  if (block < 0) return 0;
  const char *name = nt_str(nt, id, "name");
  int recv = nt_ref(nt, id, "receiver");
  if (!name || recv < 0) return 0;
  int body = nt_ref(nt, block, "body");
  const char *p0 = block_param_name(c, block, 0);
  TyKind rt = comp_ntype(c, recv);

  /* n.times { |i| ... } */
  if (!strcmp(name, "times") && rt == TY_INT) {
    int t = ++g_tmp;
    Buf rb; memset(&rb, 0, sizeof rb);
    emit_expr(c, recv, &rb);
    emit_indent(b, indent);
    buf_printf(b, "for (mrb_int _t%d = 0; _t%d < ", t, t);
    buf_puts(b, rb.p); buf_printf(b, "; _t%d++) {\n", t);
    if (p0) { emit_indent(b, indent + 1); buf_printf(b, "lv_%s = _t%d;\n", p0, t); }
    emit_stmts(c, body, b, indent + 1);
    emit_indent(b, indent); buf_puts(b, "}\n");
    free(rb.p);
    return 1;
  }

  /* array.each { |x| ... } */
  if (!strcmp(name, "each") && ty_is_array(rt)) {
    const char *k = array_kind(rt);
    if (!k) return 0;
    int t = ++g_tmp;
    Buf rb; memset(&rb, 0, sizeof rb);
    emit_expr(c, recv, &rb);
    emit_indent(b, indent);
    buf_printf(b, "for (mrb_int _t%d = 0; _t%d < sp_%sArray_length(", t, t, k);
    buf_puts(b, rb.p); buf_printf(b, "); _t%d++) {\n", t);
    if (p0) {
      emit_indent(b, indent + 1);
      buf_printf(b, "lv_%s = sp_%sArray_get(", p0, k);
      buf_puts(b, rb.p); buf_printf(b, ", _t%d);\n", t);
    }
    emit_stmts(c, body, b, indent + 1);
    emit_indent(b, indent); buf_puts(b, "}\n");
    free(rb.p);
    return 1;
  }

  /* (a..b).each { |i| ... } */
  if (!strcmp(name, "each") && rt == TY_RANGE && p0) {
    int rn = unwrap_parens(c, recv);
    if (nt_type(nt, rn) && !strcmp(nt_type(nt, rn), "RangeNode")) {
      int left = nt_ref(nt, rn, "left");
      int right = nt_ref(nt, rn, "right");
      int excl = (int)(nt_int(nt, rn, "flags", 0) & 4);
      Buf lb; memset(&lb, 0, sizeof lb); emit_expr(c, left, &lb);
      Buf rb; memset(&rb, 0, sizeof rb); emit_expr(c, right, &rb);
      emit_indent(b, indent);
      buf_printf(b, "for (lv_%s = ", p0); buf_puts(b, lb.p);
      buf_printf(b, "; lv_%s %s ", p0, excl ? "<" : "<="); buf_puts(b, rb.p);
      buf_printf(b, "; lv_%s++) {\n", p0);
      emit_stmts(c, body, b, indent + 1);
      emit_indent(b, indent); buf_puts(b, "}\n");
      free(lb.p); free(rb.p);
      return 1;
    }
  }

  /* n.upto(m) / n.downto(m) { |i| ... } */
  if ((!strcmp(name, "upto") || !strcmp(name, "downto")) && rt == TY_INT && p0) {
    int up = !strcmp(name, "upto");
    int args = nt_ref(nt, id, "arguments");
    int argc = 0;
    const int *argv = NULL;
    if (args >= 0) argv = nt_arr(nt, args, "arguments", &argc);
    if (argc != 1) return 0;
    Buf lo; memset(&lo, 0, sizeof lo); emit_expr(c, recv, &lo);
    Buf hi; memset(&hi, 0, sizeof hi); emit_expr(c, argv[0], &hi);
    emit_indent(b, indent);
    buf_printf(b, "for (lv_%s = ", p0); buf_puts(b, lo.p);
    buf_printf(b, "; lv_%s %s ", p0, up ? "<=" : ">="); buf_puts(b, hi.p);
    buf_printf(b, "; lv_%s%s) {\n", p0, up ? "++" : "--");
    emit_stmts(c, body, b, indent + 1);
    emit_indent(b, indent); buf_puts(b, "}\n");
    free(lo.p); free(hi.p);
    return 1;
  }

  return 0;
}

/* ---- interpolation ---- */

static void emit_interp(Compiler *c, int id, Buf *b) {
  const NodeTable *nt = c->nt;
  int n = 0;
  const int *parts = nt_arr(nt, id, "parts", &n);
  Buf fmt; memset(&fmt, 0, sizeof fmt);
  Buf argbuf; memset(&argbuf, 0, sizeof argbuf);
  int nargs = 0;

  for (int k = 0; k < n; k++) {
    int pid = parts[k];
    const char *pty = nt_type(nt, pid);
    if (pty && !strcmp(pty, "StringNode")) {
      const char *content = nt_str(nt, pid, "content");
      for (const char *p = content ? content : ""; *p; p++) {
        if (*p == '%') buf_puts(&fmt, "%%");
        else buf_printf(&fmt, "%c", *p);
      }
    } else if (pty && !strcmp(pty, "EmbeddedStatementsNode")) {
      int s = nt_ref(nt, pid, "statements");
      int bn = 0;
      const int *body = s >= 0 ? nt_arr(nt, s, "body", &bn) : NULL;
      int expr = bn > 0 ? body[bn - 1] : -1;
      TyKind t = comp_ntype(c, expr);
      buf_puts(&argbuf, ", ");
      if (t == TY_INT) {
        buf_puts(&fmt, "%lld"); buf_puts(&argbuf, "(long long)");
        emit_expr(c, expr, &argbuf);
      } else if (t == TY_STRING) {
        buf_puts(&fmt, "%s"); emit_expr(c, expr, &argbuf);
      } else if (t == TY_FLOAT) {
        buf_puts(&fmt, "%s"); buf_puts(&argbuf, "sp_float_to_s(");
        emit_expr(c, expr, &argbuf); buf_puts(&argbuf, ")");
      } else if (t == TY_BOOL) {
        buf_puts(&fmt, "%s"); buf_puts(&argbuf, "(");
        emit_expr(c, expr, &argbuf); buf_puts(&argbuf, " ? \"true\" : \"false\")");
      } else {
        free(fmt.p); free(argbuf.p);
        unsupported(c, pid, "interpolation value");
      }
      nargs++;
    } else {
      free(fmt.p); free(argbuf.p);
      unsupported(c, pid, "interpolation part");
    }
  }

  if (nargs == 0) {
    buf_puts(b, "(&(\"\\xff\" \"");
    for (const char *p = fmt.p ? fmt.p : ""; *p; p++) {
      if (p[0] == '%' && p[1] == '%') { buf_puts(b, "%"); p++; }
      else buf_printf(b, "%c", *p);
    }
    buf_puts(b, "\")[1])");
  } else {
    buf_puts(b, "sp_sprintf(\"");
    buf_puts(b, fmt.p ? fmt.p : "");
    buf_puts(b, "\"");
    buf_puts(b, argbuf.p ? argbuf.p : "");
    buf_puts(b, ")");
  }
  free(fmt.p); free(argbuf.p);
}

/* ---- expression ---- */

static void emit_expr(Compiler *c, int id, Buf *b) {
  const NodeTable *nt = c->nt;
  const char *ty = nt_type(nt, id);
  if (!ty) unsupported(c, id, "expression (no type)");

  if (!strcmp(ty, "IntegerNode")) { buf_printf(b, "%lldLL", nt_int(nt, id, "value", 0)); return; }
  if (!strcmp(ty, "FloatNode")) { const char *v = nt_content(nt, id); buf_puts(b, v ? v : "0.0"); return; }
  if (!strcmp(ty, "StringNode")) { emit_str_literal(b, nt_str(nt, id, "content")); return; }
  if (!strcmp(ty, "InterpolatedStringNode")) { emit_interp(c, id, b); return; }
  if (!strcmp(ty, "TrueNode"))  { buf_puts(b, "1"); return; }
  if (!strcmp(ty, "FalseNode")) { buf_puts(b, "0"); return; }
  if (!strcmp(ty, "LocalVariableReadNode")) { buf_printf(b, "lv_%s", nt_str(nt, id, "name")); return; }
  if (!strcmp(ty, "ParenthesesNode")) {
    int body = nt_ref(nt, id, "body");
    int n = 0;
    const int *bd = body >= 0 ? nt_arr(nt, body, "body", &n) : NULL;
    if (n != 1) unsupported(c, id, "parenthesized group");
    buf_puts(b, "("); emit_expr(c, bd[0], b); buf_puts(b, ")");
    return;
  }
  if (!strcmp(ty, "ArrayNode")) {
    TyKind at = comp_ntype(c, id);
    const char *k = array_kind(at);
    if (!k) unsupported(c, id, "array literal (element type)");
    int n = 0;
    const int *els = nt_arr(nt, id, "elements", &n);
    int t = ++g_tmp;
    emit_indent(g_pre, g_indent);
    buf_printf(g_pre, "sp_%sArray *_t%d = sp_%sArray_new();\n", k, t, k);
    emit_indent(g_pre, g_indent);
    buf_printf(g_pre, "SP_GC_ROOT(_t%d);\n", t);
    for (int j = 0; j < n; j++) {
      Buf el; memset(&el, 0, sizeof el);
      emit_expr(c, els[j], &el);   /* element preludes flow to g_pre first */
      emit_indent(g_pre, g_indent);
      buf_printf(g_pre, "sp_%sArray_push(_t%d, ", k, t);
      buf_puts(g_pre, el.p ? el.p : "");
      buf_puts(g_pre, ");\n");
      free(el.p);
    }
    buf_printf(b, "_t%d", t);
    return;
  }
  if (!strcmp(ty, "CallNode")) { emit_call(c, id, b); return; }

  unsupported(c, id, "expression");
}

/* ---- output statements (puts/print/p) ---- */

static void emit_puts_one(Compiler *c, int arg, Buf *b, int indent) {
  TyKind t = comp_ntype(c, arg);
  emit_indent(b, indent);
  if (t == TY_INT) {
    buf_puts(b, "printf(\"%lld\\n\", (long long)"); emit_expr(c, arg, b); buf_puts(b, ");\n");
  } else if (t == TY_FLOAT) {
    buf_puts(b, "{ const char *_fs = sp_float_to_s("); emit_expr(c, arg, b);
    buf_puts(b, "); fputs(_fs, stdout); putchar('\\n'); }\n");
  } else if (t == TY_STRING) {
    buf_puts(b, "{ const char *_ps = (const char *)("); emit_expr(c, arg, b);
    buf_puts(b, "); if (_ps) { fputs(_ps, stdout); if (!*_ps || _ps[strlen(_ps)-1] != '\\n') putchar('\\n'); } else putchar('\\n'); }\n");
  } else if (t == TY_BOOL) {
    buf_puts(b, "puts(("); emit_expr(c, arg, b); buf_puts(b, ") ? \"true\" : \"false\");\n");
  } else {
    unsupported(c, arg, "puts argument");
  }
}
static void emit_print_one(Compiler *c, int arg, Buf *b, int indent) {
  TyKind t = comp_ntype(c, arg);
  emit_indent(b, indent);
  if (t == TY_INT) {
    buf_puts(b, "printf(\"%lld\", (long long)"); emit_expr(c, arg, b); buf_puts(b, ");\n");
  } else if (t == TY_FLOAT) {
    buf_puts(b, "fputs(sp_float_to_s("); emit_expr(c, arg, b); buf_puts(b, "), stdout);\n");
  } else if (t == TY_STRING) {
    buf_puts(b, "{ const char *_s = ("); emit_expr(c, arg, b);
    buf_puts(b, "); if (_s) fputs(_s, stdout); }\n");
  } else if (t == TY_BOOL) {
    buf_puts(b, "fputs(("); emit_expr(c, arg, b); buf_puts(b, ") ? \"true\" : \"false\", stdout);\n");
  } else {
    unsupported(c, arg, "print argument");
  }
}
static void emit_p_one(Compiler *c, int arg, Buf *b, int indent) {
  TyKind t = comp_ntype(c, arg);
  emit_indent(b, indent);
  if (t == TY_INT) {
    buf_puts(b, "printf(\"%lld\\n\", (long long)"); emit_expr(c, arg, b); buf_puts(b, ");\n");
  } else if (t == TY_FLOAT) {
    buf_puts(b, "{ const char *_fs = sp_float_to_s("); emit_expr(c, arg, b);
    buf_puts(b, "); fputs(_fs, stdout); putchar('\\n'); }\n");
  } else if (t == TY_STRING) {
    buf_puts(b, "fputs(sp_str_inspect("); emit_expr(c, arg, b);
    buf_puts(b, "), stdout); putchar('\\n');\n");
  } else if (t == TY_BOOL) {
    buf_puts(b, "puts(("); emit_expr(c, arg, b); buf_puts(b, ") ? \"true\" : \"false\");\n");
  } else if (ty_is_array(t) && array_kind(t)) {
    buf_printf(b, "fputs(sp_%sArray_inspect(", array_kind(t));
    emit_expr(c, arg, b);
    buf_puts(b, "), stdout); putchar('\\n');\n");
  } else {
    unsupported(c, arg, "p argument");
  }
}

static int emit_output_call(Compiler *c, int id, Buf *b, int indent) {
  const NodeTable *nt = c->nt;
  const char *name = nt_str(nt, id, "name");
  int recv = nt_ref(nt, id, "receiver");
  if (!name || recv >= 0) return 0;
  if (comp_method_index(c, name) >= 0) return 0; /* user method shadows builtin */
  int args = nt_ref(nt, id, "arguments");
  int argc = 0;
  const int *argv = NULL;
  if (args >= 0) argv = nt_arr(nt, args, "arguments", &argc);

  if (!strcmp(name, "puts")) {
    if (argc == 0) { emit_indent(b, indent); buf_puts(b, "putchar('\\n');\n"); return 1; }
    for (int k = 0; k < argc; k++) emit_puts_one(c, argv[k], b, indent);
    return 1;
  }
  if (!strcmp(name, "print")) { for (int k = 0; k < argc; k++) emit_print_one(c, argv[k], b, indent); return 1; }
  if (!strcmp(name, "p"))     { for (int k = 0; k < argc; k++) emit_p_one(c, argv[k], b, indent); return 1; }
  return 0;
}

/* ---- assignment ---- */

static void emit_assign(Compiler *c, int id, Buf *b, int indent) {
  const char *nm = nt_str(c->nt, id, "name");
  int v = nt_ref(c->nt, id, "value");
  emit_indent(b, indent);
  buf_printf(b, "lv_%s = ", nm);
  emit_expr(c, v, b);
  buf_puts(b, ";\n");
}

static void emit_op_assign(Compiler *c, int id, Buf *b, int indent) {
  const NodeTable *nt = c->nt;
  const char *nm = nt_str(nt, id, "name");
  const char *op = nt_str(nt, id, "binary_operator");
  int v = nt_ref(nt, id, "value");
  LocalVar *lv = scope_local(comp_scope_of(c, id), nm);
  TyKind t = lv ? lv->type : TY_UNKNOWN;
  emit_indent(b, indent);

  if (t == TY_STRING && !strcmp(op, "+")) {
    buf_printf(b, "lv_%s = sp_str_concat(lv_%s, ", nm, nm);
    emit_expr(c, v, b); buf_puts(b, ");\n");
    return;
  }
  if (t == TY_INT && (!strcmp(op, "+") || !strcmp(op, "-") || !strcmp(op, "*"))) {
    buf_printf(b, "lv_%s %s= ", nm, op); emit_expr(c, v, b); buf_puts(b, ";\n");
    return;
  }
  if (t == TY_INT) {
    const char *fn = int_arith_fn(op);
    if (fn) { buf_printf(b, "lv_%s = %s(lv_%s, ", nm, fn, nm); emit_expr(c, v, b); buf_puts(b, ");\n"); return; }
  }
  if (t == TY_FLOAT && (!strcmp(op, "+") || !strcmp(op, "-") || !strcmp(op, "*") || !strcmp(op, "/"))) {
    buf_printf(b, "lv_%s %s= ", nm, op); emit_expr(c, v, b); buf_puts(b, ";\n");
    return;
  }
  unsupported(c, id, "operator assignment");
}

/* ---- control flow ---- */

static void emit_cond(Compiler *c, int id, Buf *b) {
  if (comp_ntype(c, id) != TY_BOOL) unsupported(c, id, "condition (non-bool)");
  emit_expr(c, id, b);
}

static void emit_if(Compiler *c, int id, Buf *b, int indent, int is_unless, int tail) {
  const NodeTable *nt = c->nt;
  int pred = nt_ref(nt, id, "predicate");
  int then_b = nt_ref(nt, id, "statements");
  int sub = nt_ref(nt, id, "subsequent");

  emit_indent(b, indent);
  buf_puts(b, "if (");
  if (is_unless) buf_puts(b, "!(");
  emit_cond(c, pred, b);
  if (is_unless) buf_puts(b, ")");
  buf_puts(b, ") {\n");
  if (tail) emit_stmts_tail(c, then_b, b, indent + 1);
  else      emit_stmts(c, then_b, b, indent + 1);
  emit_indent(b, indent);
  buf_puts(b, "}");

  if (sub >= 0) {
    const char *sty = nt_type(nt, sub);
    if (sty && !strcmp(sty, "ElseNode")) {
      buf_puts(b, " else {\n");
      int s = nt_ref(nt, sub, "statements");
      if (tail) emit_stmts_tail(c, s, b, indent + 1);
      else      emit_stmts(c, s, b, indent + 1);
      emit_indent(b, indent); buf_puts(b, "}\n");
    } else if (sty && !strcmp(sty, "IfNode")) {
      buf_puts(b, " else {\n");
      emit_if(c, sub, b, indent + 1, 0, tail);
      emit_indent(b, indent); buf_puts(b, "}\n");
    } else {
      buf_puts(b, "\n");
    }
  } else {
    buf_puts(b, "\n");
  }
}

static void emit_while(Compiler *c, int id, Buf *b, int indent, int is_until) {
  const NodeTable *nt = c->nt;
  int pred = nt_ref(nt, id, "predicate");
  int body = nt_ref(nt, id, "statements");
  emit_indent(b, indent);
  buf_puts(b, "while (");
  if (is_until) buf_puts(b, "!(");
  emit_cond(c, pred, b);
  if (is_until) buf_puts(b, ")");
  buf_puts(b, ") {\n");
  emit_stmts(c, body, b, indent + 1);
  emit_indent(b, indent);
  buf_puts(b, "}\n");
}

static void emit_return(Compiler *c, int id, Buf *b, int indent) {
  int args = nt_ref(c->nt, id, "arguments");
  int n = 0;
  const int *a = args >= 0 ? nt_arr(c->nt, args, "arguments", &n) : NULL;
  emit_indent(b, indent);
  if (n > 0) { buf_puts(b, "return "); emit_expr(c, a[0], b); buf_puts(b, ";\n"); }
  else buf_puts(b, "return;\n");
}

static void emit_stmt_inner(Compiler *c, int id, Buf *b, int indent);
static void emit_stmt_tail_inner(Compiler *c, int id, Buf *b, int indent);

/* Wrap a line-emitting statement so any expression preludes are flushed
   before the line itself. */
static void emit_with_prelude(Compiler *c, int id, Buf *b, int indent,
                              void (*inner)(Compiler *, int, Buf *, int)) {
  Buf *savePre = g_pre;
  int saveIndent = g_indent;
  Buf pre;  memset(&pre, 0, sizeof pre);
  Buf line; memset(&line, 0, sizeof line);
  g_pre = &pre;
  g_indent = indent;
  inner(c, id, &line, indent);
  g_pre = savePre;
  g_indent = saveIndent;
  if (pre.p)  buf_puts(b, pre.p);
  if (line.p) buf_puts(b, line.p);
  free(pre.p);
  free(line.p);
}

static void emit_stmt(Compiler *c, int id, Buf *b, int indent) {
  emit_with_prelude(c, id, b, indent, emit_stmt_inner);
}
static void emit_stmt_tail(Compiler *c, int id, Buf *b, int indent) {
  emit_with_prelude(c, id, b, indent, emit_stmt_tail_inner);
}

static void emit_stmt_inner(Compiler *c, int id, Buf *b, int indent) {
  const NodeTable *nt = c->nt;
  const char *ty = nt_type(nt, id);
  if (!ty) unsupported(c, id, "statement (no type)");

  if (!strcmp(ty, "CallNode")) {
    if (emit_output_call(c, id, b, indent)) return;
    if (emit_iteration_stmt(c, id, b, indent)) return;
    if (emit_array_mutate_stmt(c, id, b, indent)) return;
    emit_indent(b, indent);
    emit_expr(c, id, b);
    buf_puts(b, ";\n");
    return;
  }
  if (!strcmp(ty, "LocalVariableWriteNode")) { emit_assign(c, id, b, indent); return; }
  if (!strcmp(ty, "LocalVariableOperatorWriteNode")) { emit_op_assign(c, id, b, indent); return; }
  if (!strcmp(ty, "IfNode"))     { emit_if(c, id, b, indent, 0, 0); return; }
  if (!strcmp(ty, "UnlessNode")) { emit_if(c, id, b, indent, 1, 0); return; }
  if (!strcmp(ty, "WhileNode"))  { emit_while(c, id, b, indent, 0); return; }
  if (!strcmp(ty, "UntilNode"))  { emit_while(c, id, b, indent, 1); return; }
  if (!strcmp(ty, "ReturnNode")) { emit_return(c, id, b, indent); return; }
  if (!strcmp(ty, "DefNode"))    { return; } /* emitted separately */

  unsupported(c, id, "statement");
}

/* Tail position: the value of this statement is the method's return value. */
static void emit_stmt_tail_inner(Compiler *c, int id, Buf *b, int indent) {
  const NodeTable *nt = c->nt;
  const char *ty = nt_type(nt, id);
  if (!ty) unsupported(c, id, "tail statement (no type)");

  if (!strcmp(ty, "IfNode"))     { emit_if(c, id, b, indent, 0, 1); return; }
  if (!strcmp(ty, "UnlessNode")) { emit_if(c, id, b, indent, 1, 1); return; }
  if (!strcmp(ty, "ReturnNode")) { emit_return(c, id, b, indent); return; }

  /* statements that don't produce a usable tail value: emit normally;
     the trailing default return covers the method's value. */
  if (!strcmp(ty, "LocalVariableWriteNode") ||
      !strcmp(ty, "LocalVariableOperatorWriteNode") ||
      !strcmp(ty, "WhileNode") || !strcmp(ty, "UntilNode") ||
      (!strcmp(ty, "CallNode") && nt_ref(nt, id, "receiver") < 0 &&
       emit_output_call(c, id, b, indent))) {
    if (strcmp(ty, "CallNode") != 0) emit_stmt(c, id, b, indent);
    return;
  }

  /* a value expression: return it */
  emit_indent(b, indent);
  buf_puts(b, "return ");
  emit_expr(c, id, b);
  buf_puts(b, ";\n");
}

static void emit_stmts(Compiler *c, int id, Buf *b, int indent) {
  if (id < 0) return;
  const NodeTable *nt = c->nt;
  const char *ty = nt_type(nt, id);
  if (ty && !strcmp(ty, "StatementsNode")) {
    int n = 0;
    const int *body = nt_arr(nt, id, "body", &n);
    for (int k = 0; k < n; k++) emit_stmt(c, body[k], b, indent);
  } else {
    emit_stmt(c, id, b, indent);
  }
}

static void emit_stmts_tail(Compiler *c, int id, Buf *b, int indent) {
  if (id < 0) return;
  const NodeTable *nt = c->nt;
  const char *ty = nt_type(nt, id);
  if (ty && !strcmp(ty, "StatementsNode")) {
    int n = 0;
    const int *body = nt_arr(nt, id, "body", &n);
    for (int k = 0; k < n; k++) {
      if (k == n - 1) emit_stmt_tail(c, body[k], b, indent);
      else emit_stmt(c, body[k], b, indent);
    }
  } else {
    emit_stmt_tail(c, id, b, indent);
  }
}

/* ---- declarations ---- */

/* Heap-managed types need a GC root for their local slot. */
static int needs_root(TyKind t) { return t == TY_STRING || ty_is_array(t); }

static void declare_local(Buf *b, LocalVar *lv) {
  switch (lv->type) {
    case TY_INT:    buf_printf(b, "    mrb_int lv_%s = 0;\n", lv->name); break;
    case TY_FLOAT:  buf_printf(b, "    mrb_float lv_%s = 0.0;\n", lv->name); break;
    case TY_BOOL:   buf_printf(b, "    mrb_bool lv_%s = 0;\n", lv->name); break;
    case TY_STRING:
      buf_printf(b, "    const char * lv_%s = (&(\"\\xff\")[1]);\n", lv->name);
      buf_printf(b, "    SP_GC_ROOT(lv_%s);\n", lv->name);
      break;
    case TY_INT_ARRAY:
    case TY_FLOAT_ARRAY:
    case TY_STR_ARRAY:
      buf_printf(b, "    %s lv_%s = NULL;\n", c_type_name(lv->type), lv->name);
      buf_printf(b, "    SP_GC_ROOT(lv_%s);\n", lv->name);
      break;
    default:
      fprintf(stderr, "spinelc: local '%s' has unsupported type %s\n",
              lv->name, ty_name(lv->type));
      exit(1);
  }
}

/* Declare a scope's locals. Params are already C function parameters, so
   they only need a GC root; body locals get a full declaration. */
static void emit_scope_decls(Scope *s, Buf *b) {
  for (int i = 0; i < s->nlocals; i++) {
    LocalVar *lv = &s->locals[i];
    if (lv->is_param) {
      if (needs_root(lv->type)) buf_printf(b, "    SP_GC_ROOT(lv_%s);\n", lv->name);
    } else {
      declare_local(b, lv);
    }
  }
}

/* ---- methods ---- */

static int method_is_void(Scope *s) { return !is_scalar_ret(s->ret); }

static void emit_method_signature(Compiler *c, Scope *s, Buf *b) {
  const char *rt = method_is_void(s) ? "void" : c_type_name(s->ret);
  buf_printf(b, "static %s sp_%s(", rt, s->name);
  if (s->nparams == 0) {
    buf_puts(b, "void");
  } else {
    for (int i = 0; i < s->nparams; i++) {
      if (i) buf_puts(b, ", ");
      LocalVar *p = scope_local(s, s->pnames[i]);
      const char *ct = p ? c_type_name(p->type) : NULL;
      if (!ct) {
        fprintf(stderr, "spinelc: method '%s' param '%s' has unsupported type %s\n",
                s->name, s->pnames[i], ty_name(p ? p->type : TY_UNKNOWN));
        exit(1);
      }
      buf_printf(b, "%s lv_%s", ct, s->pnames[i]);
    }
  }
  buf_puts(b, ")");
}

static void emit_method(Compiler *c, Scope *s, Buf *b) {
  emit_method_signature(c, s, b);
  buf_puts(b, " {\n");
  buf_puts(b, "    SP_GC_SAVE();\n");
  emit_scope_decls(s, b);
  if (method_is_void(s)) {
    emit_stmts(c, s->body, b, 1);
  } else {
    emit_stmts_tail(c, s->body, b, 1);
    buf_printf(b, "  return %s;\n", default_value(s->ret));
  }
  buf_puts(b, "}\n");
}

/* ---- top level ---- */

char *codegen_program(const NodeTable *nt) {
  Compiler *c = comp_new(nt);
  analyze_program(c);

  Buf b; memset(&b, 0, sizeof b);
  buf_puts(&b, "/* Generated by Spinel AOT compiler */\n");
  buf_puts(&b, "#include \"sp_runtime.h\"\n");
  buf_puts(&b, "static const char *sp_sym_to_s(sp_sym id){(void)id;return \"\";}\n\n");
  buf_puts(&b, "static const char *sp_class_to_s(sp_Class c){(void)c;return \"\";}\n\n\n");

  /* method prototypes then definitions (scope 0 is top-level) */
  for (int s = 1; s < c->nscopes; s++) { emit_method_signature(c, &c->scopes[s], &b); buf_puts(&b, ";\n"); }
  if (c->nscopes > 1) buf_puts(&b, "\n");
  for (int s = 1; s < c->nscopes; s++) emit_method(c, &c->scopes[s], &b);

  buf_puts(&b, "int main(int argc,char**argv){\n");
  buf_puts(&b, "    SP_GC_SAVE();\n");
  emit_scope_decls(&c->scopes[0], &b);
  buf_puts(&b, "\n");
  emit_stmts(c, c->scopes[0].body, &b, 1);
  buf_puts(&b, "  return 0;\n}\n");

  comp_free(c);
  return b.p;
}
