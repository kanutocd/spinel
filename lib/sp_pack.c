/*
 * sp_pack.c — Array#pack / String#unpack for Spinel
 *
 * Implements the common Perl/Ruby pack format specifiers. Built
 * as a separate translation unit and linked into libspinel_rt.a;
 * the main generated .c file (which includes sp_runtime.h with
 * its static GC state) provides a small set of extern shims
 * (sp_ext_*) so this file can hand back GC-managed PolyArrays
 * and strings without dragging the entire runtime header into a
 * second TU.
 *
 * Supported specifiers (initial):
 *   C / c   unsigned / signed 8-bit
 *   n / N   unsigned 16 / 32-bit big-endian
 *   v / V   unsigned 16 / 32-bit little-endian
 *   s / S   signed / unsigned 16-bit native
 *   l / L   signed / unsigned 32-bit native
 *   q / Q   signed / unsigned 64-bit native
 *   a       binary string (NUL-padded on pack)
 *   A       text string (space-padded on pack, space-trimmed on unpack)
 *   Z       NUL-terminated string
 *   x       null byte
 *
 * Counts:  `<spec>N` packs N items; `<spec>*` consumes all remaining.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

/* mruby_shim has the canonical mrb_int / mrb_bool / mrb_float
   typedefs the rest of the runtime uses. Pulling it in (rather
   than redeclaring) keeps this file in sync with sp_runtime.h. */
#include "mruby_shim.h"
typedef mrb_int sp_sym;

/* sp_RbVal mirrors the layout in sp_runtime.h. */
#define SP_TAG_INT  0
#define SP_TAG_STR  1
#define SP_TAG_FLT  2
#define SP_TAG_BOOL 3
#define SP_TAG_NIL  4
#define SP_TAG_OBJ  5
#define SP_TAG_SYM  6

typedef struct {
  int     tag;
  int     cls_id;
  union {
    mrb_int      i;
    const char  *s;
    mrb_float    f;
    mrb_bool     b;
    void        *p;
  } v;
} sp_RbVal;

typedef struct sp_PolyArray sp_PolyArray;
typedef struct {
  mrb_int *data;
  mrb_int  start;
  mrb_int  len;
  mrb_int  cap;
} sp_IntArray;

/* Extern shims supplied by the main file (sp_runtime.h). */
extern sp_PolyArray *sp_ext_poly_array_new(void);
extern void          sp_ext_poly_array_push_int(sp_PolyArray *a, int64_t v);
extern void          sp_ext_poly_array_push_str(sp_PolyArray *a, const char *s);
extern char         *sp_ext_str_alloc(size_t n);   /* GC-tracked, NUL-terminated */
extern void          sp_ext_str_set_len(char *s, size_t n);
extern const char   *sp_ext_str_empty(void);
extern size_t        sp_ext_str_byte_len(const char *s);

/* ---------- Helpers ---------- */

static void pk_append(char **buf, size_t *len, size_t *cap, const char *src, size_t n) {
  if (*len + n + 1 > *cap) {
    size_t nc = (*len + n + 1) * 2;
    char *nb = (char *)realloc(*buf, nc);
    if (!nb) { perror("realloc"); exit(1); }
    *buf = nb;
    *cap = nc;
  }
  memcpy(*buf + *len, src, n);
  *len += n;
}

/* Encode codepoint `v` as UTF-8 (the `U` directive) into out[0..5].
   Mirrors CRuby's permissive scheme: up to 6 bytes for values through
   0x7FFFFFFF. Negative / out-of-range values encode nothing (CRuby
   raises RangeError; spinel has no exception path here). Returns the
   byte count written. */
