# `[nil, nil, ...].first` / `.last` returns nil. Pre-fix the
# array-literal lowering pushed each NilNode as `sp_IntArray_push(_t, 0)`
# (the int_array default) and `.first` returned int 0, so `.nil?`
# folded to false. The peephole keeps the int_array layout for the
# rest of the inference -- lifting all-nil literals to poly_array
# breaks optcarrot's `[nil] * N` initialization -- but recognises
# the `[nil, ...].first / .last` shape at the analyzer's CallNode
# return-type site. Issue #619 puzzle 5.
p [nil].first.nil?               # true
p [nil].last.nil?                # true
p [nil, nil, nil].first.nil?     # true
p [nil, nil, nil].last.nil?      # true
