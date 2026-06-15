# First-class Proc / lambda in the C rewrite — 設計と計画メモ

`proc {}` / `lambda {}` / `->(){}` を**値**として扱う(変数代入・引数渡し・戻り値・
`Proc#call`)機能を、C 書き直し(`src/analyze.c` + `src/codegen.c` → `build/spinel`)に
追加するための設計メモ。

> **対象は C 書き直しのみ。** legacy Ruby (`legacy/spinel_*.rb`) は凍結リファレンス
> (オラクル)で、ここでは触らない。出力等価性は legacy / CRuby と照合して検証する。

## 現状(C 書き直し)

C 版はブロックを**コンパイル時インライン展開**のみで扱う(M3 の yield 機構):

- `g_block_id` / `g_block_param_name` / `emit_block_invoke` (`codegen.c:2059`) /
  `emit_inline_call_x` (`codegen.c:1943`) — `arr.map{}`、`yield`、`def m(&b); b.call; end`
  はすべて呼び出し位置に body を展開する。
- 第一級 Proc は**皆無**: `TY_PROC` 型タグ無し(`types.h:11-35`)、proc/lambda/`->` の
  型推論無し(`analyze.c` infer_uncached/infer_call に該当なし)、closure/static-fn を
  出力する仕組み無し(codegen に `g_pre` 以外のバッファ無し)、`TY_PROC` の dispatch 無し。
- ランタイム `lib/sp_runtime.h` には `sp_Proc`(`fn/cap/cap_scan/arity/lambda_p/
  param_count/param_kinds/param_names`、`:4158`)と `sp_proc_new_meta` / `sp_proc_call` /
  `sp_proc_arity` / `sp_proc_lambda_p` / `sp_proc_parameters` / `sp_proc_compose` が**既にある**。
  codegen が使っていないだけ。

インライン機構はそのまま残す。第一級 Proc は直交した別経路 — メソッドを**脱出して**
変数に入り後で呼ばれる proc を扱う。

## AST 形状(実測)

- `proc { |x| ... }` = `CallNode{name:"proc", receiver:-1, block:BlockNode}`。
  `lambda { ... }` も同形(name:"lambda")。`Proc.new { }` は
  `CallNode{name:"new", receiver:ConstantRead(Proc), block:BlockNode}`。
- `BlockNode{parameters: BlockParametersNode{parameters: ParametersNode{requireds:[RequiredParameterNode{name}]}}, body: StatementsNode}`。
- `->(x){ ... }` = `LambdaNode{parameters: BlockParametersNode..., body: StatementsNode}`。
- `f.call(a)` = `CallNode{name:"call", receiver: <proc expr>, arguments:[a]}`。
  `f.(a)` は name:"()"、`f[a]` は name:"[]"。

## 表現

### 型タグ

`types.h` の `TyKind` に **`TY_PROC`** を追加(`ty_name` → `"proc"`)。lambda/proc の区別は
ランタイムの `lambda_p` フラグで持ち、型は単一 `TY_PROC`(`静的型を優先`しつつ過剰分割を避ける)。

proc は param 型と**戻り値型**のメタが要る。型システムは単純スカラ enum なので、
proc を生成するノード(BlockNode / LambdaNode の id)→ シグネチャの**側テーブル**を
`Compiler` に持つ:

```c
typedef struct { int create_node; TyKind ret; TyKind *ptypes; int nparams; int lambda_p; } ProcSig;
```

`.call` の戻り値型は、proc 値の出所ノードから引く。出所が辿れない場合(メソッド戻り値・
poly 経由)は戻り値を `TY_POLY`(boxed)にフォールバック。

### C 表現と ABI

- `TY_PROC` → C 型 `sp_Proc *`(`emit_ctype` に追加)。
- 呼び出し: `sp_proc_call(p, (mrb_int[16]){ a0, a1, ... })`。引数は `mrb_int` に laundering
  (`(mrb_int)(uintptr_t)` でポインタ、bigint は unbox)。戻り値 `mrb_int` を proc の
  記録された戻り値型へ unbox(int はそのまま、ポインタ系は `(T)(uintptr_t)`、poly は box)。

### proc リテラルの lowering

各 `proc{}`/`lambda{}`/`->`/`Proc.new{}` に対し:

1. **static C 関数**を deferred バッファ `g_procs` に出力:
   `static mrb_int _proc_N(void *_cap, mrb_int *args) { <block params from args[i]>; <body>; return <last>; }`
   body は既存 `emit_stmts`/`emit_expr` を block scope (`c->nscope[block]`)で再利用。
2. **capture 構造体**(自由変数がある場合):`typedef struct { <T> *v; ... } _proc_cap_N;` と
   GC scan 関数。`_cap` から各自由変数を読む。
3. 生成式は `sp_proc_new_meta((void*)_proc_N, <cap or NULL>, <scan or NULL>, arity, lambda_p, nparams, kinds, names)`。

`g_procs` は `codegen_program` でメソッド定義群と同じ段(プロトタイプは前方宣言)で flush。

## 作業スライス(test-driven、垂直スライス)

`build/test-results/proc*.ok`(`proc` / `proc_closure` / `proc_arg_object`)が ERR。
これらを段階的に green にする。

1. **Slice 1 — capture 無し proc、`.call` で int 戻り(end-to-end)。**
   `sq = proc { |x| x * x }; puts sq.call(5)`。`TY_PROC` 追加、`emit_ctype`、`g_procs`、
   capture 無しの static fn 出力、proc-sig 側テーブル(ret 型)、`infer` で proc CallNode→
   `TY_PROC`、`.call` on `TY_PROC`→`sp_proc_call` + int 戻り。検証して commit。
2. **Slice 2 — `lambda {}` と `->(){}`(LambdaNode)。** lambda_p フラグ、`.()`/`[]` 別名。
3. **Slice 3 — proc を引数/戻り値として渡す。** param 型/戻り値型に `TY_PROC` が乗ることを確認
   (`def apply(f, x); f.call(x); end`)。`proc_arg_object` 系。
4. **Slice 4 — closure(自由変数キャプチャ)。** capture 構造体 + GC scan。
   `def mk(n); proc { |x| x + n }; end`。`proc_closure`。最難関、GC 落とし穴注意。
5. **Slice 5 — 戻り値が int 以外**(string/array/poly)、nested proc-returning-proc、
   `arity`/`lambda?`/`parameters`、`<<`/`>>`/`curry`、poly 格納時の `.call`。長い尾。

## 検証

- 各スライス後: `build/spinel` で対象 .rb を直接コンパイル+実行し CRuby/legacy と出力一致を確認。
  `cc -Werror` で生成 C をビルド(ハーネスと同条件)。
- `make test`(C 版)で proc*.ok が green に変わり、**他テストの pass 数が減らない**ことを確認
  (`rm -rf build/test-results/` してから)。680 error ベースラインは漸減が指標。
- GC: capture と `mrb_int[]` laundering は GC 不可視。アキュムレータ/受信側/proc 値を rooting。
- `make optcarrot` / `make bench` は proc が乗ってから(現状 C 版は未到達)。

## メモ

- インライン経路(`emit_block_invoke` / `emit_inline_call_x`)は**変更しない**。第一級 Proc は別経路。
- `&proc値` を builtin iterator(`map` 等)へ渡す経路(legacy で言う Bug A)は Slice 5 で。
  C 版の iterator もインライン block 前提なので、proc 値 forwarding は per-element `sp_proc_call`
  ループを別途出す。
