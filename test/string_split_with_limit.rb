# String#split with a positive `limit` argument caps the result at
# `limit` elements; the last element keeps the unsplit remainder.
# Pre-fix spinel's two-arg split fell through to sp_str_split, which
# ignored the limit and split exhaustively. Issue #619 puzzle 2.
p "hi!".split("", 2) == ["h", "i!"]
p "a,b,c,d".split(",", 2) == ["a", "b,c,d"]
p "a,b,c,d".split(",", 3) == ["a", "b", "c,d"]
p "abc".split("", 1) == ["abc"]                     # limit=1 keeps the whole string
p "abc".split("", 3) == ["a", "b", "c"]             # limit == #chars, exact split
p "a,b,c".split(",", -1) == ["a", "b", "c"]         # negative limit -> full split