static int pk_utf8(unsigned char *out, int64_t v) {
  if (v < 0) return 0;
  uint64_t uv = (uint64_t)v;
  if (uv <= 0x7F) {
    out[0] = (unsigned char)uv;
    return 1;
  }
  if (uv <= 0x7FF) {
    out[0] = (unsigned char)(0xC0 | (uv >> 6));
    out[1] = (unsigned char)(0x80 | (uv & 0x3F));
    return 2;
  }
  if (uv <= 0xFFFF) {
    out[0] = (unsigned char)(0xE0 | (uv >> 12));
    out[1] = (unsigned char)(0x80 | ((uv >> 6) & 0x3F));
    out[2] = (unsigned char)(0x80 | (uv & 0x3F));
    return 3;
  }
  if (uv <= 0x1FFFFF) {
    out[0] = (unsigned char)(0xF0 | (uv >> 18));
    out[1] = (unsigned char)(0x80 | ((uv >> 12) & 0x3F));
    out[2] = (unsigned char)(0x80 | ((uv >> 6) & 0x3F));
    out[3] = (unsigned char)(0x80 | (uv & 0x3F));
    return 4;
  }
  if (uv <= 0x3FFFFFF) {
    out[0] = (unsigned char)(0xF8 | (uv >> 24));
    out[1] = (unsigned char)(0x80 | ((uv >> 18) & 0x3F));
    out[2] = (unsigned char)(0x80 | ((uv >> 12) & 0x3F));
    out[3] = (unsigned char)(0x80 | ((uv >> 6) & 0x3F));
    out[4] = (unsigned char)(0x80 | (uv & 0x3F));
    return 5;
  }
  if (uv <= 0x7FFFFFFF) {
    out[0] = (unsigned char)(0xFC | (uv >> 30));
    out[1] = (unsigned char)(0x80 | ((uv >> 24) & 0x3F));
    out[2] = (unsigned char)(0x80 | ((uv >> 18) & 0x3F));
    out[3] = (unsigned char)(0x80 | ((uv >> 12) & 0x3F));
    out[4] = (unsigned char)(0x80 | ((uv >> 6) & 0x3F));
    out[5] = (unsigned char)(0x80 | (uv & 0x3F));
    return 6;
  }
  return 0;
}

static int64_t pk_parse_count(const char **pp) {
  const char *p = *pp;
  if (*p == '*') { *pp = p + 1; return -1; }
  if (*p < '0' || *p > '9') return 1;
  int64_t n = 0;
  while (*p >= '0' && *p <= '9') { n = n * 10 + (*p - '0'); p++; }
  *pp = p;
  return n;
}

static int64_t pk_poly_to_int(sp_RbVal v) {
  switch (v.tag) {
    case SP_TAG_INT:  return v.v.i;
    case SP_TAG_BOOL: return v.v.i ? 1 : 0;
    case SP_TAG_FLT:  return (int64_t)v.v.f;
    case SP_TAG_STR:  return v.v.s ? strtoll(v.v.s, NULL, 0) : 0;
    case SP_TAG_NIL:  return 0;
    default:          return 0;
  }
}

static const char *pk_poly_to_str(sp_RbVal v) {
  switch (v.tag) {
    case SP_TAG_STR: return v.v.s ? v.v.s : "";
    case SP_TAG_NIL: return "";
    default:         return "";
  }
}

/* PolyArray layout — must match sp_runtime.h. We only need
   `data` and `len` for read access. */
struct sp_PolyArray {
  sp_RbVal *data;
  mrb_int   len;
  mrb_int   cap;
};

/* ---------- Pack entry points ---------- */

const char *sp_IntArray_pack(sp_IntArray *arr, const char *fmt) {
  if (!arr || !fmt) return sp_ext_str_empty();
  size_t cap = 64;
  char *buf = (char *)malloc(cap);
  if (!buf) { perror("malloc"); exit(1); }
  size_t len = 0;
  mrb_int idx = 0;
  const char *p = fmt;
  while (*p) {
    char spec = *p++;
    if (spec == ' ' || spec == '\t' || spec == '\n') continue;
    int64_t count = pk_parse_count(&p);
    if (count < 0) count = arr->len - idx;
    if (count < 0) count = 0;
    for (int64_t k = 0; k < count; k++) {
      int64_t v = (idx < arr->len) ? arr->data[arr->start + idx] : 0;
      idx++;
      char tmp[8];
      switch (spec) {
        case 'C': case 'c':
          tmp[0] = (char)(v & 0xff);
          pk_append(&buf, &len, &cap, tmp, 1);
          break;
        case 'n':
          tmp[0] = (char)((v >> 8) & 0xff); tmp[1] = (char)(v & 0xff);
          pk_append(&buf, &len, &cap, tmp, 2);
          break;
        case 'N':
          tmp[0] = (char)((v >> 24) & 0xff); tmp[1] = (char)((v >> 16) & 0xff);
          tmp[2] = (char)((v >> 8) & 0xff);  tmp[3] = (char)(v & 0xff);
          pk_append(&buf, &len, &cap, tmp, 4);
          break;
        case 'v':
          tmp[0] = (char)(v & 0xff); tmp[1] = (char)((v >> 8) & 0xff);
          pk_append(&buf, &len, &cap, tmp, 2);
          break;
        case 'V':
          tmp[0] = (char)(v & 0xff);        tmp[1] = (char)((v >> 8) & 0xff);
          tmp[2] = (char)((v >> 16) & 0xff); tmp[3] = (char)((v >> 24) & 0xff);
          pk_append(&buf, &len, &cap, tmp, 4);
          break;
        case 's': case 'S':
          memcpy(tmp, &v, 2);
          pk_append(&buf, &len, &cap, tmp, 2);
          break;
        case 'l': case 'L':
          memcpy(tmp, &v, 4);
          pk_append(&buf, &len, &cap, tmp, 4);
          break;
        case 'q': case 'Q':
          memcpy(tmp, &v, 8);
          pk_append(&buf, &len, &cap, tmp, 8);
          break;
        case 'x':
          tmp[0] = 0;
          pk_append(&buf, &len, &cap, tmp, 1);
          idx--;
          break;
        case 'U': {
          unsigned char ub[6];
          int ulen = pk_utf8(ub, v);
          pk_append(&buf, &len, &cap, (const char *)ub, (size_t)ulen);
          break;
        }
        default:
          break;
      }
    }
  }
  /* Hand back via GC-tracked sp_str_alloc so the main file's GC
     can free the buffer. */
  char *r = sp_ext_str_alloc(len);
  memcpy(r, buf, len);
  sp_ext_str_set_len(r, len);
  free(buf);
  return r;
}

