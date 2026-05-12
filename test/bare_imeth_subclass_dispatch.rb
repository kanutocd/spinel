# Bare-receiver instance method call from inside a parent-defined
# method dispatches to the subclass override at runtime, not to the
# parent's stub. Pre-fix the codegen resolved imeth statically
# against the method body's defining class, so a Child instance
# routed through Base#run always landed on Base#hook.
#
# Imeth analog of the cmeth dispatch handled by the
# self_class_subclass_dispatch sibling test. The bare imeth call
# site lowers to a `switch (self->cls_id)` when descendants of the
# current class override the imeth.
#
# Coverage:
#   - Plain Base/Child override.
#   - Multi-level (GrandChild overrides hook).
#   - Subclass that doesn't override -- inherits via the default
#     (Sibling has no #hook, falls through to Base).
#   - Direct Base instance still routes to Base.

class Base
  def run
    hook
  end

  def hook
    puts "BASE"
  end
end

class Child < Base
  def hook
    puts "CHILD"
  end
end

class GrandChild < Child
  def hook
    puts "GRANDCHILD"
  end
end

class Sibling < Base
end

Base.new.run
Child.new.run
GrandChild.new.run
Sibling.new.run
