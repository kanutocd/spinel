# Float#zero?: true only for 0.0 / -0.0.
p 0.0.zero?
p(-0.0.zero?)
p 3.5.zero?
p (1.0 - 1.0).zero?
puts(0.0.zero? ? "z" : "nz")