const char *sp_PolyArray_pack(sp_PolyArray *arr, const char *fmt) {
  if (!arr || !fmt) return sp_ext_str_empty();
  size_t cap = 64;
  char *buf = (char *)malloc(cap);
  if (!buf) { perror("malloc"); exit(1); }
  size_t len = 0;
  mrb_int idx = 0;
  const char *p = fmt;
  while (*p) {
    char spec = *p++;
    if (spec == ' ' || spec == '\t' || spec == '\n') continue;
    int64_t count = pk_parse_count(&p);
    if (spec == 'a' || spec == 'A' || spec == 'Z') {
      const char *s = (idx < arr->len) ? pk_poly_to_str(arr->data[idx]) : "";
      idx++;
      size_t sl = strlen(s);
      size_t want = (count < 0) ? sl : (size_t)count;
      if (spec == 'Z' && count < 0) want = sl + 1;
      size_t take = sl < want ? sl : want;
      pk_append(&buf, &len, &cap, s, take);
      if (take < want) {
        char pad = (spec == 'A') ? ' ' : 0;
        for (size_t pi = 0; pi < want - take; pi++) pk_append(&buf, &len, &cap, &pad, 1);
      }
      continue;
    }
    if (count < 0) count = arr->len - idx;
    if (count < 0) count = 0;
    for (int64_t k = 0; k < count; k++) {
      int64_t v = (idx < arr->len) ? pk_poly_to_int(arr->data[idx]) : 0;
      idx++;
      char tmp[8];
      switch (spec) {
        case 'C': case 'c':
          tmp[0] = (char)(v & 0xff);
          pk_append(&buf, &len, &cap, tmp, 1);
          break;
        case 'n':
          tmp[0] = (char)((v >> 8) & 0xff); tmp[1] = (char)(v & 0xff);
          pk_append(&buf, &len, &cap, tmp, 2);
          break;
        case 'N':
          tmp[0] = (char)((v >> 24) & 0xff); tmp[1] = (char)((v >> 16) & 0xff);
          tmp[2] = (char)((v >> 8) & 0xff);  tmp[3] = (char)(v & 0xff);
          pk_append(&buf, &len, &cap, tmp, 4);
          break;
        case 'v':
          tmp[0] = (char)(v & 0xff); tmp[1] = (char)((v >> 8) & 0xff);
          pk_append(&buf, &len, &cap, tmp, 2);
          break;
        case 'V':
          tmp[0] = (char)(v & 0xff);        tmp[1] = (char)((v >> 8) & 0xff);
          tmp[2] = (char)((v >> 16) & 0xff); tmp[3] = (char)((v >> 24) & 0xff);
          pk_append(&buf, &len, &cap, tmp, 4);
          break;
        case 's': case 'S':
          memcpy(tmp, &v, 2);
          pk_append(&buf, &len, &cap, tmp, 2);
          break;
        case 'l': case 'L':
          memcpy(tmp, &v, 4);
          pk_append(&buf, &len, &cap, tmp, 4);
          break;
        case 'q': case 'Q':
          memcpy(tmp, &v, 8);
          pk_append(&buf, &len, &cap, tmp, 8);
          break;
        case 'x':
          tmp[0] = 0;
          pk_append(&buf, &len, &cap, tmp, 1);
          idx--;
          break;
        case 'U': {
          unsigned char ub[6];
          int ulen = pk_utf8(ub, v);
          pk_append(&buf, &len, &cap, (const char *)ub, (size_t)ulen);
          break;
        }
        default:
          break;
      }
    }
  }
  char *r = sp_ext_str_alloc(len);
  memcpy(r, buf, len);
  sp_ext_str_set_len(r, len);
  free(buf);
  return r;
}

