# `Array * sep` (String arg) is equivalent to Array#join(sep) and
# returns a string. Previously spinel routed it through the int-repeat
# path which treated the string pointer as a loop count.
puts ([1, 2, 3] * ",")
puts ([1, 2, 3] * ",").inspect
puts ([1, 2, 3] * "")
puts (["a", "b", "c"] * "-")
