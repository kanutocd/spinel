/* In-memory AST node table for the C Spinel compiler.
 *
 * Mirrors the text node-table schema emitted by spinel_parse.c
 * (N/S/I/F/R/A lines): every node has a type string and a set of named
 * fields. Fields come in four flavors that match the text tags:
 *   S  string field   (e.g. CallNode "name" = "puts")
 *   I  int field      (e.g. IntegerNode "value" = 1)
 *   R  ref field      (a child node id, -1 if absent)
 *   A  array field    (a list of child node ids)
 * plus an F "content" string (floats, raw literals).
 *
 * The single-binary compiler loads this directly from the parser's text
 * output (sp_parse_file_to_text) -- no on-disk intermediate.
 */
#ifndef SPINEL_NODE_TABLE_H
#define SPINEL_NODE_TABLE_H

#include <stddef.h>

typedef struct { char *key; char *val; size_t val_len; } SpStrField;
typedef struct { char *key; long long val; }    SpIntField;
typedef struct { char *key; int ref; }          SpRefField;
typedef struct { char *key; int *ids; int n; }  SpArrField;

typedef struct {
  char *type;          /* node type string ("CallNode"), NULL if unset */
  char *content;       /* F content, NULL if none */
  SpStrField *s; int ns, cs;
  SpIntField *i; int ni, ci;
  SpRefField *r; int nr, cr;
  SpArrField *a; int na, ca;
} SpNode;

typedef struct {
  SpNode *nodes;
  int count;           /* number of allocated node slots */
  int root_id;
  char *source_file;   /* SOURCE_FILE path (unescaped), NULL if none */
} NodeTable;

/* Build a node table from the parser's text AST (NUL-terminated). The
   buffer is consumed read-only; the table owns its own copies. Returns
   NULL on allocation failure. */
NodeTable *nt_load_text(const char *text);

void nt_free(NodeTable *nt);

/* Deep-clone the subtree rooted at `root`; returns the new root id (or -1).
   Appends nodes and grows nt->count -- parallel per-node arrays must be
   resized to match afterward. */
int nt_clone_subtree(NodeTable *nt, int root);

/* Accessors. id must be in [0, nt->count). Out-of-range ids return the
   given defaults so callers can walk freely without bounds checks. */
const char *nt_type(const NodeTable *nt, int id);          /* NULL if unset */
const char *nt_str(const NodeTable *nt, int id, const char *key);   /* NULL */
size_t      nt_str_len(const NodeTable *nt, int id, const char *key); /* 0 if absent */
long long   nt_int(const NodeTable *nt, int id, const char *key, long long dflt);
int         nt_ref(const NodeTable *nt, int id, const char *key);   /* -1 */
const int  *nt_arr(const NodeTable *nt, int id, const char *key, int *out_n); /* NULL,0 */
const char *nt_content(const NodeTable *nt, int id);       /* NULL */

/* Generic child iteration (for structural walks that don't know field
   names). Ref fields and array-field elements are the node's children. */
int        nt_num_refs(const NodeTable *nt, int id);
int        nt_ref_at(const NodeTable *nt, int id, int i);   /* ref value, may be -1 */
int        nt_num_arrs(const NodeTable *nt, int id);
const int *nt_arr_at(const NodeTable *nt, int id, int i, int *out_n);

#endif
