# Issue #1244: an unresolved Array method (here repeated_permutation /
# repeated_combination, which Spinel does not implement) emits a 0
# placeholder for its result. Chaining .to_a.inspect onto that NULL
# array used to dereference a->len and SEGV. The inspect helpers now
# NULL-guard and render "[]", so the program degrades safely instead
# of crashing. (Spinel does not compute the permutation; this test
# only pins that the unresolved path no longer segfaults.)
puts [1, 2].repeated_permutation(2).to_a.inspect
puts [1, 2].repeated_combination(2).to_a.inspect
puts "after"
