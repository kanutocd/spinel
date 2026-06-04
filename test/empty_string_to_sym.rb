# Empty-string interning: "".to_sym and the :"" literal must resolve to the
# same symbol id (an empty symbol once broke the C build).
p("".to_sym == :"")
p(:"" == "".to_sym)
p("abc".to_sym == :abc)
p("".to_sym.to_s == "")
