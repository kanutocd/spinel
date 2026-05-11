# Issue #430. `@ivar = [] if @ivar.nil?` plus push-through-getter:
# the ivar stayed inferred as IntArray (from the empty `[]`
# literal) even when pushes through a getter method handed in
# string values. sp_IntArray_push then took the string as a
# mrb_int -- C compile error.
#
# Fix: scan_writer_calls now also matches the bare-call shape
# `<getter>(*args) << v` / `<getter>.push(v)` by resolving
# through method_returns_ivar_in_class -- if the getter method's
# body returns a bare `@<iname>` as its last expression, the
# push observation lands on `@<iname>` directly. The empty-array
# default promotes the same way it does for direct `@x.push`
# / `@x << v` writes.
#
# Coverage:
#   - The canonical Rails-style `ActiveRecord::Base#errors`
#     shape: lazy-init via nil guard, push via a sibling
#     `add_error` method that calls `errors << "..."`.
#   - Same shape with `self.<getter>` (explicit self-recv) so
#     both the bare and self-prefixed call forms route to the
#     ivar.

class Errors
  def list
    @list = [] if @list.nil?
    @list
  end

  def add(msg)
    list << msg
  end
end

class ErrorsSelf
  def list
    @list = [] if @list.nil?
    @list
  end

  def add(msg)
    self.list << msg
  end
end

e = Errors.new
e.add("a")
e.add("b")
puts e.list.length
puts e.list[0]
puts e.list[1]

es = ErrorsSelf.new
es.add("x")
puts es.list[0]
