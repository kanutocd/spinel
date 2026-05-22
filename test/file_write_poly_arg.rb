# Issue #643: `File.write(path, value)` where `value`'s static
# type is poly (cross-class union widened the return slot of the
# producer to sp_RbVal) used to emit `sp_file_write(lv_path,
# lv_value)` with a struct value passed where const char * was
# expected — C compile failure with "incompatible type for
# argument 2".
#
# Fix: when either arg's static type is poly, extract `.v.s`
# before the call.

class Worker
  def run(x)
    "result-#{x}"
  end
end

class OtherWorker
  def run(x)
    "alt-#{x}"
  end
end

# Cross-class union via array — both classes' `run` returns String,
# but the union of obj_Worker | obj_OtherWorker pushed through
# `.each` widens the dispatch return to sp_RbVal in some shapes.
workers = [Worker.new, OtherWorker.new]
results = workers.map { |w| w.run(42) }

# results is poly_array; result of [0] dispatch is poly. File.write
# call site must unbox before the sp_file_write boundary.
# Use cwd-relative path so Windows MinGW (no `/tmp`) passes —
# memory: feedback_windows_tmp_path.
path = "spinel_i643_test.txt"
File.write(path, results[0])
puts File.read(path)
File.delete(path)
