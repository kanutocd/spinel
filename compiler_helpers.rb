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

# CRuby bootstrap shim for compiler_state_* declarations. Spinel's
# analyzer/codegen consume these calls at compile time and emit concrete
# methods; this shim only keeps the Ruby-hosted bootstrap compiler
# executable while the compiled binaries are being rebuilt.
if RUBY_ENGINE == "ruby"
  class Module
    def compiler_state_entries; @compiler_state_entries ||= []; end

    def compiler_state_register(kind, names)
      names.each do |raw_name|
        compiler_state_entries << [kind.to_s, raw_name.to_s]
      end
      compiler_state_define_runtime_methods
    end

    def compiler_state_int(*names); compiler_state_register("int", names); end
    def compiler_state_str(*names); compiler_state_register("str", names); end
    def compiler_state_sa(*names); compiler_state_register("sa", names); end
    def compiler_state_ia(*names); compiler_state_register("ia", names); end

    def compiler_state_define_runtime_methods
      return if @compiler_state_runtime_methods_defined

      @compiler_state_runtime_methods_defined = true

      define_method(:init_compiler_state) do
        self.class.compiler_state_entries.each do |kind, name|
          val = 0
          if kind == "str"
            val = ""
          elsif kind == "sa"
            val = []
          elsif kind == "ia"
            val = []
          end
          instance_variable_set("@" + name, val)
        end
        0
      end

      define_method(:dump_compiler_state_ir) do |buf|
        self.class.compiler_state_entries.each do |kind, name|
          ir_name = "@" + name
          val = instance_variable_get(ir_name)
          if kind == "int"
            buf = ir_emit_int(buf, ir_name, val)
          elsif kind == "str"
            buf = ir_emit_str(buf, ir_name, val)
          elsif kind == "sa"
            buf = ir_emit_sa(buf, ir_name, val)
          elsif kind == "ia"
            buf = ir_emit_ia(buf, ir_name, val)
          end
        end
        buf
      end

      define_method(:compiler_state_set_runtime) do |kind, name, val|
        self.class.compiler_state_entries.each do |entry_kind, field|
          if entry_kind == kind && name == "@" + field
            instance_variable_set(name, val)
          end
        end
        0
      end

      define_method(:compiler_state_set_int) { |name, val| compiler_state_set_runtime("int", name, val) }
      define_method(:compiler_state_set_str) { |name, val| compiler_state_set_runtime("str", name, val) }
      define_method(:compiler_state_set_sa) { |name, val| compiler_state_set_runtime("sa", name, val) }
      define_method(:compiler_state_set_ia) { |name, val| compiler_state_set_runtime("ia", name, val) }
    end
  end
end

