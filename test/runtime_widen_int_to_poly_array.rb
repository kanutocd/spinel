# `compile_bracket_assign`'s `rt == "poly"` branch dispatches
# `@arr[i] = v` by runtime cls_id, but when the slot's runtime
# storage is IntArray and the rhs carries a non-int payload (a
# typed pointer / box whose cls_id we'd lose if cast to int),
# the write silently truncates to int.
#
# This patch widens the storage at runtime: allocate a fresh
# PolyArray, copy each existing IntArray element as sp_box_int,
# set the new slot, and reassign the slot expression to hold the
# new PolyArray.

class C
  def init_arr_widen
    @arr = [10, 20, 30]   # int_array storage
    @arr[1] = "string!"   # heterogeneous → triggers runtime widen
  end
  def init_str
    @arr = "scalar"       # forces slot type to widen to poly
  end
  def at(i); @arr[i]; end
end

c = C.new
c.init_arr_widen
puts c.at(0)               # 10 (preserved as int)
puts c.at(1)               # "string!" (recovered via widen)
puts c.at(2)               # 30
