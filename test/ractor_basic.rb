# Minimal Ractor end-to-end (RFC, Milestone 1): spawn a Ractor on a
# pthread, send it a scalar through its mailbox, double it, and take the
# result back. Exercises Ractor.new / Ractor.receive / Ractor.yield /
# r.send / r.take with the scalar deep-copy boundary codec.
r = Ractor.new do
  x = Ractor.receive
  Ractor.yield(x * 2)
end
r.send(21)
puts r.take

# A second Ractor that sums two mailbox messages, exercising the `<<`
# send alias and multiple receives.
s = Ractor.new do
  a = Ractor.receive
  b = Ractor.receive
  Ractor.yield(a + b)
end
s << 10
s << 32
puts s.take
