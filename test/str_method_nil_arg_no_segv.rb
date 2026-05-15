# #504. Several String methods receiving the wrong arg shape used
# to SEGV. CRuby raises ArgumentError; spinel can't raise but we
# should at least not crash. Codegen emits compile_arg0 -> "0"
# (NULL) for missing args and the runtime helpers then ran
# strlen(NULL) or worse.
#
# Fix: NULL guards in sp_str_count / sp_str_delete /
# sp_str_rindex / sp_str_concat; setbyte (which would have
# written through a read-only string literal) is now warned and
# returns 0 without mutating. The send(:<<) shape isn't covered
# here -- it doesn't crash but inherits a misinferred return
# type from the inner sp_str_concat, so the output is meaningless.

p "foo".count    # CRuby: ArgumentError. spinel: 0 (was: SEGV)
p "foo".delete   # CRuby: ArgumentError. spinel: "foo" unchanged (was: SEGV)
p "foo".rindex(/missing/)  # CRuby: nil. spinel: -1 (was: SEGV; no regex rindex helper yet)

# setbyte on a literal: CRuby returns the int and mutates the
# string in place. Spinel strings are `const char *` so we
# can't mutate; the helper is a no-op + warning now. Test just
# verifies "doesn't crash" -- the warn output goes to stderr,
# which the harness drops.
(str = "a")
str.setbyte(0, 98)
puts str   # spinel: "a" (mutation was dropped). Was: SEGV.
