# Issue #674: `hash.fetch(k, nil)` assigned to an int-typed LV must
# not lower to ((const char *)NULL). Pre-fix #671's codegen change
# emitted the pointer-NULL form whenever the surrounding method's
# return type was a nullable pointer -- but the fetch result here
# is being stored into `v` (mrb_int), not directly returned. The
# pointer-NULL assignment to an int slot trips -Wint-conversion (and
# under -Werror becomes a hard error).
#
# Fix moves the NULL coerce from the fetch arm to the return site
# (compile_body_return_inner's last-expr arm), gated on the actual
# AST shape -- so an LV-write context keeps the int form.

def f(opts = {})
  v = opts.fetch(:k, nil)
  v.nil? ? "missing" : "found"
end

puts f
