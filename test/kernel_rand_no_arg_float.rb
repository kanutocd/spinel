# Kernel#rand without args returns Float in [0.0, 1.0).
puts rand.class
puts rand(100).class
v = rand
puts v >= 0.0 && v < 1.0
