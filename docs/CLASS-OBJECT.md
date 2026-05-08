# Class オブジェクト 設計メモ

`obj.class` を Ruby 互換の Class 値として扱うための設計。Module も含めた
継承ツリー対応、機能未使用時は 1 byte も emit しない条件付き出力。

## 動機

現状の Spinel は `obj.class` を未対応とし、warning + 0 を吐いていた。
optcarrot は文字列補間 (`"#<#{ self.class }>"`) で `<0>` のような壊れた
出力になる。互換性のため、Class を本物の値型として実装する。

## スコープ

### サポート対象 (初期実装)

- `obj.class` → Class 値 (組み込み型と user class 両方)
- `Klass.to_s` / `.name` / `.inspect` → 名前文字列 (`Optcarrot::NES` 形式)
- `Klass == Other` / `!=` → cls_id 比較
- `Klass < Other` / `<=` → subclass 比較
- `Klass.superclass` → 親 class
- `Klass.ancestors` → 含む module 込みの祖先 list
- `Klass.ancestors.include?(C)`
- `obj.is_a?(C)` で C が動的 (poly) のとき
- `case obj when Klass1, Klass2` (`Class#===`)
- ConstantReadNode (`Foo` を value として使う)
- Module も Class と同じ cls_id 空間に統合

### 後回し

- `Klass.instance_methods` / `.method_defined?`
- `Klass.new(*args)` (動的 instantiation)
- `Klass.allocate`
- `prepend` (現状は include のみ)
- Singleton class (`obj.singleton_class`)

## 表現

### C 側

```c
typedef struct { mrb_int cls_id; } sp_Class;
```

8 byte の値型、レジスタ渡し。`cls_id = -1` は sentinel ("class でない")。
Class と Module は同じ表現。区別は `sp_class_kinds[cls_id]`。

新 poly tag `SP_TAG_CLASS` を追加 (ancestors を PolyArray に格納するため)。

### Codegen 側

新型タグ `"class"`:

- `c_type("class") → "sp_Class"`
- 既定値: `((sp_Class){-1})`
- 値型 (`is_value_type` true)

## Global class table

統一した cls_id 空間に Class と Module が共存する。

### Built-in registration (固定 index)

| cls_id | name | kind | parent | includes |
|---|---|---|---|---|
| 0 | BasicObject | CLASS | -1 | [] |
| 1 | Object | CLASS | 0 | [Kernel] |
| 2 | Kernel | MODULE | -1 | [] |
| 3 | Comparable | MODULE | -1 | [] |
| 4 | Enumerable | MODULE | -1 | [] |
| 5 | NilClass | CLASS | 1 | [] |
| 6 | TrueClass | CLASS | 1 | [] |
| 7 | FalseClass | CLASS | 1 | [] |
| 8 | Numeric | CLASS | 1 | [Comparable] |
| 9 | Integer | CLASS | 8 | [] |
| 10 | Float | CLASS | 8 | [] |
| 11 | String | CLASS | 1 | [Comparable] |
| 12 | Symbol | CLASS | 1 | [Comparable] |
| 13 | Array | CLASS | 1 | [Enumerable] |
| 14 | Hash | CLASS | 1 | [Enumerable] |
| 15 | Range | CLASS | 1 | [Enumerable] |
| 16 | Time | CLASS | 1 | [Comparable] |
| 17 | Module | CLASS | 1 | [] |
| 18 | Class | CLASS | 17 | [] |
| 19 | Method | CLASS | 1 | [] |
| 20 | Complex | CLASS | 8 | [] |
| 21 | Proc | CLASS | 1 | [] |

User-defined class / module はこの後ろに採番される。

### `obj.class` の cls_id 解決

| 静的型 | 返す cls_id |
|---|---|
| `obj_<C>` (user class) | builtin_count + ci of C |
| `obj_<M>` (user module instance) — そもそもインスタンスが作られない | n/a |
| `int` | 9 (Integer) |
| `float` | 10 (Float) |
| `string` / `mutable_str` | 11 (String) |
| `symbol` | 12 (Symbol) |
| `int_array`/`str_array`/`float_array`/`poly_array`/`ptr_array<…>` | 13 (Array) |
| `*_hash` 各種 | 14 (Hash) |
| `range` | 15 (Range) |
| `time` | 16 (Time) |
| `complex` | 20 (Complex) |
| `bool` (TrueClass / FalseClass) | 6 / 7 (literal の場合) |
| `nil` | 5 (NilClass) |
| `class` (sp_Class on sp_Class) | 17 or 18 (kind による) |
| `poly` | runtime 判定: `sp_class_for_poly(<rval>)` |

