# Issue #314 follow-up: the synthesized void
# `sp_<C>_initialize` super-chain wrapper inherits @in_gc_scope
# from the prior `sp_<C>_new` constructor emit. When that left
# @in_gc_scope at 1, declare_method_locals' `@in_gc_scope == 0`
# guard skipped emitting `SP_GC_SAVE()` at the top of the void
# wrapper. But the body's bare `return` (e.g. `return if x.nil?`)
# still emitted `SP_GC_RESTORE()` — which references `_gc_saved`
# that the missing SP_GC_SAVE never declared.
#
# Fix: reset @in_gc_scope to 0 when entering the void wrapper so
# declare_method_locals decides cleanly.
#
# The void wrapper is only emitted when a subclass calls `super`,
# so this reproducer needs the inheritance shape. The body uses
# a String pointer local (which forces declare_method_locals'
# has_gc_locals branch to want SP_GC_SAVE) and an early bare
# `return` (which forces compile_return_stmt to emit
# SP_GC_RESTORE).

class Base
  attr_reader :extra
  def initialize(skip)
    note = "base"
    if skip
      return        # bare `return` — emits SP_GC_RESTORE()
    end
    @extra = note
  end
end

class Child < Base
  def initialize
    super(false)    # calls sp_Base_initialize (the void wrapper)
  end
end

# Push into a [Child] array so neither class is value-typed —
# the void wrapper is only emitted for heap classes.
all = [Child.new, Child.new]
puts all.length          # 2
