# #520. `Array#pop` on a nested integer array (Array<Array<Int>>,
# spinel-side `int_array_ptr_array`) used to fall through to the
# unresolved-call warning and emit 0 — the array stayed intact.
# The same gap existed for any `<X>_ptr_array` element type; only
# the IntArray / StrArray / FloatArray / SymArray flavors had a
# direct `_pop` runtime helper.
#
# Fix: new sp_PtrArray_pop runtime helper (returns NULL on empty,
# matching CRuby's nil) plus a dispatch arm in the
# is_ptr_array_type recv_type branch.

a = [[1, 2]]
puts "before pop: #{a.inspect}"
a.pop
puts "after  pop: #{a.inspect}"
a.push([3, 4])
puts "after push: #{a.inspect}"

# Seed-and-pop idiom: array typed as Array<String> via the seed,
# then drained and used as an accumulator.
b = ["seed"]
b.pop
b.push("real")
b.push("data")
puts b.inspect

# Multiple pops drain the array.
c = [[10], [20], [30]]
c.pop
c.pop
puts c.length
