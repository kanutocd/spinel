# Regression: `a, b = self.method(...)` where `method` returns a typed
# array other than int_array. compile_multi_write previously emitted
# `sp_IntArray *tmp = call(); sp_IntArray_get(tmp, k)` for every
# array-returning RHS that wasn't poly_array / poly. A method
# returning e.g. obj_<C>_ptr_array therefore type-mismatched at the
# C-temp declaration and dispatched the wrong getter.
#
# Each shape below has the call return a typed array and destructures
# with two locals; the values must round-trip cleanly.

class Mat
  attr_accessor :v
  def initialize(v); @v = v; end
end

class N
  def two_mats
    [Mat.new(11), Mat.new(22)]
  end
  def two_floats
    [1.5, 2.5]
  end
  def two_strs
    ["a", "b"]
  end

  def go_mats
    a, b = self.two_mats
    a.v + b.v
  end
  def go_floats
    a, b = self.two_floats
    a + b
  end
  def go_strs
    a, b = self.two_strs
    a + b
  end
end

n = N.new
puts n.go_mats     # 33
puts n.go_floats   # 4.0
puts n.go_strs     # "ab"
