# Ensure that pushing a Proc into an ivar array (int_array default
# from []) promotes the array to poly_array so .each { |b| b.call }
# actually dispatches the proc. Without the fix, .call on the
# iteration variable is a no-op because b stays typed as mrb_int.
class Runner
  def initialize
    @procs = []
  end

  def add(&block)
    @procs.push(block)
  end

  def call_all
    @procs.each do |p|
      p.call
    end
  end
end

r = Runner.new
r.add { puts "first" }
r.add { puts "second" }
puts "before"
r.call_all
puts "after"
