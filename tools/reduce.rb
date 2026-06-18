# spinel-reduce: delta-debug (ddmin) a degrading program down to a minimal
# input that still reproduces a chosen failure. Re-runs spinel only.
#
# Usage: spinel-reduce [--oracle build|unsupported|unresolved]
#                      [--oracle-cmd 'CMD {}'] [--shrink-ints] [-o OUT] app.rb
#
#   --oracle <leg>     built-in interestingness (default: build = spinel fails)
#   --oracle-cmd CMD   custom test: "{}" is replaced by the candidate file;
#                      the candidate is interesting when CMD exits 0
#   --shrink-ints      after code reduction, binary-search each surviving integer
#                      literal down to the smallest value that still reproduces,
#                      and report the threshold (isolates a size-triggered bug's
#                      numeric boundary, e.g. "fails once the dim crosses ~512")
#
# Tip: flatten multi-file programs first (spinel-flatten) so reduce has one
# input to shrink.

require_relative "tool_common"

# Is the candidate (an array of source lines) still interesting?
def interesting(lines, tmp, sp, oracle, ocmd)
  File.write(tmp, lines.join("\n") + "\n")
  if ocmd.length > 0
    sh(ocmd.gsub("{}", tmp))
    return $sh_status == 0
  end
  if oracle == "build"
    sh(sp + " " + tmp + " -o " + tmp + ".bin")
    return $sh_status != 0
  end
  needle = "unsupported "
  needle = "warning: unresolved" if oracle == "unresolved"
  out = sh("SPINEL_WARN_UNRESOLVED=1 " + sp + " " + tmp + " -c -o " + tmp + ".c")
  out.include?(needle)
end

# Classic ddmin: shrink `lines` while `interesting` holds, increasing
# granularity when no single chunk-complement reproduces.
def ddmin(lines, tmp, sp, oracle, ocmd)
  n = 2
  while lines.length >= 2
    size = lines.length / n
    size = 1 if size < 1
    start = 0
    reduced = false
    while start < lines.length
      stop = start + size
      comp = []
      k = 0
      while k < lines.length
        comp.push(lines[k]) if k < start || k >= stop
        k = k + 1
      end
      if comp.length > 0 && comp.length < lines.length && interesting(comp, tmp, sp, oracle, ocmd)
        lines = comp
        n = n - 1
        n = 2 if n < 2
        reduced = true
        start = 0
      else
        start = start + size
      end
    end
    if !reduced
      break if n >= lines.length
      n = n * 2
      n = lines.length if n > lines.length
    end
  end
  lines
end

# Is `c` a single decimal digit?
def is_digit(c)
  c >= "0" && c <= "9"
end

# Does the char left of offset `j` glue a digit there into an identifier or a
# larger number (so a digit at `j` is not the start of a fresh integer literal)?
def glued_left(line, j)
  return false if j == 0
  p = line[j - 1, 1]
  is_digit(p) || p == "_" || p == "." ||
    (p >= "a" && p <= "z") || (p >= "A" && p <= "Z")
end

# Build a candidate with the [b, e) span of lines[idx] replaced by `v`, and test
# whether it is still interesting.
def try_int(lines, idx, b, e, v, tmp, sp, oracle, ocmd)
  line = lines[idx]
  repl = line[0, b] + v.to_s + line[e, line.length - e]
  cand = []
  k = 0
  while k < lines.length
    cand.push(k == idx ? repl : lines[k])
    k = k + 1
  end
  interesting(cand, tmp, sp, oracle, ocmd)
end

