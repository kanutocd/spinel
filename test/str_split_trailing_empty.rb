# String#split without limit drops trailing empty strings
# String#split(sep, -1) keeps them (CRuby default vs no-limit behavior).

puts "a,b,c,".split(",").inspect
puts "a,b,c,,,".split(",").inspect
puts "a,b,c".split(",").inspect
puts "a,b,c,".split(",", -1).inspect
