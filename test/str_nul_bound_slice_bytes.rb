# Issue #657: a string with embedded NUL bytes had two surviving
# truncation paths:
#
#   - s[a, n] slice walks the result range via sp_utf8_byte_offset
#     applied to (s + boff, n). The inner call fell back to strlen
#     on a mid-string pointer (no 0xfe/0xfc marker visible at [-1])
#     and stopped at the first NUL after boff.
#
#   - s.bytes[i] (via sp_str_bytes) used `for (i=0; s[i]; i++)` which
#     terminates at the first NUL byte.
#
# Fix:
#   - sp_utf8_byte_offset bounds the walk on sp_str_byte_len(s)
#     (which honours the heap-string hdr marker) instead of "*p".
#   - sp_str_sub_range / sp_str_sub_range_len compute the end byte
#     position inline against sp_str_byte_len(s) instead of recursing
#     into sp_utf8_byte_offset(s+boff, len).
#   - sp_str_bytes walks 0..sp_str_byte_len(s) instead of 0..NUL.
#
# Concat already round-trips NULs correctly (sp_str_concat uses
# sp_str_byte_len for both inputs).

nul = 0.chr
s = "abc" + nul + "def"
puts "len=#{s.length}"
puts "slice_full=#{s[0, 7].length}"
puts "slice_after_nul=#{s[4, 3].length}"
puts "slice_around_nul=#{s[2, 3].length}"
puts "b0=#{s.bytes[0]}"
puts "b3=#{s.bytes[3]}"
puts "b4=#{s.bytes[4]}"
puts "b6=#{s.bytes[6]}"
puts "bytes_len=#{s.bytes.length}"
