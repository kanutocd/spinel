# Issue #662: Array#+ concatenating arrays of different element
# types. Previously the codegen assumed both operands had the same
# array prefix and used the lhs's *_get / *_length / *_push for
# both -- failed C compilation with a pointer-type mismatch.
#
# Fix: infer_call_type returns "poly_array" when lhs is a typed
# array and rhs is an array of a different element type. compile_+
# detects the same shape and builds an sp_PolyArray, boxing each
# source element via sp_box_* (sp_box_obj with cls_id for ptr).

a1 = [1, 2, 3]
a2 = ["x", "y", "z"]
a3 = a1 + a2
puts a3.length
puts a3[0]
puts a3[3]
puts "ok"

# Float + Int round-trip
b1 = [1.5, 2.5]
b2 = [10, 20]
b3 = b1 + b2
puts b3.length
puts b3[0]
puts b3[2]
puts "done"
