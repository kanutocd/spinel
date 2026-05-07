# Issue #314 follow-up: a class method whose return type was
# inferred as `obj_<C>` (because every explicit return path
# produced a value of that class) lowered a bare `return` to
# `return self;` — but class methods have no `self` C param, so
# gcc complained `'self' undeclared`.
#
# Fix: thread a `@current_method_has_self` flag through the
# instance-method / class-method / top-level / constructor-
# synthesis emit paths. compile_return_stmt's bare-return-with-
# obj_<C>-return path emits `return self;` only when has_self=1,
# otherwise `return c_return_default(...);` (which knows about
# value vs pointer object types).
#
# Companion to b9d6303 (#337) which added the obj_<C> branch for
# constructor synthesis.
#
# Surfaced via Roundhouse's `InMemoryAdapter.update` — a module
# class method whose return type was inferred as obj_HWIA via
# the `attrs.each` last-expression, with an early `return if
# row.nil?` lowering to broken `return self;`.

class Holder
  attr_reader :id
  def initialize(id)
    @id = id
  end

  def self.maybe(id)
    if id < 0
      return       # ← bare return; bug emitted `return self;`
    end
    Holder.new(id)
  end
end

# Pushing into a [Holder] array forces Holder out of the value-type
# bucket so `Holder.maybe` returns `sp_Holder *` (pointer) and the
# bare-return shape exercises the pointer fallback.
holders = [Holder.new(0)]

a = Holder.maybe(42)
holders << a
puts a.id                 # 42

b = Holder.maybe(-1)
puts b.nil?               # true