## Precomputed ancestors

ancestors の MRO 計算は **codegen 時** に Ruby 側で展開し、flat 配列に焼く。
runtime は単純 lookup のみ。

### Codegen のアルゴリズム

```ruby
def compute_ancestors(i, acc = [])
  return acc if acc.include?(i)
  if @kind[i] == :module
    acc.push(i)
    @includes[i].each { |j| compute_ancestors(j, acc) }
  else
    # class
    acc.push(i)
    @includes[i].reverse_each { |j| compute_ancestors(j, acc) }
    if @parents[i] >= 0
      compute_ancestors(@parents[i], acc)
    end
  end
  acc
end
```

include 順序 (逆順) と dedup を含めて、CRuby の MRO と同じ並びを生成する。

### 出力テーブル

```c
static const mrb_int sp_class_ancestors_off[N+1] = { 0, 1, 4, 5, ... };
static const mrb_int sp_class_ancestors_flat[]   = {
  /* 0 BasicObject */ 0,
  /* 1 Object      */ 1, 2, 0,                  /* Object, Kernel, BasicObject */
  /* 2 Kernel      */ 2,
  /* 3 Comparable  */ 3,
  /* 4 Enumerable  */ 4,
  /* 5 NilClass    */ 5, 1, 2, 0,
  ...
  /* 9 Integer     */ 9, 8, 3, 1, 2, 0,         /* Integer, Numeric, Comparable, Object, Kernel, BasicObject */
  /* 13 Array      */ 13, 4, 1, 2, 0,           /* Array, Enumerable, Object, Kernel, BasicObject */
  ...
};
```

### Ruby 仕様との照合

```
Array.ancestors      => [Array, Enumerable, Object, Kernel, BasicObject]
Enumerable.ancestors => [Enumerable]
Comparable.ancestors => [Comparable]
Integer.ancestors    => [Integer, Numeric, Comparable, Object, Kernel, BasicObject]
String.ancestors     => [String, Comparable, Object, Kernel, BasicObject]
NilClass.ancestors   => [NilClass, Object, Kernel, BasicObject]
Class.ancestors      => [Class, Module, Object, Kernel, BasicObject]
```

precomputed table はちょうどこの通り展開される。

## Runtime helpers (lib/sp_runtime.h)

