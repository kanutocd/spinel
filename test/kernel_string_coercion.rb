# Issue #879: Kernel#String() coercion routes through .to_s for
# each primitive type. nil -> "". Pre-fix: silently emitted 0.
puts String(42)
puts String(nil).inspect
puts String(true)
puts String("hi")
puts String(:sym)
puts String(3.14)