/* ---------- Unpack entry point ---------- */

sp_PolyArray *sp_str_unpack(const char *str, const char *fmt) {
  sp_PolyArray *out = sp_ext_poly_array_new();
  if (!str || !fmt) return out;
  /* sp_ext_str_byte_len honors the heap-string header so embedded
     NULs (binary data) don't truncate the source. */
  size_t slen = sp_ext_str_byte_len(str);
  size_t off = 0;
  const char *p = fmt;
  while (*p) {
    char spec = *p++;
    if (spec == ' ' || spec == '\t' || spec == '\n') continue;
    int64_t count = pk_parse_count(&p);
    size_t fsize = 0;
    switch (spec) {
      case 'C': case 'c': case 'x': fsize = 1; break;
      case 'n': case 'v': case 's': case 'S': fsize = 2; break;
      case 'N': case 'V': case 'l': case 'L': fsize = 4; break;
      case 'q': case 'Q': fsize = 8; break;
      default: fsize = 0; break;
    }
    if (spec == 'a' || spec == 'A' || spec == 'Z') {
      size_t take;
      if (count < 0) {
        take = slen - off;
      }
else {
        take = (size_t)count;
        if (off + take > slen) take = slen - off;
      }
      const char *src = str + off;
      if (spec == 'Z' && count < 0) {
        size_t z = 0;
        while (off + z < slen && src[z]) z++;
        char *s = sp_ext_str_alloc(z);
        memcpy(s, src, z); s[z] = 0; sp_ext_str_set_len(s, z);
        sp_ext_poly_array_push_str(out, s);
        off += z;
        if (off < slen && str[off] == 0) off++;
      }
else {
        char *s = sp_ext_str_alloc(take);
        memcpy(s, src, take); s[take] = 0;
        size_t real = take;
        if (spec == 'A') {
          while (real > 0 && (s[real - 1] == ' ' || s[real - 1] == 0)) real--;
          s[real] = 0;
        }
else if (spec == 'Z') {
          size_t z = 0;
          while (z < take && s[z]) z++;
          s[z] = 0;
          real = z;
        }
        sp_ext_str_set_len(s, real);
        sp_ext_poly_array_push_str(out, s);
        off += take;
      }
      continue;
    }
    if (fsize == 0) continue;
    if (count < 0) count = (slen - off) / fsize;
    for (int64_t k = 0; k < count; k++) {
      if (off + fsize > slen) break;
      int64_t v = 0;
      const unsigned char *u = (const unsigned char *)(str + off);
      switch (spec) {
        case 'C': v = u[0]; break;
        case 'c': v = (int8_t)u[0]; break;
        case 'n': v = ((int64_t)u[0] << 8) | u[1]; break;
        case 'N': v = ((int64_t)u[0] << 24) | ((int64_t)u[1] << 16) | ((int64_t)u[2] << 8) | u[3]; break;
        case 'v': v = ((int64_t)u[1] << 8) | u[0]; break;
        case 'V': v = ((int64_t)u[3] << 24) | ((int64_t)u[2] << 16) | ((int64_t)u[1] << 8) | u[0]; break;
        case 's': { int16_t s16; memcpy(&s16, u, 2); v = s16; } break;
        case 'S': { uint16_t s16; memcpy(&s16, u, 2); v = s16; } break;
        case 'l': { int32_t s32; memcpy(&s32, u, 4); v = s32; } break;
        case 'L': { uint32_t s32; memcpy(&s32, u, 4); v = s32; } break;
        case 'q': { int64_t s64; memcpy(&s64, u, 8); v = s64; } break;
        case 'Q': { uint64_t s64; memcpy(&s64, u, 8); v = (int64_t)s64; } break;
        case 'x': break;
      }
      off += fsize;
      if (spec != 'x') sp_ext_poly_array_push_int(out, v);
    }
  }
  return out;
}
