# Spawn arguments: deep-copied into the Ractor block params
r = Ractor.new(21) do |n|
  Ractor.yield(n * 2)
end
puts r.take

r2 = Ractor.new("hello", "world") do |a, b|
  Ractor.yield(a + " " + b)
end
puts r2.take

r3 = Ractor.new([1, 2, 3, 4]) do |nums|
  Ractor.yield(nums[0] + nums[3])
end
puts r3.take