```c
typedef struct { mrb_int cls_id; } sp_Class;

#define SP_KIND_CLASS  1
#define SP_KIND_MODULE 2

/* Built-in cls_id 定数 */
#define SP_CLASS_BASICOBJECT 0
#define SP_CLASS_OBJECT      1
#define SP_CLASS_KERNEL      2
#define SP_CLASS_COMPARABLE  3
#define SP_CLASS_ENUMERABLE  4
#define SP_CLASS_NIL         5
#define SP_CLASS_TRUE        6
#define SP_CLASS_FALSE       7
#define SP_CLASS_NUMERIC     8
#define SP_CLASS_INTEGER     9
#define SP_CLASS_FLOAT       10
#define SP_CLASS_STRING      11
#define SP_CLASS_SYMBOL      12
#define SP_CLASS_ARRAY       13
#define SP_CLASS_HASH        14
#define SP_CLASS_RANGE       15
#define SP_CLASS_TIME        16
#define SP_CLASS_MODULE      17
#define SP_CLASS_CLASS       18
#define SP_CLASS_METHOD      19
#define SP_CLASS_COMPLEX     20
#define SP_CLASS_PROC        21

static inline const char *sp_class_to_s(sp_Class c) {
  if (c.cls_id < 0 || c.cls_id >= SP_CLASS_COUNT) return "";
  return sp_class_names[c.cls_id];
}

static inline mrb_bool sp_class_eq(sp_Class a, sp_Class b) {
  return a.cls_id == b.cls_id;
}

/* sp_Class 値の `.class` を返す: kind に応じて Class または Module を返す */
static inline sp_Class sp_class_meta(sp_Class c) {
  if (c.cls_id < 0 || c.cls_id >= SP_CLASS_COUNT) return (sp_Class){-1};
  return (sp_Class){sp_class_kinds[c.cls_id] == SP_KIND_MODULE ? SP_CLASS_MODULE : SP_CLASS_CLASS};
}

static inline sp_Class sp_class_superclass(sp_Class c) {
  if (c.cls_id < 0 || c.cls_id >= SP_CLASS_COUNT) return (sp_Class){-1};
  /* module には superclass が無い */
  if (sp_class_kinds[c.cls_id] == SP_KIND_MODULE) return (sp_Class){-1};
  return (sp_Class){sp_class_parents[c.cls_id]};
}

/* `child <= ancestor` — ancestors に ancestor が含まれるか */
static inline mrb_bool sp_class_le(sp_Class child, sp_Class ancestor) {
  if (child.cls_id < 0) return FALSE;
  mrb_int s = sp_class_ancestors_off[child.cls_id];
  mrb_int e = sp_class_ancestors_off[child.cls_id + 1];
  for (mrb_int k = s; k < e; k++) {
    if (sp_class_ancestors_flat[k] == ancestor.cls_id) return TRUE;
  }
  return FALSE;
}

/* `child < ancestor` — proper subclass (== は false) */
static inline mrb_bool sp_class_lt(sp_Class child, sp_Class ancestor) {
  if (child.cls_id == ancestor.cls_id) return FALSE;
  return sp_class_le(child, ancestor);
}

static sp_PolyArray *sp_class_ancestors_arr(sp_Class c) {
  sp_PolyArray *r = sp_PolyArray_new();
  if (c.cls_id < 0) return r;
  mrb_int s = sp_class_ancestors_off[c.cls_id];
  mrb_int e = sp_class_ancestors_off[c.cls_id + 1];
  for (mrb_int k = s; k < e; k++) {
    sp_PolyArray_push(r, sp_box_class((sp_Class){sp_class_ancestors_flat[k]}));
  }
  return r;
}

/* `Klass === obj` — obj.class が Klass の subclass-or-equal か */
static inline mrb_bool sp_class_case_match(sp_Class klass, sp_Class obj_class) {
  return sp_class_le(obj_class, klass);
}

/* poly 値の cls_id を取って sp_Class を返す runtime 関数 */
static sp_Class sp_class_for_poly(sp_RbVal v) {
  switch (v.tag) {
    case SP_TAG_NIL:    return (sp_Class){SP_CLASS_NIL};
    case SP_TAG_BOOL:   return (sp_Class){v.v.b ? SP_CLASS_TRUE : SP_CLASS_FALSE};
    case SP_TAG_INT:    return (sp_Class){SP_CLASS_INTEGER};
    case SP_TAG_FLT:    return (sp_Class){SP_CLASS_FLOAT};
    case SP_TAG_STR:    return (sp_Class){SP_CLASS_STRING};
    case SP_TAG_SYM:    return (sp_Class){SP_CLASS_SYMBOL};
    case SP_TAG_CLASS:  /* Class/Module 自身 — kind を見る */
      return sp_class_meta((sp_Class){v.v.i});
    case SP_TAG_OBJ:
      /* user class instance: cls_id (poly) を builtin offset 込みで返す */
      return (sp_Class){v.cls_id};
    default:
      return (sp_Class){-1};
  }
}
```

## 条件付き emission

無関係な program で 1 byte も emit しないように、`@needs_*` フラグで制御する。

| フラグ | 立つ条件 | emit する table |
|---|---|---|
| `@needs_class_table` | `obj.class` / class 値の登場 / `.to_s` / `.name` / ConstantReadNode を value で利用 | `sp_class_names`, `sp_class_kinds` |
| `@needs_class_parents` | `.superclass` | `sp_class_parents` |
| `@needs_class_ancestors` | `.ancestors` / 動的 `is_a?` / `case-when` Class / `<` / `<=` | `sp_class_ancestors_off`, `sp_class_ancestors_flat` |

