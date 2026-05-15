path = "spinel_file_write_binary_string.bin"

File.write(path, "A" + 0.chr + "B")
bytes = File.binread(path).bytes

puts bytes.length
if bytes.length == 3
  puts bytes[0]
  puts bytes[1]
  puts bytes[2]
end

File.delete(path) if File.exist?(path)
