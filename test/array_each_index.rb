# Array#each_index { |i| } yields each index (0..length-1). Works on
# any typed array; only the index is bound, no element.
[10, 20, 30].each_index { |i| puts i }
puts "---"
%w[a b c].each_index { |i| puts "idx #{i}" }
puts "---"
[].each_index { |i| puts "never" }
puts "done"