# Parameter search: for each surviving integer literal, binary-search the
# smallest value that still reproduces the failure (assuming the trigger is
# monotone in the value -- what a size threshold is) and report the boundary. A
# literal whose value is irrelevant (even 0 still triggers) is zeroed and flagged
# "not size-dependent". Edits `lines` in place; returns the report lines.
def shrink_ints(lines, src, tmp, sp, oracle, ocmd)
  report = []
  idx = 0
  while idx < lines.length
    line = lines[idx]
    # Collect [start, stop) spans of integer literals.
    starts = []
    stops = []
    j = 0
    while j < line.length
      if is_digit(line[j, 1]) && !glued_left(line, j)
        k = j
        while k < line.length && (is_digit(line[k, 1]) || line[k, 1] == "_")
          k = k + 1
        end
        starts.push(j)
        stops.push(k)
        j = k
      else
        j = j + 1
      end
    end
    # Right-to-left, so editing one span never shifts an unprocessed one's offset.
    si = starts.length - 1
    while si >= 0
      b = starts[si]
      e = stops[si]
      orig = line[b, e - b].delete("_").to_i
      if orig != 0
        label = base_name(src) + ":" + (idx + 1).to_s
        if try_int(lines, idx, b, e, 0, tmp, sp, oracle, ocmd)
          line = line[0, b] + "0" + line[e, line.length - e]
          lines[idx] = line
          report.push(label + ": " + orig.to_s + " -> 0  (not size-dependent)")
        else
          lo = 1
          hi = orig
          while lo < hi
            mid = (lo + hi) / 2
            if try_int(lines, idx, b, e, mid, tmp, sp, oracle, ocmd)
              hi = mid
            else
              lo = mid + 1
            end
          end
          line = line[0, b] + hi.to_s + line[e, line.length - e]
          lines[idx] = line
          report.push(label + ": " + orig.to_s + " -> " + hi.to_s +
            "  (threshold; " + (hi - 1).to_s + " does not trigger)")
        end
      end
      si = si - 1
    end
    idx = idx + 1
  end
  report
end

def main
  oracle = "build"
  ocmd = ""
  shrink = false
  outfile = ""
  src = ""
  i = 0
  while i < ARGV.length
    a = ARGV[i]
    if a == "--oracle"
      i = i + 1
      oracle = ARGV[i] if i < ARGV.length
    elsif a == "--oracle-cmd"
      i = i + 1
      ocmd = ARGV[i] if i < ARGV.length
    elsif a == "--shrink-ints"
      shrink = true
    elsif a == "-o"
      i = i + 1
      outfile = ARGV[i] if i < ARGV.length
    elsif a == "-h" || a == "--help"
      puts "usage: spinel-reduce [--oracle build|unsupported|unresolved] [--oracle-cmd 'CMD {}'] [--shrink-ints] [-o OUT] app.rb"
      exit(0)
    else
      src = a
    end
    i = i + 1
  end
  die("usage: spinel-reduce [options] app.rb", 2) if src.length == 0
  die("spinel-reduce: no such file: " + src, 2) if !File.exist?(src)

  sp = find_spinel
  tmp = tmp_path("reduce", src, ".rb")
  lines = []
  File.read(src).split("\n").each { |l| lines.push(l) }

  if !interesting(lines, tmp, sp, oracle, ocmd)
    die("spinel-reduce: the input is not interesting under this oracle (nothing to reduce).", 1)
  end

  $stderr.puts "spinel-reduce: " + lines.length.to_s + " lines, oracle=" + (ocmd.length > 0 ? "cmd" : oracle)
  mini = ddmin(lines, tmp, sp, oracle, ocmd)
  $stderr.puts "spinel-reduce: reduced to " + mini.length.to_s + " lines"

  if shrink
    $stderr.puts "spinel-reduce: shrinking integer literals (parameter search)"
    report = shrink_ints(mini, src, tmp, sp, oracle, ocmd)
    if report.length > 0
      $stderr.puts "spinel-reduce: size thresholds:"
      report.each { |r| $stderr.puts "  " + r }
    end
  end
  text = mini.join("\n") + "\n"

  if outfile.length > 0
    File.write(outfile, text)
    $stderr.puts "spinel-reduce: wrote " + outfile
  else
    print text
  end
  exit(0)
end

main
