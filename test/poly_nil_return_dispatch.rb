# Regression: a subclass override whose static return type is `nil`
# must still be called when dispatched through a poly receiver.
# Previously `box_value_to_poly("nil", call_expr)` dropped `call_expr`
# and emitted a bare `sp_box_nil()` for that arm, so the body of the
# override never ran.
#
# Two checks:
#  1. The override's side effect runs (the `puts` inside Sub#hook).
#  2. The dispatched call's *return value* is correctly observable as
#     nil (i.e. the boxing path threads through, not just the side
#     effect).

class Base
  def hook(arg); end          # empty body -> static return "nil"
end

class Sub < Base
  def hook(arg)
    puts "subclass-ran: " + arg   # `puts` returns nil
  end
end

class Holder
  attr_accessor :h
  def initialize; @h = Base.new; end
  def set(x); @h = x; end
  def call_hook(arg); @h.hook(arg); end
end

h = Holder.new
h.set(Sub.new)
result = h.call_hook("ok")
puts result == nil
