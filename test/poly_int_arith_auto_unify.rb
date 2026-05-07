# Auto-unify int receiver + poly argument in arithmetic. Common
# case: `addr + arr[i][j]` where the inner dispatch is a
# heterogeneous user-class+IntArray array — both arms genuinely
# return int at runtime, but spinel statically types `[]`
# dispatch as poly. Spinel previously emitted `(addr +
# <sp_RbVal>)` and the C compile failed (`invalid operands to
# binary + (have 'mrb_int' and 'sp_RbVal')`). The operator-site
# fall-through now unboxes the poly arg via .v.i, mirroring PR
# #347's LV-write semantics.

# Class that defines `[]` returning int — when stored alongside an
# IntArray in a poly_array, the outer `[]` dispatch returns poly.
class Lookup
  def [](i); i * 10 + 1; end
end

arr = [Lookup.new, [100, 200, 300]]

# arr[i] is poly (Lookup or IntArray), then `[j]` dispatches —
# every runtime arm returns int, but the static return type is
# poly. So `addr + arr[1][0]` is `int + poly` at codegen time.
addr = 7
puts(addr + arr[1][0])  # 7 + 100 = 107
puts(addr - arr[0][2])  # 7 - 21  = -14
puts(addr * arr[1][1])  # 7 * 200 = 1400
puts(arr[1][2] / 3)     # 300 / 3 = 100  (recv-poly + arg-int already worked via sp_poly_div, included for coverage)
