# Issue #663: Array#<< with heterogeneous element types on an
# initially-empty array. Previously the type inference latched
# onto the first push's element type (transitioning int_array ->
# str_array / float_array / sym_array) but didn't widen to
# poly_array when a subsequent push had a different type. The
# codegen then emitted e.g. sp_StrArray_push with an int literal
# and failed C compilation.
#
# Fix: scan_locals's push/<< inference now widens to poly_array
# when the slot is already a non-target concrete array type and
# the next push is of a different family.

arr = []
arr << 1
arr << "string"
arr << :symbol
puts arr.length
puts arr[0]
puts arr[1]
puts arr[2]
puts "ok"