`scan_features` (既存) を拡張して上記を AST walk で検出する。

### Reachability-based subset emission

更に細かく: 「user code から到達可能な class/module」だけを emit する
(`Object`, `BasicObject`, `Kernel` は parent として transitively 必要)。

実装は scan phase で reachable set を求め、emit 時にそのインデックスだけを
出力する。cls_id は連続な numbering である必要があるので、
re-numbering テーブルを持つ。

ただし初期実装ではフルテーブル emit で OK
(builtin 22 + user ~30 = 52 entry × 平均 6 ancestors ≒ 2.5KB)。
最適化は後回し。

## Codegen 変更点

### 1. Class index 管理

```ruby
# 初期化時に builtin を登録
@builtin_class_names    = ["BasicObject", "Object", "Kernel", ..., "Proc"]
@builtin_class_kinds    = [:class, :class, :module, ..., :class]
@builtin_class_parents  = [-1, 0, -1, ..., 1]
@builtin_class_includes = [[], [2], [], ..., []]
@builtin_class_count    = @builtin_class_names.length

# user class の cls_id は @builtin_class_count + ci
def cls_id_for_user_ci(ci)
  @builtin_class_count + ci
end

# 静的型から cls_id を解決
def cls_id_for_static_type(t)
  case t
  when "int"        then SP_CLASS_INTEGER
  when "float"      then SP_CLASS_FLOAT
  when "string", "mutable_str" then SP_CLASS_STRING
  when "symbol"     then SP_CLASS_SYMBOL
  ...
  when /^obj_(.+)$/ then cls_id_for_user_ci(find_class_idx($1))
  ...
  end
end
```

### 2. `@cls_human_names`

class collection 時に `Optcarrot::NES` 形式 (`::` 区切り) を別途記録する。

```ruby
def collect_class_with_prefix(nid, module_prefix)
  ...
  cname = ...  # "Optcarrot_NES"
  human = (module_prefix == "" ? local : human_join(module_prefix, local))
  @cls_names.push(cname)
  @cls_human_names.push(human)
  ...
end

def human_join(prefix, local)
  # prefix は "Optcarrot" 形式 (まだ underscore されていない場合)、
  # または "Optcarrot_Inner" 形式 (nest している場合) を想定。
  prefix.split("_").join("::") + "::" + local
end
```

### 3. `obj.class` の lowering

```ruby
# compile_object_method_expr 内
if mname == "class"
  cid = cls_id_for_static_type(recv_type)
  if cid >= 0
    @needs_class_table = 1
    return "((sp_Class){#{cid}})"
  end
  if recv_type == "poly"
    @needs_class_table = 1
    return "sp_class_for_poly(#{rc})"
  end
end
```

`infer_call_type` で `<recv>.class → "class"`。

### 4. `class` 受信のメソッド

```ruby
# compile_object_method_expr 内、recv_type == "class"
case mname
when "to_s", "name", "inspect"
  @needs_class_table = 1
  "sp_class_to_s(#{rc})"
when "==", "eql?"
  "sp_class_eq(#{rc}, #{compile_arg0(nid)})"
when "!="
  "(!sp_class_eq(#{rc}, #{compile_arg0(nid)}))"
when "superclass"
  @needs_class_table = 1
  @needs_class_parents = 1
  "sp_class_superclass(#{rc})"
when "ancestors"
  @needs_class_table = 1
  @needs_class_ancestors = 1
  "sp_class_ancestors_arr(#{rc})"
when "<"
  @needs_class_ancestors = 1
  "sp_class_lt(#{rc}, #{compile_arg0(nid)})"
when "<="
  @needs_class_ancestors = 1
  "sp_class_le(#{rc}, #{compile_arg0(nid)})"
when "class"
  @needs_class_table = 1
  "sp_class_meta(#{rc})"
end
```

### 5. ConstantReadNode (Class/Module 名) を value で使う

`compile_expr` で ConstantReadNode を扱う path を拡張:

```ruby
# 既存: receiver context (Foo.new など) は別 path で処理されるので、
# ここに来るのは「value 用法」のみ
if @nd_type[nid] == "ConstantReadNode"
  name = @nd_name[nid]
  cid = lookup_class_id_for_const_name(name)
  if cid >= 0
    @needs_class_table = 1
    return "((sp_Class){#{cid}})"
  end
  ...
end
```

