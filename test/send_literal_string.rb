# .send("sym", args) plain string literal rewrites to .sym(args) at
# parse time, identical to the :symbol form. Interpolated strings and
# variable args still fall through to runtime dispatch.

class Calc
  def add(a, b)
    a + b
  end

  def hello
    "hi"
  end
end

c = Calc.new
puts c.send("add", 2, 3)       # 5
puts c.send("hello")           # hi

puts "done"
