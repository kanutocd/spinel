# Worker reading two jobs off a port, summing, writing to a result port.
jobs = Ractor::Port.new
results = Ractor::Port.new
w = Ractor.new(jobs, results) do |inp, out|
  a = inp.receive
  b = inp.receive
  out.send(a + b)
end
jobs.send(10)
jobs.send(32)
puts results.receive

# String round-trip through ports (variable arg to avoid send-literal reflection)
sp = Ractor::Port.new
rp = Ractor::Port.new
e = Ractor.new(sp, rp) do |i, o|
  o.send(i.receive + " world")
end
greeting = "hello"
sp.send(greeting)
puts rp.receive
