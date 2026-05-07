# `Array.new(N) { block }` should pick its accumulator container
# from the block's return type, not collapse to IntArray. Without
# the fix, `Array.new(N) { _x = [0]; _x.clear; _x }` (the seed-int
# idiom for an empty-but-typed inner array) emits a flat IntArray
# at the C level, then later `<<` pushes silently cast pointers
# to ints — every read returns 0.
#
# The fix mirrors compile_map_expr's range / typed-container
# branch: infer the block tail's type and emit StrArray /
# FloatArray / PtrArray<X> / PolyArray accordingly. Three call
# sites need it (infer_type, infer_ivar_init_type,
# compile_constructor_expr) so the ivar widening pipeline stays
# consistent.

class C
  def initialize
    @typed = Array.new(4) { _a = [0]; _a.clear; _a }
    @strs  = Array.new(3) { |i| "row#{i}" }
    @flts  = Array.new(3) { |i| i.to_f * 0.5 }
  end
  def push_typed(i, v); @typed[i] << v; end
  def get_typed(i, j); @typed[i][j]; end
  def get_str(i); @strs[i]; end
  def get_flt(i); @flts[i]; end
end

c = C.new
c.push_typed(0, 100)
c.push_typed(0, 200)
c.push_typed(2, 999)
puts c.get_typed(0, 0)    # 100
puts c.get_typed(0, 1)    # 200
puts c.get_typed(2, 0)    # 999
puts c.get_str(0)         # row0
puts c.get_str(2)         # row2
puts c.get_flt(0)         # 0.0
puts c.get_flt(2)         # 1.0
