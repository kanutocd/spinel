# `def initialize(conf = ARGV)` typed `conf` as the specialised
# `argv` scalar (because `infer_type(ARGV) == "argv"`). A caller
# that passes a single string then unified the call-site `string`
# against `argv` — the unifier had no argv-vs-string rule, so it
# dropped to the catch-all poly tail. `conf` widened to poly and
# `Wrapper.new(conf)` (which expects a String) received a poly arg,
# miscompiling the inner `@s.length` read.
#
# Narrowing argv + string → string biases toward the call-site
# shape: single-string entry points don't drag the whole signature
# into poly, while genuinely-array-of-strings call sites still
# unify on their own type via the existing array-array path.

class Wrapper
  def initialize(s)
    @s = s
  end
  def show
    puts @s.length
  end
end

class Entry
  def initialize(conf = ARGV)
    @conf = Wrapper.new(conf)
  end
  def show
    @conf.show
  end
end

Entry.new("hello").show     # 5
