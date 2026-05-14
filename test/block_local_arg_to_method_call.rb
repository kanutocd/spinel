# #484. A class method whose body iterates `arr.each do |bp| ... end`
# and passes `bp` to another class method's call previously left the
# callee's param at the `mrb_int` default. The same shape at top-
# level worked because infer_main_call_types uses the full scan_locals
# walker which already records block-param types into scope before
# scan_new_calls widens call-site arg types. The class-method path
# used scan_locals_first_type which omitted block-param handling.
# Fix: scan_locals_first_type now picks up RequiredParameterNode
# entries for `recv.method do |bp| ... end` blocks and records the
# inferred element type (str_array -> string, etc.).

class M
  def self.use(s)
    s.length
  end

  def self.driver
    ["a", "b"].each do |pair|
      M.use(pair)
    end
  end
end

M.driver
puts "ok"
