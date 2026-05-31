# StringIO.new(nil) raises TypeError, matching CRuby, instead of
# running strlen(NULL) at the C level (which warned -Wnonnull and would
# segfault). The reporter's "null device" framing is incorrect: CRuby
# rejects a nil initial string outright.
require 'stringio'
begin
  StringIO.new(nil)
  puts "BUG: no raise"
rescue TypeError => e
  puts "TypeError: #{e.message}"
end
# A real string still constructs normally.
io = StringIO.new("ok")
puts io.string
