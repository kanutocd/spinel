# Approach-2 narrowing: when `<poly>[k]` chases an `arr[i]` whose
# `arr` is a poly_array with observed elements that all return int
# from `[]` (IntArray + Method-objects), narrow the outer dispatch
# return type from poly to int. Without narrowing, the outer call
# returns sp_RbVal and downstream sites — `total + 1`, `~bits`,
# `iv += 1`, etc. — fail the C compile or cascade widen ivars to
# poly.

class Box
  def initialize
    @slots = [nil] * 4         # int_array initially
    @int_arr = [10, 20, 30, 40]
    @slots[0] = method(:double_at)   # widens via obj_Method_ptr_array
    @slots[1] = @int_arr             # then widens to poly_array
    @total = 0
  end

  def double_at(i)
    i * 2
  end

  # Direct ivar access: narrowing fires via `InstanceVariableReadNode`.
  def via_ivar(i)
    @slots[i][i]
  end

  # Local-variable alias: narrowing fires via `LocalVariableReadNode`
  # with the AST-walking fallback in `find_lv_ivar_alias_in_ast`.
  def via_local(i)
    cache = @slots
    cache[i][i]
  end

  def run
    # IntArray arm of @slots[1]: returns @int_arr[1] = 20.
    @total = via_ivar(1)
    @total += 1
    puts @total                # 21
    # Method arm of @slots[0]: returns double_at(0) = 0.
    @total = via_local(0)
    @total += 1
    puts @total                # 1
  end
end

Box.new.run
