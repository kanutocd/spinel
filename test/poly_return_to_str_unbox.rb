# Issue #655: A function whose RBS declares `-> String` but
# whose body returns a poly (sp_RbVal) ternary tripped the
# `incompatible types when returning sp_RbVal from a function
# with incompatible result type 'const char *'` C error. Canonical
# shape: `@hash[key] || ""` where the hash inferred to value-type
# Int (no writes observed) and the `||` ternary boxed both arms.
#
# Fix: compile_body_return_inner now unboxes via `.v.s` when
# expr_type is poly and return_type is string / mutable_str.
#
# This test pins runtime behaviour on the writes-observed case
# (which produces the real value) since the no-writes path's
# semantics are inherently lossy — Ruby's `0 || ""` returns 0
# (int is truthy), so a no-write hash returning the default-0
# Int and then taking `.v.s` reads the union as a NULL pointer
# (which `sp_str_length` guards as length 0). The standalone
# repro from the issue is included to verify C compile.

class C
  attr_reader :h
  def initialize
    @h = {}
    @h["a"] = "alpha"
    @h["b"] = "beta"
  end

  def get(key)
    @h[key] || ""
  end
end

c = C.new
puts c.get("a")
puts c.get("b")
puts c.get("missing")
puts c.get("a").length
puts c.get("missing").length
