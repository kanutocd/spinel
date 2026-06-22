# Integer#digits(base) returns the digits in the given base, least-significant
# first. The base argument must reach the runtime instead of being ignored.
p 255.digits
p 255.digits(16)
p 100.digits(10)
p 1234.digits(16)
p 0.digits(16)

def digits_of(n, base)
  n.digits(base)
end
p digits_of(255, 16)
p digits_of(1000, 2)
