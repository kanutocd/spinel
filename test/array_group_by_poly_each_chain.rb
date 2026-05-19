# Array#group_by + Hash#each chain on a poly_array of sym_poly_hashes.
# spinel fuses `<arr>.group_by(blk).each |k, rows|` into a single emit
# that builds a sp_PolyPolyHash keyed by the block's return value, with
# each slot holding a sp_PolyArray of elements (boxed as poly). The
# iteration loop then unboxes the slot back to a typed sp_PolyArray so
# `rows.map { ... }` / `rows.sum` / `rows.size` reach the existing
# poly_array dispatch arms.
#
# Two downstream gaps the fusion exposes get fixed in the same change:
# `Array#size` was missing for poly_array (only `.length`), and
# `Array#sum` on a poly_array now uses a runtime helper that sums the
# int-tagged elements (the shape the .map produces for `_1[:int_key]`).
# Float interpolation also routes through sp_float_to_s so 4.0 renders
# as "4.0" (matching Ruby's Float#to_s) rather than "4" (printf %g).

scores = [
  { shop: "ginza", score: 5 },
  { shop: "ginza", score: 4 },
  { shop: "shibuya", score: 3 },
  { shop: "shibuya", score: 5 }
]

scores.group_by { _1[:shop] }.each do |shop, rows|
  avg = rows.map { _1[:score] }.sum.to_f / rows.size
  puts "#{shop}: #{avg}"
end
