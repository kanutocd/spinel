# String#crypt — spinel's contract: 13-char deterministic output
# whose first 2 chars are the salt (or "." padding). Underlying
# primitive is HMAC-SHA-256 (via libspinel_rt.a's sp_crypto),
# NOT libc's DES crypt, so the hash bytes won't match MRI's
# DES output — but length, salt-prefix, and reproducibility do.

r = "hello".crypt("ab")
puts r.length
puts r[0, 2]

# Determinism: same inputs → identical output.
puts "hello".crypt("ab") == "hello".crypt("ab")

# Different password → different hash, same salt prefix.
a = "hello".crypt("ab")
b = "world".crypt("ab")
puts a[0, 2] == b[0, 2]   # same salt
puts a == b                # different hash

# 1-char salt is padded.
puts "x".crypt("z").length
puts "x".crypt("z")[0, 2]
