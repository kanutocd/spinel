# Followup to PR #347: when a poly RHS is auto-unboxed into an
# int local slot, the slot's tracked type must stay int so a
# *subsequent* poly RHS write also unboxes. Without this, the
# first auto-unbox-write widened the slot's tracked type to
# poly; the second poly write then emitted `lv = <sp_RbVal>;`
# (no unbox) into the still-int C declaration, failing the C
# compile (`incompatible types when assigning to type 'mrb_int'
# from type 'sp_RbVal'`).
#
# Reproduces optcarrot's chained `pixel0 = sprite[N]` writes:
# the function-level slot stays mrb_int (set by an earlier
# int_array read), but later sprite[N] writes are poly.

class C
  def make_int_arr; @arr = [10, 20, 30]; end
  def make_poly_arr
    @arr = [nil] * 3
    @arr[0] = 100
    @arr[1] = 200
    @arr[2] = 300
  end
  def at(i); @arr[i]; end
end

c = C.new

# Two consecutive poly RHS writes into the same int slot. Both
# must auto-unbox; without the fix, the second one fails C compile.
c.make_int_arr
val = c.at(0)            # int RHS, val slot established as int
puts val

c.make_poly_arr
val = c.at(0)            # 1st poly RHS — already worked in PR #347
puts val

val = c.at(2)            # 2nd poly RHS — must also unbox; failed pre-fix
puts val
