# Splatting a string range into an array literal expands it into a
# str_array (the runtime already has sp_StrArray_from_string_range; the
# bug was the literal mis-typing to int_array and emitting a char*-in-
# int-loop).
p [*"a".."e"]
p [*"a"..."d"]        # exclusive range drops the endpoint
p [*"x".."z", "!"]    # splat-first, then a trailing literal
p [*" ".."&"]         # the printable-ASCII idiom from the bug report
