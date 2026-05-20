# Shared helpers used by both spinel_analyze.rb and
# spinel_codegen.rb. Extracted to avoid byte-for-byte
# duplication between the two compiler passes. Both passes
# already share node-table accessors (@nd_type / @nd_name /
# @nd_arguments / etc.) and class-table accessors
# (cls_find_method / cls_method_return / etc.) by virtue of
# both defining a `class Compiler`; the methods here only
# depend on that shared surface.
#
# To add a helper here it must:
# - depend only on instance vars / methods that exist on
#   BOTH the analyze-side and codegen-side Compiler
# - not perform pass-specific side effects (emit, push narrow
#   stack only via methods both sides define, etc.)
# - have identical semantics in both passes (drift between
#   the two would re-introduce the original bug)
class Compiler

 # ---- Nil-guard narrow helpers (#550) ----

 # `<lv>.nil?` predicate. Returns the LV name; otherwise "".
  def parse_nil_predicate(pred_id)
    if pred_id < 0
      return ""
    end
    if @nd_type[pred_id] != "CallNode"
      return ""
    end
    if @nd_name[pred_id] != "nil?"
      return ""
    end
    recv = @nd_receiver[pred_id]
    if recv < 0 || @nd_type[recv] != "LocalVariableReadNode"
      return ""
    end
    @nd_name[recv]
  end

 # Body ends with a definite scope exit. Used by the nil-guard
 # narrow (issue #550) to identify guards whose continuation
 # only fires when the predicate held. Recognizes:
 # - `return X` (ReturnNode)
 # - `raise ...` / `throw ...` (CallNode)
 # - `break` / `next` (BreakNode / NextNode) -- both unwind
 #   the iteration / loop, so the narrow applies to the rest
 #   of the enclosing block.
  def body_definitely_exits?(body_id)
    if body_id < 0
      return 0
    end
    stmts_r = get_stmts(body_id)
    if stmts_r.length == 0
      return 0
    end
    last = stmts_r[stmts_r.length - 1]
    if @nd_type[last] == "ReturnNode"
      return 1
    end
    if @nd_type[last] == "BreakNode" || @nd_type[last] == "NextNode"
      return 1
    end
    if @nd_type[last] == "CallNode" && (@nd_name[last] == "raise" || @nd_name[last] == "throw")
      return 1
    end
    0
  end

 # Given the rhs of the most recent write to a local variable
 # whose nil? was just checked, return the type the variable
 # narrows to after the nil-exit. Currently recognizes
 # `<string>.index(needle)` / rindex / find_index returning
 # int-or-nil; the non-nil arm is mrb_int. Returns "" when the
 # writer's shape isn't a known int-or-nil source so the caller
 # leaves the type alone. Issue #550.
  def infer_nil_guard_narrow_type(expr_id)
    if expr_id < 0
      return ""
    end
    if @nd_type[expr_id] != "CallNode"
      return ""
    end
    mname_eg = @nd_name[expr_id]
    if mname_eg != "index" && mname_eg != "rindex" && mname_eg != "find_index"
      return ""
    end
    recv_eg = @nd_receiver[expr_id]
    if recv_eg < 0
      return ""
    end
    rt_eg = infer_type(recv_eg)
    if rt_eg == "string" || rt_eg == "mutable_str"
      return "int"
    end
 # Array#index family on int_array now returns int? (sentinel-
 # encoded). After `return if h.nil?` the live arm sees the value
 # as a plain int, same as the String#index narrow above.
    if rt_eg == "int_array"
      return "int"
    end
    ""
  end

 # Recognize `return X if h.nil?` shape; return the LV name or
 # "". Caller threads the stmt list separately into
 # scan_back_writer_narrow_for to derive the narrow type. (Two
 # separate calls instead of one [var, type] return because
 # spinel-self's inference widens an array-return into poly,
 # cascading into push_type_narrow's param signature.)
 # Issue #550.
  def parse_nil_guard_var(nid)
    if nid < 0
      return ""
    end
    if @nd_type[nid] != "IfNode"
      return ""
    end
    body_i = @nd_body[nid]
    if body_definitely_exits?(body_i) == 0
      return ""
    end
    sub_i = @nd_subsequent[nid]
    else_i = @nd_else_clause[nid]
    if sub_i >= 0 || else_i >= 0
      return ""
    end
    parse_nil_predicate(@nd_predicate[nid])
  end

  def scan_back_writer_narrow_for(stmts_list, before_idx, varname)
    j = before_idx - 1
    while j >= 0
      stmt = stmts_list[j]
      if @nd_type[stmt] == "LocalVariableWriteNode" && @nd_name[stmt] == varname
        return infer_nil_guard_narrow_type(@nd_expression[stmt])
      end
      j = j - 1
    end
    ""
  end

 # ---- Poly-recv dispatch helpers (#549) ----

 # For a `<poly>.<mname>(args)` site, return the static C type
 # the dispatch result temp should have. Returns "poly" when
 # the surviving cls_id arms can't agree on a single scalar.
 # nid + arg_types let the helper apply the same arm-suppression
 # logic the emit loop uses (param-incompat + observed-class
 # narrow), so unreachable arms don't widen the result.
  def poly_dispatch_return_type(mname, nid = -1, arg_types = nil)
    if arg_types == nil
      arg_types = "".split(",")
    end
    if mname == "[]"
      @needs_rb_value = 1
      return "poly"
    end
 # Hash-shape preserving methods on a poly recv carrying hash
 # storage. The result temp must be sp_RbVal so the per-cls_id
 # arm's `tmp = sp_box_obj(...)` lands. Without this, the temp
 # is mrb_int and the assignment silently no-ops, leaving every
 # downstream consumer reading the int 0 default.
    if mname == "dup" || mname == "each" || mname == "to_h" || mname == "merge"
      @needs_rb_value = 1
      return "poly"
    end
 # `fetch` on a poly recv: runtime cls_id picks between user-class
 # `fetch` arms and built-in Hash-variant arms (StrIntHash /
 # StrStrHash / StrPolyHash). Each arm's value type differs (int /
 # string / poly) so the result temp must be sp_RbVal -- without
 # widening, the temp's static C type comes from the first user
 # class's `fetch` return and other arms' rhs fails to compile
 # against it. Sibling to `[]` widening above; same rationale.
    if mname == "fetch"
      @needs_rb_value = 1
      return "poly"
    end
 # Source-level narrow set from ivar observations: when the
 # receiver reads from an ivar whose observed type set is all
 # obj_X (no poly / no primitives), the dispatch can only ever
 # land on those classes. Combined with the param-incompat
 # check below, this prunes arms whose return type would
 # otherwise widen the dispatch result to sp_RbVal even though
 # they can never fire at runtime. Issues #549, #531.
    narrow_set = poly_dispatch_narrow_class_set(nid)
 # Built-in string methods that compile_poly_method_call also
 # lowers via a SP_TAG_STR arm -- their result temp needs to be
 # at least string-typed so the per-tag dispatch assignment
 # doesn't try to store const char * into a mrb_int slot. If a
 # user class also defines the method with a different return
 # type, the per-class loop below escalates to "poly".
    if mname == "gsub" || mname == "sub"
      ci_s = 0
      diverges = 0
      while ci_s < @cls_names.length
        if narrow_set != "" && poly_dispatch_class_in_set(narrow_set, ci_s) == 0
          ci_s = ci_s + 1
        else
          if cls_find_method(ci_s, mname) >= 0 && poly_dispatch_arm_param_compat(ci_s, mname, arg_types) == 1
            urt = cls_method_return(ci_s, mname)
            if urt != "" && urt != "string"
              diverges = 1
              ci_s = @cls_names.length
            end
          end
          ci_s = ci_s + 1
        end
      end
      if diverges == 1
        @needs_rb_value = 1
        return "poly"
      end
      return "string"
    end
 # Setters: mname ends with "=" and at least one class has an
 # attr_writer for the bare name. Return type is the ivar type
 # (Ruby returns the rhs from `x = v`); without this, the result
 # tmp's C type defaults to `mrb_int` and `tmp = rhs` mismatches
 # for non-int slots.
    setter_bname = ""
    if mname.length > 1 && mname[mname.length - 1] == "="
      setter_bname = mname[0, mname.length - 1]
    end
    common = ""
    ci = 0
    while ci < @cls_names.length
      if narrow_set != "" && poly_dispatch_class_in_set(narrow_set, ci) == 0
        ci = ci + 1
      else
        rt = ""
        if cls_find_method(ci, mname) >= 0
 # Skip arms whose param types can't accept the dispatch
 # site's arg types -- mirrors the arm_incompat check in
 # the emit loop so the result-type union doesn't see
 # return types from arms the runtime can't reach.
          if poly_dispatch_arm_param_compat(ci, mname, arg_types) == 0
            rt = ""
          else
            rt = cls_method_return(ci, mname)
          end
        elsif cls_has_attr_reader(ci, mname) == 1
 # An attr_reader returns the ivar type. .
          rt = cls_ivar_type(ci, "@" + mname)
        elsif setter_bname != "" && cls_has_attr_writer(ci, setter_bname) == 1
 # An attr_writer setter returns the ivar's type.
          rt = cls_ivar_type(ci, "@" + setter_bname)
        end
        if rt != ""
          if common == ""
            common = rt
          elsif common != rt
            return "poly"
          end
        end
        ci = ci + 1
      end
    end
    common == "" ? "int" : common
  end

 # Returns a comma-separated list of class indices the dispatch
 # site can possibly land on, derived from the receiver ivar's
 # observed type set. Returns "" when no narrowing is safe
 # (non-ivar receiver, partial observation, or any non-obj
 # observation like "poly" / "int" / "string"). Issue #549.
  def poly_dispatch_narrow_class_set(nid)
    if nid < 0
      return ""
    end
    if @current_class_idx < 0
      return ""
    end
    recv_id = @nd_receiver[nid]
    if recv_id < 0
      return ""
    end
    if @nd_type[recv_id] != "InstanceVariableReadNode"
      return ""
    end
    iname = @nd_name[recv_id]
    obs = cls_ivar_observed_types_for(@current_class_idx, iname)
    if obs == ""
      return ""
    end
    out = ""
    parts = obs.split(",")
    k = 0
    while k < parts.length
      t = parts[k]
      if t == ""
 # blank slot -- uninformative, skip
      elsif t == "poly"
 # "poly" alone means the writer-scan saw a widened union value
 # (typically a method param that received obj_X across multiple
 # callsites and collapsed to poly). The companion ctor-arg
 # propagation pass adds the concrete obj_X entries alongside,
 # so when we ALSO see those, the obj_X set is sharper and we
 # should keep the narrow. Skip the bare "poly" here; if no
 # obj_X entries follow, `out` stays empty and the caller falls
 # back to the unrestricted dispatch.
      elsif is_obj_type(t) == 1
        cname = t[4, t.length - 4]
        cidx = find_class_idx(cname)
        if cidx >= 0
          s_idx = cidx.to_s
          if out == ""
            out = s_idx
          else
 # dedup
            already = 0
            seen = out.split(",")
            sk = 0
            while sk < seen.length
              if seen[sk] == s_idx
                already = 1
              end
              sk = sk + 1
            end
            if already == 0
              out = out + "," + s_idx
            end
          end
        end
      else
 # Truly broad non-obj observation ("int", "string", "float"
 # etc.) — the ivar can hold a value whose dispatch isn't a
 # user-class method call at all. Bail to avoid unsound pruning.
        return ""
      end
      k = k + 1
    end
    out
  end

  def poly_dispatch_class_in_set(set, ci)
    if set == ""
      return 1
    end
    target = ci.to_s
    parts = set.split(",")
    k = 0
    while k < parts.length
      if parts[k] == target
        return 1
      end
 # Allow when ci is a descendant of an observed class. The ivar
 # may have been written via a typed setter (`def set_x(f); @x = f; end`)
 # whose param is the declared base type, but the actual runtime
 # object is a subclass instance whose own cls_id won't appear in
 # the observed set. Without this, the dispatch only emits the
 # base-class arm and the subclass override is silently skipped --
 # the #616 filter-elision shape (App.set_before(SubFilter.new) ->
 # @before_filter.before(...) where the override never fires).
      ancestor_ci = parts[k].to_i
      if ancestor_ci >= 0 && cls_is_descendant(ci, ancestor_ci) == 1
        return 1
      end
      k = k + 1
    end
    0
  end

 # Mirrors the arm_incompat check inside compile_poly_method_call's
 # emit loop. Returns 1 when the arm's param types are compatible
 # with the dispatch site's arg types, 0 when at least one slot
 # has a base-type mismatch outside the int/symbol/bool family.
  def poly_dispatch_arm_param_compat(ci, mname, arg_types)
    midx = cls_find_method_direct(ci, mname)
    owner_idx = ci
    if midx < 0
      owner_name = find_method_owner(ci, mname)
      if owner_name != ""
        owner_idx = find_class_idx(owner_name)
        if owner_idx >= 0
          midx = cls_find_method_direct(owner_idx, mname)
        end
      end
    end
    if midx < 0
      return 1
    end
    arm_ptypes = cls_meth_ptypes_get(owner_idx, midx)
    pk = 0
    while pk < arm_ptypes.length && pk < arg_types.length
      at_b = base_type(arg_types[pk])
      pt_b = base_type(arm_ptypes[pk])
      if at_b != "" && pt_b != "" && at_b != "poly" && pt_b != "poly" && at_b != pt_b
        if (at_b == "int" && pt_b == "symbol") || (at_b == "symbol" && pt_b == "int") ||
           (at_b == "int" && pt_b == "bool")   || (at_b == "bool"   && pt_b == "int")
 # compatible
        else
          return 0
        end
      end
      pk = pk + 1
    end
    1
  end

 # ---- AST id-list cache ----

 # Parse comma-sep node IDs into IntArray. Manually walks bytes to avoid
 # allocating the intermediate StrArray + substrings that `String#split`
 # would produce -- this is called ~100 K times during bootstrap.
 # Results are cached by input string: AST fields are immutable once
 # parsed, so the same IntArray can be shared across callers. Callers
 # must treat the result as read-only.
  def parse_id_list(s)
    if @parse_id_cache.key?(s)
      return @parse_id_pool[@parse_id_cache[s]]
    end
    result = []
    if s != ""
      bs = s.bytes
      i = 0
      n = bs.length
      num = 0
      while i < n
        b = bs[i]
        if b == 44  # ','
          result.push(num)
          num = 0
        else
          num = num * 10 + (b - 48)
        end
        i = i + 1
      end
      result.push(num)
    end
    @parse_id_cache[s] = @parse_id_pool.length
    @parse_id_pool.push(result)
    result
  end

 # ---- AST node table storage (parallel arrays by node ID) ----
 # The 46 @nd_* arrays are initialized in each host's `initialize`
 # and operated on here. Fields are listed explicitly (not via
 # ivar reflection) because the spinel-self type inferencer reads
 # the literal `@nd_X.push(0)` vs `@nd_X.push("")` shape to pick
 # IntArray vs StrArray storage per slot.

  def alloc_node
    nid = @nd_count
    @nd_type.push("")
    @nd_name.push("")
    @nd_value.push(0)
    @nd_content.push("")
    @nd_flags.push(0)
    @nd_operator.push("")
    @nd_binop.push("")
    @nd_callop.push("")
    @nd_unescaped.push("")
    @nd_receiver.push(-1)
    @nd_arguments.push(-1)
    @nd_body.push(-1)
    @nd_block.push(-1)
    @nd_parameters.push(-1)
    @nd_predicate.push(-1)
    @nd_subsequent.push(-1)
    @nd_else_clause.push(-1)
    @nd_left.push(-1)
    @nd_right.push(-1)
    @nd_constant_path.push(-1)
    @nd_superclass.push(-1)
    @nd_rest.push(-1)
    @nd_keyword_rest.push(-1)
    @nd_rescue_clause.push(-1)
    @nd_ensure_clause.push(-1)
    @nd_expression.push(-1)
    @nd_target.push(-1)
    @nd_pattern.push(-1)
    @nd_key.push(-1)
    @nd_reference.push(-1)
    @nd_collection.push(-1)
    @nd_stmts.push("")
    @nd_args.push("")
    @nd_requireds.push("")
    @nd_optionals.push("")
    @nd_keywords.push("")
    @nd_elements.push("")
    @nd_parts.push("")
    @nd_conditions.push("")
    @nd_exceptions.push("")
    @nd_targets.push("")
    @nd_rights.push("")
    @nd_posts.push("")
    @nd_new_name.push(-1)
    @nd_old_name.push(-1)
    @nd_names.push("")
    @nd_inferred_type.push("")
    @nd_scope_names.push("")
    @nd_scope_types.push("")
    @nd_count = @nd_count + 1
    nid
  end

 # Bulk presize variant called by NodeTableLoader after Pass 1
 # computes max node id. Allocates each parallel array to size `n`
 # with its default fill value in one shot, avoiding ~46 * n
 # individual Array#push calls (and the amortized realloc events
 # that come with them). Field setters then write into preallocated
 # slots by index.
  def alloc_nodes(n)
    @nd_type = Array.new(n, "")
    @nd_name = Array.new(n, "")
    @nd_value = Array.new(n, 0)
    @nd_content = Array.new(n, "")
    @nd_flags = Array.new(n, 0)
    @nd_operator = Array.new(n, "")
    @nd_binop = Array.new(n, "")
    @nd_callop = Array.new(n, "")
    @nd_unescaped = Array.new(n, "")
    @nd_receiver = Array.new(n, -1)
    @nd_arguments = Array.new(n, -1)
    @nd_body = Array.new(n, -1)
    @nd_block = Array.new(n, -1)
    @nd_parameters = Array.new(n, -1)
    @nd_predicate = Array.new(n, -1)
    @nd_subsequent = Array.new(n, -1)
    @nd_else_clause = Array.new(n, -1)
    @nd_left = Array.new(n, -1)
    @nd_right = Array.new(n, -1)
    @nd_constant_path = Array.new(n, -1)
    @nd_superclass = Array.new(n, -1)
    @nd_rest = Array.new(n, -1)
    @nd_keyword_rest = Array.new(n, -1)
    @nd_rescue_clause = Array.new(n, -1)
    @nd_ensure_clause = Array.new(n, -1)
    @nd_expression = Array.new(n, -1)
    @nd_target = Array.new(n, -1)
    @nd_pattern = Array.new(n, -1)
    @nd_key = Array.new(n, -1)
    @nd_reference = Array.new(n, -1)
    @nd_collection = Array.new(n, -1)
    @nd_stmts = Array.new(n, "")
    @nd_args = Array.new(n, "")
    @nd_requireds = Array.new(n, "")
    @nd_optionals = Array.new(n, "")
    @nd_keywords = Array.new(n, "")
    @nd_elements = Array.new(n, "")
    @nd_parts = Array.new(n, "")
    @nd_conditions = Array.new(n, "")
    @nd_exceptions = Array.new(n, "")
    @nd_targets = Array.new(n, "")
    @nd_rights = Array.new(n, "")
    @nd_posts = Array.new(n, "")
    @nd_new_name = Array.new(n, -1)
    @nd_old_name = Array.new(n, -1)
    @nd_names = Array.new(n, "")
    @nd_inferred_type = Array.new(n, "")
    @nd_scope_names = Array.new(n, "")
    @nd_scope_types = Array.new(n, "")
    @nd_count = n
  end

  def read_text_ast(data)
    loader = NodeTableLoader.new(self)
    loader.read_text_ast(data)
  end

  def set_root_id(root_id)
    @root_id = root_id
  end

  def set_node_type(nid, node_type)
    @nd_type[nid] = node_type
  end

  def set_node_content(nid, content)
    @nd_content[nid] = content
  end

 # `if`-chain (not `case`) — `case` over many string literals
 # measured ~58% slower on the codegen self-compile workload.
  def set_string_field(nid, field, val)
    if field == "name"
      @nd_name[nid] = val
    end
    if field == "content"
      @nd_content[nid] = val
    end
    if field == "value"
      @nd_content[nid] = val
    end
    if field == "operator"
      @nd_operator[nid] = val
    end
    if field == "binary_operator"
      @nd_binop[nid] = val
    end
    if field == "call_operator"
      @nd_callop[nid] = val
    end
    if field == "unescaped"
      @nd_unescaped[nid] = val
    end
    if field == "kind"
 # UnsupportedNode carries the Prism node-type name here so
 # codegen can surface a precise compile error.
      @nd_content[nid] = val
    end
  end

  def set_int_field(nid, field, val)
    if field == "value"
      @nd_value[nid] = val
    end
    if field == "flags"
      @nd_flags[nid] = val
    end
    if field == "number"
      @nd_value[nid] = val
    end
    if field == "maximum"
      @nd_value[nid] = val
    end
    if field == "start_line"
      @nd_value[nid] = val
    end
    if field == "source_line"
 # UnsupportedNode carries the source line so codegen can cite
 # location in the compile error.
      @nd_value[nid] = val
    end
  end

  def set_ref_field(nid, field, ref_id)
    if field == "receiver"
      @nd_receiver[nid] = ref_id
    end
    if field == "arguments"
      @nd_arguments[nid] = ref_id
    end
    if field == "body"
      @nd_body[nid] = ref_id
    end
    if field == "block"
      @nd_block[nid] = ref_id
    end
    if field == "parameters"
      @nd_parameters[nid] = ref_id
    end
    if field == "predicate"
      @nd_predicate[nid] = ref_id
    end
    if field == "subsequent"
      @nd_subsequent[nid] = ref_id
    end
    if field == "else_clause"
      @nd_else_clause[nid] = ref_id
    end
    if field == "left"
      @nd_left[nid] = ref_id
    end
    if field == "right"
      @nd_right[nid] = ref_id
    end
    if field == "constant_path"
      @nd_constant_path[nid] = ref_id
    end
    if field == "superclass"
      @nd_superclass[nid] = ref_id
    end
    if field == "rest"
      @nd_rest[nid] = ref_id
    end
    if field == "keyword_rest"
      @nd_keyword_rest[nid] = ref_id
    end
    if field == "rescue_clause"
      @nd_rescue_clause[nid] = ref_id
    end
    if field == "ensure_clause"
      @nd_ensure_clause[nid] = ref_id
    end
    if field == "expression"
      @nd_expression[nid] = ref_id
    end
    if field == "target"
      @nd_target[nid] = ref_id
    end
    if field == "pattern"
      @nd_pattern[nid] = ref_id
    end
    if field == "key"
      @nd_key[nid] = ref_id
    end
    if field == "reference"
      @nd_reference[nid] = ref_id
    end
    if field == "collection"
      @nd_collection[nid] = ref_id
    end
    if field == "statements"
      @nd_body[nid] = ref_id
    end
    if field == "value"
      @nd_expression[nid] = ref_id
    end
    if field == "index"
      @nd_target[nid] = ref_id
    end
    if field == "parent"
      @nd_receiver[nid] = ref_id
    end
    if field == "rescue_expression"
      @nd_else_clause[nid] = ref_id
    end
    if field == "call"
      @nd_receiver[nid] = ref_id
    end
    if field == "new_name"
 # AliasMethodNode / AliasGlobalVariableNode -- the new-name slot
 # (a SymbolNode for methods, GlobalVariableReadNode for globals).
      @nd_new_name[nid] = ref_id
    end
    if field == "old_name"
      @nd_old_name[nid] = ref_id
    end
  end

  def set_array_field(nid, field, ids_str)
    if field == "body"
      @nd_stmts[nid] = ids_str
    end
    if field == "arguments"
      @nd_args[nid] = ids_str
    end
    if field == "requireds"
      @nd_requireds[nid] = ids_str
    end
    if field == "optionals"
      @nd_optionals[nid] = ids_str
    end
    if field == "keywords"
      @nd_keywords[nid] = ids_str
    end
    if field == "elements"
      @nd_elements[nid] = ids_str
    end
    if field == "parts"
      @nd_parts[nid] = ids_str
    end
    if field == "conditions"
      @nd_conditions[nid] = ids_str
    end
    if field == "exceptions"
      @nd_exceptions[nid] = ids_str
    end
    if field == "lefts"
      @nd_targets[nid] = ids_str
    end
    if field == "targets"
      @nd_targets[nid] = ids_str
    end
    if field == "rights"
      @nd_rights[nid] = ids_str
    end
    if field == "posts"
      @nd_posts[nid] = ids_str
    end
    if field == "names"
 # UndefNode -- list of SymbolNode names to undef.
      @nd_names[nid] = ids_str
    end
  end

 # ---- Convenience: get stmts of a body node ----
  def get_stmts(nid)
    if nid < 0
      return []
    end
 # If it's a StatementsNode, return its stmts
    if @nd_type[nid] == "StatementsNode"
      return parse_id_list(@nd_stmts[nid])
    end
 # Otherwise return single-element array
    result = []
    result.push(nid)
    result
  end

end