class Compiler

 # ---- Compile-time class-body declaration helpers ----

  compiler_state_int :nd_count, :root_id, :analysis_frozen, :ieval_counter, :iexec_counter, :needs_gc, :needs_system
  compiler_state_int :needs_int_array, :needs_float_array, :needs_str_array, :needs_str_int_hash, :needs_str_str_hash, :needs_int_str_hash
  compiler_state_int :needs_sym_int_hash, :needs_sym_str_hash, :needs_sym_intern, :needs_setjmp, :needs_mutable_str, :needs_rb_value
  compiler_state_int :needs_regexp, :needs_rand, :needs_stringio, :needs_lambda, :needs_fiber, :needs_bigint
  compiler_state_int :needs_poly_array, :needs_poly_poly_hash, :needs_str_poly_hash, :needs_sym_poly_hash, :needs_ptr_array, :needs_file_io

  compiler_state_str :cls_cmeth_live, :cls_meth_live

  compiler_state_sa :meth_names, :meth_param_names, :meth_param_types, :meth_param_empty, :meth_return_types, :meth_has_defaults
  compiler_state_sa :cls_names, :cls_parents, :cls_includes, :cls_ivar_names, :cls_ivar_types, :cls_ivar_init_definite
  compiler_state_sa :cls_ivar_observed_types, :cls_meth_names, :cls_meth_params, :cls_meth_ptypes, :cls_meth_returns, :cls_meth_bodies
  compiler_state_sa :cls_rest_keys, :dead_mod_cls_meths, :cls_meth_defaults, :cls_meth_ptypes_empty, :cls_meth_prep_chain, :cls_attr_readers
  compiler_state_sa :cls_attr_writers, :cls_cmeth_names, :cls_cmeth_params, :cls_cmeth_ptypes, :cls_cmeth_returns, :cls_cmeth_bodies
  compiler_state_sa :cls_cmeth_defaults, :cls_cmeth_scope_names, :cls_cmeth_scope_types, :cls_meth_has_yield, :cls_method_adapters, :const_names
  compiler_state_sa :const_types, :const_scope_names, :const_init_class, :cvar_names, :cvar_types, :cvar_init_values
  compiler_state_sa :gvar_names, :gvar_types, :module_names, :module_includes, :module_acc_keys, :module_acc_consts
  compiler_state_sa :ffi_modules, :ffi_module_libs, :ffi_module_cflags, :ffi_func_modules, :ffi_func_names, :ffi_func_arg_types
  compiler_state_sa :ffi_func_ret_types, :ffi_func_arg_specs, :ffi_func_ret_specs, :ffi_buf_modules, :ffi_buf_names, :ffi_reader_modules
  compiler_state_sa :ffi_reader_names, :ffi_reader_kinds, :regexp_patterns, :regexp_flags, :dyn_regex_flags, :local_regex_names
  compiler_state_sa :open_class_names, :method_ref_vars, :method_ref_names, :galias_new, :galias_old, :undef_method
  compiler_state_sa :sym_names, :tuple_types, :poly_funcs, :poly_param_types, :ieval_return_types, :ieval_self_param_names
  compiler_state_sa :ieval_extra_param_names, :compile_time_subst_keys, :compile_time_subst_vals, :cls_with_internal_ieval_lift, :toplevel_ivar_names, :toplevel_ivar_types
  compiler_state_sa :lambda_var_ret_names, :lambda_var_ret_types, :multi_const_inits, :meth_blk_param_types, :cls_cmeth_blk_param_types
  compiler_state_sa :iexec_block_pnames, :iexec_block_ptypes

  compiler_state_ia :meth_body_ids, :meth_rest_index, :meth_kwrest_index, :meth_has_yield, :cls_rest_idxs, :cls_is_value_type
  compiler_state_ia :cls_is_sra, :const_expr_ids, :const_mutated, :gvar_written, :module_body_ids, :ffi_buf_sizes, :ffi_reader_offsets
  compiler_state_ia :dyn_regex_node_ids, :local_regex_idx, :local_regex_call_nids, :undef_class_idx, :ieval_class_idxs, :ieval_body_ids
  compiler_state_ia :pre_execution_blocks, :post_execution_blocks
  compiler_state_ia :iexec_class_idxs, :iexec_body_ids

  def compiler_state_init_body_id; -31; end
  def compiler_state_dump_body_id; -32; end
  def compiler_state_set_int_body_id; -33; end
  def compiler_state_set_str_body_id; -34; end
  def compiler_state_set_sa_body_id; -35; end
  def compiler_state_set_ia_body_id; -36; end

  def compiler_state_synthetic_body_id?(bid)
    if bid <= compiler_state_init_body_id && bid >= compiler_state_set_ia_body_id
      return 1
    end
    0
  end

  def compiler_state_macro_kind(mn)
    return "int" if mn == "compiler_state_int"
    return "str" if mn == "compiler_state_str"
    return "sa" if mn == "compiler_state_sa"
    return "ia" if mn == "compiler_state_ia"
    ""
  end

  def compiler_state_field_type(kind)
    return "string" if kind == "str"
    return "str_array" if kind == "sa"
    return "int_array" if kind == "ia"
    "int"
  end

  def compile_time_subst_key(ci, mname, bid, varname)
    ci.to_s + ":" + mname + ":" + bid.to_s + ":" + varname
  end

  def compile_time_subst_lookup(ci, mname, bid, varname)
    if ci < 0 || mname == "" || varname == ""
      return ""
    end
    key = compile_time_subst_key(ci, mname, bid, varname)
    i = 0
    while i < @compile_time_subst_keys.length
      if @compile_time_subst_keys[i] == key
        if i < @compile_time_subst_vals.length
          return @compile_time_subst_vals[i]
        end
        return ""
      end
      i = i + 1
    end
    ""
  end

  def compile_time_subst_for_current(varname)
    if @current_class_idx < 0 || @current_method_name == ""
      return ""
    end
    midx = cls_find_method_direct(@current_class_idx, @current_method_name)
    if midx < 0
      return ""
    end
    bodies = @cls_meth_bodies[@current_class_idx].split(";", -1)
    if midx >= bodies.length
      return ""
    end
    compile_time_subst_lookup(@current_class_idx, @current_method_name, bodies[midx].to_i, varname)
  end

  def compile_time_literal_type(encoded)
    if encoded.start_with?("sym:")
      return "symbol"
    end
    if encoded.start_with?("str:")
      return "string"
    end
    if encoded.start_with?("int:")
      return "int"
    end
    ""
  end

  def compile_time_literal_payload(encoded)
    parts = encoded.split(":", -1)
    if parts.length < 2
      return ""
    end
    payload = ""
    i = 1
    while i < parts.length
      if i > 1
        payload = payload + ":"
      end
      payload = payload + parts[i]
      i = i + 1
    end
    payload
  end

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
  def poly_dispatch_return_type(mname, nid = -1, arg_types = "".split(","))
 # arg_types defaults to an empty StrArray rather than nil so the
 # nil-default + typed-callsite widening that #634 enables doesn't
 # collapse this param's slot to poly. Both call sites always pass
 # a concrete StrArray, so the empty default is observationally
 # equivalent to the prior nil-then-replace.
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
        elsif (at_b == "int" && pt_b == "bigint") || (at_b == "bigint" && pt_b == "int")
 # promote mode: int and bigint coerce at the call boundary via
 # sp_bigint_new_int / sp_bigint_to_int.
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

 # The enclosing module's name when `self` denotes a module -- i.e.
 # inside a module body or a `def self.x` module class-method.
 # current_lexical_scope_name already yields the module name in both
 # contexts (directly from @current_lexical_scope for a body, or by
 # stripping `_cls_<m>` off @current_method_name for a class method);
 # this just gates it on the scope actually being a module so `self`
 # in a plain class isn't mistaken for a module singleton receiver.
 # Returns "" when self is not a module. Used to route `self.<acc>` /
 # `self.<acc> = v` to the same module-singleton-accessor slot that
 # `Mod.<acc>` resolves to.
  def current_module_scope
    scope = current_lexical_scope_name
    if scope != "" && module_name_exists(scope) == 1
      return scope
    end
    ""
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
    @nd_line.push(0)   # keep the source-map arrays parallel with the rest, so a
    @nd_file.push(0)   # dynamically-allocated node can't drift them out of sync
    @nd_col.push(0)    # (and the self-host inferencer needs the literal push here)
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
    @nd_rat_num.push("")
    @nd_rat_den.push("")
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
    @nd_line = Array.new(n, 0)
    @nd_file = Array.new(n, 0)
    @nd_col = Array.new(n, 0)
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
 # Issue #841: RationalNode literal slots.
    @nd_rat_num = Array.new(n, "")
    @nd_rat_den = Array.new(n, "")
    @nd_count = n
  end

  def read_text_ast(data)
    loader = NodeTableLoader.new(self)
    loader.read_text_ast(data)
  end

  def set_root_id(root_id)
    @root_id = root_id
  end

 # Issue #878: parser emits SOURCE_FILE near the top so __dir__
 # (and similar compile-time helpers) can recover the path
 # without scanning for SourceFileNode entries.
  def set_source_file_path(path)
    @source_file_path = path
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
 # Issue #841: RationalNode carries numerator and denominator
 # as decimal-text strings (loaded into separate slots so
 # codegen can synthesize sp_rational_new(num, den) literals).
    if field == "rat_num"
      @nd_rat_num[nid] = val
    end
    if field == "rat_den"
      @nd_rat_den[nid] = val
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
 # Debug builds only (SPINEL_DEBUG=1): the parser stamps every node
 # with its 1-based source line in a dedicated slot so codegen can
 # emit `#line` directives. Kept separate from @nd_value, which is
 # overloaded for integer/float literal values, numbered-param max, etc.
    if field == "node_line"
      @nd_line[nid] = val
    end
 # Debug multi-file map: id into the FILE table (0 = toplevel source).
    if field == "node_file"
      @nd_file[nid] = val
    end
 # Debug/types export: 0-based source column for hover position keys.
    if field == "node_col"
      @nd_col[nid] = val
    end
  end

 # Debug multi-file map: record a FILE <id> <path> table entry emitted by
 # the parser. Grown on demand so ids can arrive in any order.
  def set_file_entry(id, path)
 # The analyze/codegen consumers initialize @file_table = []; this shared
 # helper assumes the slot exists. A bare `@file_table ||= []` fallback is
 # unsafe under self-host inference: the empty literal lowers to IntArray
 # and collides with the PolyArray-typed slot, breaking the build.
    while @file_table.length <= id
      @file_table.push("")
    end
    @file_table[id] = path
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
 # Issue #840: ImaginaryNode "numeric" field carries the imaginary
 # coefficient (IntegerNode or FloatNode); reuse the @nd_expression
 # slot so codegen reads it the same way.
    if field == "numeric"
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

 # Resolve `class CONST` (and `module`) where CONST is a constant
 # aliased to an existing class via `CONST = SomeClass` or
 # `CONST = <literal-or-class>.class`, so the body reopens that class
 # rather than defining a fresh one named after the alias (#1036:
 # `INTEGER_KLASS = 1.class; class INTEGER_KLASS; include M; end`).
 #
 # Runs in BOTH analyze and codegen (each loads its own AST) before any
 # class collection, and rewrites the ClassNode's constant_path name in
 # place. Doing it at the source means every downstream name derivation
 # sees the resolved name -- no half-applied alias where methods land
 # on one class index and dispatch resolves another.
  def resolve_class_aliases
    root = @root_id
    if @nd_type[root] != "ProgramNode"
      return
    end
    class_names = "".split(",", -1)
    collect_classnode_names(root, class_names)
    amap_from = "".split(",", -1)
    amap_to = "".split(",", -1)
    build_class_alias_map(root, class_names, amap_from, amap_to)
    if amap_from.length == 0
      return
    end
    rewrite_class_alias_refs(root, amap_from, amap_to)
  end

  def collect_classnode_names(nid, acc)
    if nid < 0
      return
    end
    if @nd_type[nid] == "ClassNode"
      cp = @nd_constant_path[nid]
      if cp >= 0 && @nd_type[cp] == "ConstantReadNode"
        nm = @nd_name[cp]
        if not_in(nm, acc) == 1
          acc.push(nm)
        end
      end
    end
    kids = []
    push_child_ids(nid, kids)
    k = 0
    while k < kids.length
      collect_classnode_names(kids[k], acc)
      k = k + 1
    end
  end

 # The class a literal node is an instance of, for `<lit>.class`.
  def literal_class_name(nid)
    if nid < 0
      return ""
    end
    t = @nd_type[nid]
    if t == "IntegerNode"
      return "Integer"
    end
    if t == "FloatNode"
      return "Float"
    end
    if t == "StringNode"
      return "String"
    end
    if t == "SymbolNode"
      return "Symbol"
    end
    if t == "ArrayNode"
      return "Array"
    end
    if t == "HashNode"
      return "Hash"
    end
    if t == "RegularExpressionNode"
      return "Regexp"
    end
    if t == "TrueNode"
      return "TrueClass"
    end
    if t == "FalseNode"
      return "FalseClass"
    end
    if t == "NilNode"
      return "NilClass"
    end
    ""
  end

  def is_builtin_class_const(name)
    builtins = "Integer;Float;String;Symbol;Array;Hash;Object;BasicObject;Numeric;Regexp;Range;Proc;Exception;StandardError;Comparable;Enumerable;Kernel;Module;Class".split(";", -1)
    if not_in(name, builtins) == 0
      return 1
    end
    0
  end

 # Resolve a constant's RHS value-node to the class name it aliases, or
 # "" when it isn't a class alias.
  def class_alias_target(rhs, class_names)
    if rhs < 0
      return ""
    end
    t = @nd_type[rhs]
    if t == "ConstantReadNode"
      nm = @nd_name[rhs]
      if not_in(nm, class_names) == 0 || is_builtin_class_const(nm) == 1
        return nm
      end
      return ""
    end
    if t == "CallNode" && @nd_name[rhs] == "class"
      recv = @nd_receiver[rhs]
      if recv < 0
        return ""
      end
      lc = literal_class_name(recv)
      if lc != ""
        return lc
      end
      if @nd_type[recv] == "ConstantReadNode"
        rnm = @nd_name[recv]
        if not_in(rnm, class_names) == 0 || is_builtin_class_const(rnm) == 1
          return rnm
        end
      end
    end
    ""
  end

  def build_class_alias_map(nid, class_names, amap_from, amap_to)
    if nid < 0
      return
    end
    if @nd_type[nid] == "ConstantWriteNode"
      cname = @nd_name[nid]
      tgt = class_alias_target(@nd_expression[nid], class_names)
 # Only treat it as a class alias when it resolves to a DIFFERENT
 # name (`Foo = Foo` / a class's own const are not aliases) and isn't
 # already recorded.
      if tgt != "" && tgt != cname && not_in(cname, amap_from) == 1
        amap_from.push(cname)
        amap_to.push(tgt)
      end
    end
    kids = []
    push_child_ids(nid, kids)
    k = 0
    while k < kids.length
      build_class_alias_map(kids[k], class_names, amap_from, amap_to)
      k = k + 1
    end
  end

  def rewrite_class_alias_refs(nid, amap_from, amap_to)
    if nid < 0
      return
    end
    if @nd_type[nid] == "ClassNode"
      cp = @nd_constant_path[nid]
      if cp >= 0 && @nd_type[cp] == "ConstantReadNode"
        nm = @nd_name[cp]
        ai = 0
        while ai < amap_from.length
          if amap_from[ai] == nm
            set_string_field(cp, "name", amap_to[ai])
            ai = amap_from.length
          end
          ai = ai + 1
        end
      end
    end
    kids = []
    push_child_ids(nid, kids)
    k = 0
    while k < kids.length
      rewrite_class_alias_refs(kids[k], amap_from, amap_to)
      k = k + 1
    end
  end

 # ---- Module#instance_methods(false) const-fold support ----
 # `Klass.instance_methods(false)` reports a class/module's own (non-
 # inherited) instance-method names. For a *compiled* user class/module
 # that set is statically known, so the call folds to a literal symbol
 # array. These helpers are shared so the analyze pass (symbol-table
 # registration + result typing) and the codegen pass (the fold) agree
 # exactly -- a name set or gate that drifted between passes would emit
 # a `sym_array`-typed slot the other side can't populate.

 # Resolved const name iff `nid` is a foldable
 # `<ConstantRead>.instance_methods(false)` call, else "". Receiver
 # resolution is context-free (the raw constant name) on purpose: the
 # gate must be identical in a flat symbol-collection walk and in a
 # class-scoped emit, so it deliberately does NOT consult lexical
 # scope. ConstantPath receivers and the no-arg / `true` forms fall
 # through unfolded (and stay untyped), matching today's behaviour.
  def instance_methods_fold_target(nid)
    recv = @nd_receiver[nid]
    if recv < 0 || @nd_type[recv] != "ConstantReadNode"
      return ""
    end
    aid = @nd_arguments[nid]
    if aid < 0
      return ""
    end
    aargs = get_args(aid)
    if aargs.length != 1 || @nd_type[aargs[0]] != "FalseNode"
      return ""
    end
    cn = @nd_name[recv]
    if instance_methods_fold_const?(cn) == 0
      return ""
    end
    cn
  end

 # 1 iff `cname` is a user-defined class or module whose own instance-
 # method set is statically known. Built-in classes (Integer, String,
 # ...) aren't in @cls_names, so they fall through -- spinel can't
 # enumerate their native method tables.
  def instance_methods_fold_const?(cname)
    if cname == ""
      return 0
    end
    if find_class_idx(cname) >= 0
      return 1
    end
    mi = 0
    while mi < @module_names.length
      if @module_names[mi] == cname
        return 1
      end
      mi = mi + 1
    end
    0
  end

 # Ordered, de-duplicated own instance-method names (as strings) for a
 # foldable const. Class: attr readers + `=`-suffixed writers + method
 # table (matches class_has_method_local, which method_defined? uses).
 # Module: body `def`s excluding `def self.x` and module_function
 # promotions, plus attr accessors. spinel doesn't model visibility, so
 # private defs are included -- consistent with method_defined?.
  def instance_methods_own_names(cname)
    acc = "".split(";", -1)
    ci = find_class_idx(cname)
    if ci >= 0
      im_push_names(acc, @cls_attr_readers[ci].split(";", -1), "")
      im_push_names(acc, @cls_attr_writers[ci].split(";", -1), "=")
      im_push_names(acc, @cls_meth_names[ci].split(";", -1), "")
      return acc
    end
    mi = 0
    while mi < @module_names.length
      if @module_names[mi] == cname && mi < @module_body_ids.length
        im_push_module_body(acc, @module_body_ids[mi])
      end
      mi = mi + 1
    end
    acc
  end

  def im_push_names(acc, names, suffix)
    k = 0
    while k < names.length
      if names[k] != ""
        full = names[k] + suffix
        if not_in(full, acc) == 1
          acc.push(full)
        end
      end
      k = k + 1
    end
  end

  def im_push_module_body(acc, body)
    if body < 0
      return
    end
    stmts = get_stmts(body)
 # Pre-scan `module_function :a, :b` named promotions: those defs
 # become class methods, not instance methods.
    mf_named = "".split(";", -1)
    si = 0
    while si < stmts.length
      sid = stmts[si]
      if @nd_type[sid] == "CallNode" && @nd_receiver[sid] < 0 && @nd_name[sid] == "module_function"
        aid = @nd_arguments[sid]
        if aid >= 0
          margs = get_args(aid)
          mk = 0
          while mk < margs.length
            if @nd_type[margs[mk]] == "SymbolNode" || @nd_type[margs[mk]] == "StringNode"
              mf_named.push(@nd_content[margs[mk]])
            end
            mk = mk + 1
          end
        end
      end
      si = si + 1
    end
 # `module_function` (no args) flips subsequent bare `def`s into
 # class methods. `def self.x` is always a class method.
    in_mf = 0
    si = 0
    while si < stmts.length
      sid = stmts[si]
      t = @nd_type[sid]
      if t == "CallNode" && @nd_receiver[sid] < 0
        cn = @nd_name[sid]
        if cn == "module_function"
          aid2 = @nd_arguments[sid]
          if aid2 < 0 || get_args(aid2).length == 0
            in_mf = 1
          end
        end
        if cn == "attr_reader" || cn == "attr_accessor"
          im_push_attr_args(acc, sid, "")
        end
        if cn == "attr_writer" || cn == "attr_accessor"
          im_push_attr_args(acc, sid, "=")
        end
      end
      if t == "DefNode" && @nd_receiver[sid] < 0 && in_mf == 0
        dn = @nd_name[sid]
        if not_in(dn, mf_named) == 1 && not_in(dn, acc) == 1
          acc.push(dn)
        end
      end
      si = si + 1
    end
  end

  def im_push_attr_args(acc, sid, suffix)
    aid = @nd_arguments[sid]
    if aid < 0
      return
    end
    aargs = get_args(aid)
    k = 0
    while k < aargs.length
      if @nd_type[aargs[k]] == "SymbolNode" || @nd_type[aargs[k]] == "StringNode"
        full = @nd_content[aargs[k]] + suffix
        if not_in(full, acc) == 1
          acc.push(full)
        end
      end
      k = k + 1
    end
  end

end
