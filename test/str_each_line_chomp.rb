# String#each_line(chomp: true) strips trailing line endings.
"a\nb\nc".each_line(chomp: true) { |l| p l }
puts "---"
"a\nb\nc".each_line { |l| p l }
puts "---"
"x\r\ny\r\n".each_line(chomp: true) { |l| p l }
