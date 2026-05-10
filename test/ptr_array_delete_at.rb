# Regression: `Array#delete_at(i)` on an array of user-class
# instances. Pre-fix the codegen had the dispatch arm only for
# IntArray / StrArray; PtrArray<UserClass> hit the unresolved-call
# warning and emitted 0, so user-class arrays could push but never
# shrink. Hit while building Tep::Scheduler's fiber-slot list:
# the `clear` loop never terminated because `delete_at` was a no-op.

class Box
  attr_accessor :tag
  def initialize(tag)
    @tag = tag
  end
end

a = [Box.new("seed")]
a.delete_at(0)
a.push(Box.new("a"))
a.push(Box.new("b"))
a.push(Box.new("c"))
puts a.length.to_s     # 3

# Remove from middle.
v = a.delete_at(1)
puts v.tag             # b
puts a.length.to_s     # 2
puts a[0].tag          # a
puts a[1].tag          # c

# Negative index counts from end.
last = a.delete_at(-1)
puts last.tag          # c
puts a.length.to_s     # 1

# Out-of-range index returns nil-equivalent (NULL); array
# unchanged.
gone = a.delete_at(99)
puts gone.nil? ? "nil" : "not-nil"
puts a.length.to_s     # 1

# Drain via repeated delete_at(0) -- the use case that surfaced
# this bug. Loop must terminate.
while a.length > 0
  a.delete_at(0)
end
puts a.length.to_s     # 0
puts a.empty? ? "empty" : "not-empty"
