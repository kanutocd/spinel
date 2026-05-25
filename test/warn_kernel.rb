# Issue #734. `warn arg, ...` writes each arg to stderr with a
# newline (matching Kernel#warn). spinel used to emit the unresolved-
# call warning and drop the IO silently. `at_exit` is a known
# limitation (spinel doesn't model atexit hooks) but should no
# longer warn at compile time.

# at_exit + warn -- both used to fall through to the unresolved-call
# warning. The test runner only captures stdout, so warn's stderr
# output isn't part of the expected diff -- we just verify the
# compile succeeds and post-warn puts is reached.
at_exit { puts "this block is ignored" }
warn "hello stderr"
puts "after warn"
warn "two", "args"
puts "done"
