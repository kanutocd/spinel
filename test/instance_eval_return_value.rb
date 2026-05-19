# instance_eval as an expression: the block's last expression is the
# call's value (CRuby semantics). Void-bodied blocks (assignment-only)
# fall through to a truthy receiver so `if obj.instance_eval { @f = 1 }`
# still works.

class Counter
  def initialize
    @count = 0
  end
  def inc
    @count = @count + 1
  end
end

c = Counter.new
c.inc
c.inc
c.inc

# Int-valued block returns the ivar, not the receiver.
n = c.instance_eval { @count }
puts n   # 3

# Boolean-valued block.
big = c.instance_eval { @count > 2 }
puts big # true

# Arithmetic expression body.
doubled = c.instance_eval { @count + @count }
puts doubled # 6

# String-valued block (pointer-typed return).
class Greeter
  def initialize
    @greeting = "hello"
  end
end

g = Greeter.new
msg = g.instance_eval { @greeting }
puts msg # hello

# Void body: receiver flows out via comma-expr fallback, keeping the
# `if` arm truthy.
class Flag
  def initialize
    @flag = 0
  end
end

f = Flag.new
if f.instance_eval { @flag = 1 }
  puts "truthy"
end

puts "done"