`infer_type` も同様に: ConstantReadNode が class/module 名 → "class" 型。

### 6. `is_a?` の拡張

既存の static cls_id check はそのまま。動的 (poly) recv に対しては:

```ruby
if mname == "is_a?" && recv_type == "poly"
  @needs_class_ancestors = 1
  "sp_class_le(sp_class_for_poly(#{rc}), #{compile_arg0(nid)})"
end
```

ここで arg0 が ConstantReadNode (例: `Foo`) なら、上記の Class const-as-value
ルールで `((sp_Class){cid})` に lower される。

### 7. `case obj when Klass1, Klass2`

既存の case-when は WhenNode の condition を `===` で評価する。Spinel の現状
実装は obj_<C> に対して cls_id 比較を直接出していると思われる
(要確認)。Class const と sp_Class 値を `===` で比較する path に対応。

```ruby
# WhenNode condition compile
when_cond_type = infer_type(cond)
if when_cond_type == "class"
  # sp_class_case_match で評価
  @needs_class_ancestors = 1
  emit_when "sp_class_case_match(#{compile_expr(cond)}, sp_class_for_poly(#{subject}))"
end
```

## Phase 計画

### Phase 1 — sp_Class コア + Class entries
1 commit。Module は暫定で全部 CLASS として登録 (`is_a?(Module)` は次 phase)。

- `sp_Class` struct + `SP_TAG_CLASS` poly tag
- `@builtin_class_*` 配列を Compiler init で登録
- `@cls_human_names` tracking
- `sp_class_names` 配列 emission (条件付き)
- `obj.class` の static lowering
- `class.to_s` / `.name` / `.inspect` / `==` / `!=` / `class` (meta)
- `@needs_class_table` フラグ
- test/builtin_class_basic.rb

### Phase 2 — Constant as value + Module 区別
1 commit。

- `kind` フィールド追加 (CLASS / MODULE)
- Module を MODULE として登録
- `sp_class_kinds` 配列 emission
- ConstantReadNode (class/module 名) → `((sp_Class){cid})` lowering
- `Klass.class == Class`, `Mod.class == Module` 動作確認
- test/class_constant_as_value.rb

### Phase 3 — Precomputed ancestors + subclass / superclass
1 commit。

- `@cls_includes` を class collection 時に populate
- `compute_ancestors` Ruby 側で実装
- `sp_class_ancestors_flat` / `_off` 配列 emission (条件付き)
- `sp_class_parents` 配列 emission (条件付き)
- `class.superclass`, `class.ancestors`, `class.ancestors.include?(C)`
- `class < other` / `<=`
- 動的 `is_a?` / `case-when Klass`
- `@needs_class_parents`, `@needs_class_ancestors` フラグ
- test/class_hierarchy.rb (modules を含む)

### 各 phase の検証

- `make test` (regressions が無いこと)
- `make bootstrap` (gen2.c == gen3.c)
- `make optcarrot` (checksum 59662)

## Bootstrap risk

spinel_codegen.rb 自体が `obj.class`、`.ancestors`、`.is_a?`、`.superclass`
を使っていれば、変更で self-host が壊れる可能性がある。実装前に grep:

```bash
grep -nE "\.class\b|\.ancestors\b|\.is_a\?|\.superclass\b|\.kind_of\?" spinel_codegen.rb
```

使っていれば、その箇所も新 path を通る。bootstrap で gen2 == gen3 を逐次検証
しながら進める。

## メモリ・Binary size 見込み

機能未使用 → 0 byte。

機能フル使用 (組み込み 22 + user 30 = 52 entries の場合):

- `sp_class_names`: 52 × 8B (ptr) + ~600B (文字列実体) ≒ 1KB
- `sp_class_kinds`: 52 × 1B = 52B
- `sp_class_parents`: 52 × 8B = 416B
- `sp_class_ancestors_off`: 53 × 8B = 424B
- `sp_class_ancestors_flat`: 平均 6 entry × 52 = 312 × 8B ≒ 2.5KB

合計 ~4.5KB。LTO + dead code elimination でさらに削れる余地あり。
