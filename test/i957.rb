h = {a: 1, b: 2}
p = h.to_proc
puts p.call(:a)
puts p.call(:b)

g = {"x" => 10, "y" => 20}.to_proc
puts g.call("x")
puts g.call("y")
