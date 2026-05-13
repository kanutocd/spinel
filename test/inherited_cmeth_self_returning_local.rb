# Inherited class method whose body holds a local typed by a
# method that each subclass overrides. The local's C type
# needs to specialize per-subclass.
#
# Pre-fix: scan_locals stored the result in @nd_scope_names
# keyed by the shared AST body id; whichever subclass scanned
# last won, leaving every other subclass with the wrong LV
# C type. Surfaced in real-blog's `Comment.find` returning
# `sp_Article *` (warning under -Wincompatible-pointer-types,
# silent miscompile if Article / Comment struct layouts
# diverge).
#
# Fix: per-(class, cmeth_idx) scope tables in
# @cls_cmeth_scope_names / @cls_cmeth_scope_types preserve
# each subclass's scan result. Codegen consumes the per-
# subclass entry instead of the per-bid one.

class Base
  def self.find(id)
    result = adapter_find(id)
    result
  end
end

class Article < Base
  attr_accessor :id, :title
  def self.adapter_find(id)
    a = Article.new
    a.id = id
    a.title = "art-#{id}"
    a
  end
end

class Comment < Base
  attr_accessor :id, :body
  def self.adapter_find(id)
    c = Comment.new
    c.id = id
    c.body = "comment-#{id}"
    c
  end
end

a = Article.find(7)
puts a.title
c = Comment.find(9)
puts c.body
