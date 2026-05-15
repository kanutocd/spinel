# Partial fix for #521. In CRuby `0 == nil` is false -- only nil
# equals nil. Spinel used to emit `(lc op rc)` for `int == nil`,
# where `rc` was "0" (compile_expr of NilNode); since unboxed ints
# share the C representation with the nil sentinel, this conflated
# stored 0 with nil and made `0 == nil` return true.
#
# Fix: compile_eq has explicit value-type-vs-nil arms that
# constant-fold to FALSE (or TRUE for `!=`). This does NOT solve
# the deeper #521 problem -- Hash<String,Int> still returns 0 for
# missing keys -- but it does fix the categorical bug that made a
# *stored* 0 in the hash indistinguishable from "the value is
# nil." With this fix, `v != nil` reflects the static type
# honestly, so users who need to distinguish missing-vs-stored
# zero have to reach for `Hash#has_key?` / `Hash#fetch`, as
# documented in the issue comment.

# Pure int (no hash)
v = 0
puts (v == nil).inspect   # false
puts (v != nil).inspect   # true

w = 5
puts (w == nil).inspect   # false
puts (w != nil).inspect   # true

# Float / bool same.
f = 0.0
puts (f == nil).inspect   # false
puts (f != nil).inspect   # true

b = false
puts (b == nil).inspect   # false

# Hash<String,Int> stored 0 case now reports != nil correctly.
h = {}
h["x"] = 0
h["y"] = 5
vx = h["x"]
vy = h["y"]
puts (vx == nil).inspect  # false (was true)
puts (vx != nil).inspect  # true  (was false)
puts (vy == nil).inspect  # false
puts (vy != nil).inspect  # true

# Symmetric: nil == int is also false.
puts (nil == 0).inspect   # false
puts (nil != 0).inspect   # true
