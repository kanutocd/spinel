# #544 / #545 follow-up to #542. Body-usage param inference
# extended to two new shapes:
#
# A. Array body inference (#545 conservative path):
#    `param.push(x)` / `.pop` / `.shift` / `.unshift` / `.concat`
#    / `.compact` / `.flatten` / `.transpose` widens an
#    int/nil-defaulted param to poly_array. Critically does NOT
#    fire on `<<`, `&`, `|`, `*`, `+`, `-` (overlap with
#    Integer bitwise/arithmetic -- optcarrot's poke(data) shape).
#    Runs ONCE post-fixpoint so call-site inference can pin
#    narrower variants (int_array / float_array / etc.) first.
#
# B. Hash iteration inference (#545 iteration arm, lifted to
#    #542's pass):
#    `param.keys` / `.values` / `.each_pair` / `.merge` /
#    `.has_key?` / `.fetch` / `.store` / `.delete` /
#    `.transform_values` / `.transform_keys` / `.to_h` widens
#    to str_poly_hash when no literal-key signal has already
#    pinned the more-specific variant. These methods don't exist
#    on Array / String / Integer, so the classifier is
#    unambiguous.
#
# Each path's matching call-site cast (poly_array NULL cast,
# str_poly_hash NULL cast) and runtime NULL-guard
# (sp_PolyArray_length/get/push, sp_StrPolyHash_get, etc.)
# handle the composition shape Sam Ruby flagged in #542 /
# #545: typed callers continue to work; untyped callers
# (uninitialized ivar, etc.) cast their nil/int value to NULL
# of the param's pointer type and the body's helper calls
# safely return the slot's zero value.
#
# Untyped-caller-only is the supported shape; mixed typed +
# untyped callers on the SAME narrow specialization (e.g.
# typed int_array caller + untyped caller) still trips at C
# compile (typed caller pins to int_array, untyped's int can't
# cast to int_array). The user's options are: (1) seed the
# untyped source upstream, (2) avoid mixing typed and untyped
# callers, (3) wait for a future narrow-array NULL-guard
# series. Sam's roundhouse uses pattern (1) for the one
# remaining seed (Router.match's table).

# Array body inference - untyped-only callers.
def consume_arr(arr)
  arr.push(42)
  puts "arr.length=" + arr.length.to_s
end

class Box
  attr_accessor :contents
end

b = Box.new
consume_arr(b.contents)   # arr widens to poly_array via push;
                          # NULL cast at call; push no-ops via
                          # runtime guard; length returns 0.

# Hash iteration inference -- .each + .merge / .keys + [k].
def merge_into_seed(other)
  result = {a: 1}
  other.each { |k, v| result[k] = v }
  result.keys.length
end

puts merge_into_seed(b.contents)  # widens to str_poly_hash;
                                  # body's iteration no-ops on
                                  # NULL hash; result keeps the
                                  # initial seed; .keys.length = 1.

# Hash widening via .keys (no .each, no [k] literal access) --
# Sam's SqliteAdapter#insert/update shape (`cols = attrs.keys;
# cols.map { |k| attrs[k] }` -- the [k] uses a computed key,
# not a literal, so #542's literal-key arm misses but .keys
# catches the param's Hash shape).
def hash_keys_count(h)
  h.keys.length
end

puts hash_keys_count(b.contents)
