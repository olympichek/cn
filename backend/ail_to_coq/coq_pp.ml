open Format
open Extra
open Panic
open Coq_ast
open Rc_annot

let pp_str = pp_print_string

let pp_as_tuple : 'a pp -> 'a list pp = fun pp ff xs ->
  match xs with
  | []      -> pp_str ff "()"
  | [x]     -> pp ff x
  | x :: xs -> fprintf ff "(%a" pp x;
               List.iter (fprintf ff ", %a" pp) xs;
               pp_str ff ")"

let pp_as_tuple_pat : 'a pp -> 'a list pp = fun pp ff xs ->
  if List.length xs > 1 then pp_str ff "'";
  pp_as_tuple pp ff xs

let pp_sep : string -> 'a pp -> 'a list pp = fun sep pp ff xs ->
  match xs with
  | []      -> ()
  | x :: xs -> pp ff x; List.iter (fprintf ff "%s%a" sep pp) xs

let pp_as_prod : 'a pp -> 'a list pp = fun pp ff xs ->
  match xs with
  | [] -> pp_str ff "()"
  | _  -> pp_sep " * " pp ff xs

let pp_int_type : Coq_ast.int_type pp = fun ff it ->
  let pp fmt = Format.fprintf ff fmt in
  match it with
  | ItSize_t(true)      -> pp "ssize_t"
  | ItSize_t(false)     -> pp "size_t"
  | ItI8(true)          -> pp "i8"
  | ItI8(false)         -> pp "u8"
  | ItI16(true)         -> pp "i16"
  | ItI16(false)        -> pp "u16"
  | ItI32(true)         -> pp "i32"
  | ItI32(false)        -> pp "u32"
  | ItI64(true)         -> pp "i64"
  | ItI64(false)        -> pp "u64"
  | ItBool              -> pp "bool_it"

let rec pp_layout : Coq_ast.layout pp = fun ff layout ->
  let pp fmt = Format.fprintf ff fmt in
  match layout with
  | LVoid              -> pp "LVoid"
  | LPtr               -> pp "LPtr"
  | LStruct(id, false) -> pp "layout_of struct_%s" id
  | LStruct(id, true ) -> pp "ul_layout union_%s" id
  | LInt(i)            -> pp "it_layout %a" pp_int_type i
  | LArray(layout, n)  -> pp "mk_array_layout (%a) %s" pp_layout layout n

let pp_op_type : Coq_ast.op_type pp = fun ff ty ->
  let pp fmt = Format.fprintf ff fmt in
  match ty with
  | OpInt(i) -> pp "IntOp %a" pp_int_type i
  | OpPtr(_) -> pp "PtrOp" (* FIXME *)

let pp_un_op : Coq_ast.un_op pp = fun ff op ->
  let pp fmt = Format.fprintf ff fmt in
  match op with
  | NotBoolOp  -> pp "NotBoolOp"
  | NotIntOp   -> pp "NotIntOp"
  | NegOp      -> pp "NegOp"
  | CastOp(ty) -> pp "(CastOp $ %a)" pp_op_type ty

let pp_bin_op : Coq_ast.bin_op pp = fun ff op ->
  pp_str ff @@
  match op with
  | AddOp       -> "+"
  | SubOp       -> "-"
  | MulOp       -> "×"
  | DivOp       -> "/"
  | ModOp       -> "%"
  | AndOp       -> "..." (* TODO *)
  | OrOp        -> "..." (* TODO *)
  | XorOp       -> "..." (* TODO *)
  | ShlOp       -> "..." (* TODO *)
  | ShrOp       -> "..." (* TODO *)
  | EqOp        -> "="
  | NeOp        -> "!="
  | LtOp        -> "<"
  | GtOp        -> ">"
  | LeOp        -> "≤"
  | GeOp        -> "≥"
  | RoundDownOp -> "..." (* TODO *)
  | RoundUpOp   -> "..." (* TODO *)

let rec pp_expr : Coq_ast.expr pp = fun ff e ->
  let pp fmt = Format.fprintf ff fmt in
  match e with
  | Var(None   ,_)                ->
      pp "\"_\""
  | Var(Some(x),g)                ->
      if g then pp_str ff x else fprintf ff "\"%s\"" x
  | Val(Null)                     ->
      pp "NULL"
  | Val(Void)                     ->
      pp "VOID"
  | Val(Int(s,it))                ->
      pp "i2v %s %a" s pp_int_type it
  | UnOp(op,ty,e)                 ->
      pp "UnOp %a (%a) (%a)" pp_un_op op pp_op_type ty pp_expr e
  | BinOp(op,ty1,ty2,e1,e2)       ->
      begin
        match (ty1, ty2, op) with
        | (OpPtr(l), OpInt(_), AddOp) ->
            pp "(%a) at_offset{%a, PtrOp, %a} (%a)" pp_expr e1
              pp_layout l pp_op_type ty2 pp_expr e2
        | (OpPtr(_), OpInt(_), _) ->
            panic_no_pos "Binop [%a] not supported on pointers." pp_bin_op op
        | (OpInt(_), OpPtr(_), _) ->
            panic_no_pos "Wrong ordering of integer pointer binop [%a]."
              pp_bin_op op
        | _                 ->
            pp "(%a) %a{%a, %a} (%a)" pp_expr e1 pp_bin_op op
              pp_op_type ty1 pp_op_type ty2 pp_expr e2
      end
  | Deref(lay,e)                  ->
      pp "!{%a} (%a)" pp_layout lay pp_expr e
  | CAS(ty,e1,e2,e3)              ->
      pp "CAS@ (%a)@ (%a)@ (%a)@ (%a)" pp_op_type ty
        pp_expr e1 pp_expr e2 pp_expr e3
  | SkipE(e)                      ->
      pp "SkipE (%a)" pp_expr e
  | Use(lay,e)                    ->
      pp "use{%a} (%a)" pp_layout lay pp_expr e
  | AddrOf(e)                     ->
      pp "&(%a)" pp_expr e
  | GetMember(e,name,false,field) ->
      pp "(%a) at{struct_%s} %S" pp_expr e name field
  | GetMember(e,name,true ,field) ->
      pp "(%a) at_union{union_%s} %S" pp_expr e name field

let rec pp_stmt : Coq_ast.stmt pp = fun ff stmt ->
  let pp fmt = Format.fprintf ff fmt in
  match stmt with
  | Goto(id)               ->
      pp "Goto %S" id
  | Return(e)              ->
      pp "Return @[<hov 0>(%a)@]" pp_expr e
  | Assign(lay,e1,e2,stmt) ->
      pp "@[<hov 2>%a <-{ %a }@ %a ;@]@;%a"
        pp_expr e1 pp_layout lay pp_expr e2 pp_stmt stmt
  | Call(ret_id,e,es,stmt) ->
      let pp_args _ es =
        let n = List.length es in
        let fn i e =
          let sc = if i = n - 1 then "" else " ;" in
          pp "%a%s@;" pp_expr e sc
        in
        List.iteri fn es
      in
      pp "@[<hov 2>%S <- %a with@ [ @[<hov 2>%a@] ] ;@]@;%a"
        (Option.get "_" ret_id) pp_expr e pp_args es pp_stmt stmt
  | SkipS(stmt)            ->
      pp_stmt ff stmt
  | If(e,stmt1,stmt2)      ->
      pp "if: @[<hov 0>%a@]@;then@;@[<v 2>%a@]@;else@;@[<v 2>%a@]"
        pp_expr e pp_stmt stmt1 pp_stmt stmt2
  | Assert(e, stmt)        ->
      pp "assert: (%a) ;@;%a" pp_expr e pp_stmt stmt
  | ExprS(annot, e, stmt)  ->
      Option.iter (Option.iter (pp "annot: (%s) ;@;")) annot;
      pp "expr: (%a) ;@;%a" pp_expr e pp_stmt stmt

type import = string * string

let pp_import ff (from, mod_name) =
  Format.fprintf ff "From %s Require Import %s.@;" from mod_name

let pp_code : import list -> Coq_ast.t pp = fun imports ff ast ->
  (* Formatting utilities. *)
  let pp fmt = Format.fprintf ff fmt in

  (* Printing some header. *)
  pp "@[<v 0>From refinedc.lang Require Export notation.@;";
  pp "From refinedc.lang Require Import tactics.@;";
  pp "From refinedc.typing Require Import annotations.@;";
  List.iter (pp_import ff) imports;
  pp "Set Default Proof Using \"Type\".@;@;";

  (* Printing generation data in a comment. *)
  pp "(* Generated from [%s]. *)@;" ast.source_file;

  (* Opening the section. *)
  pp "@[<v 2>Section code.@;";

  (* Declaration of objects (global variable) in the context. *)
  pp "(* Global variables. *)@;";
  let pp_global_var = pp "Context (%s : loc).@;" in
  List.iter pp_global_var ast.global_vars;

  (* Declaration of functions in the context. *)
  pp "@;(* Functions. *)@;";
  let pp_func_decl (id, _) = pp "Context (%s : loc).@;" id in
  List.iter pp_func_decl ast.functions;

  (* Printing for struct/union members. *)
  let pp_members members =
    let n = List.length members in
    let fn i (id, (attrs, layout)) =
      let sc = if i = n - 1 then "" else ";" in
      pp "@;(%S, %a)%s" id pp_layout layout sc
    in
    List.iteri fn members
  in

  (* Definition of structs/unions. *)
  let pp_struct (id, decl) =
    pp "@;(* Definition of struct [%s]. *)@;" id;
    pp "@[<v 2>Program Definition struct_%s := {|@;" id;

    pp "@[<v 2>sl_members := [";
    pp_members decl.struct_members;
    pp "@]@;];@]@;|}.@;";
    pp "Solve Obligations with solve_struct_obligations.@;"
  in
  let pp_union (id, decl) =
    pp "@;(* Definition of union [%s]. *)@;" id;
    pp "@[<v 2>Program Definition union_%s := {|@;" id;

    pp "@[<v 2>ul_members := [";
    pp_members decl.struct_members;
    pp "@]@;];@]@;|}.@;";
    pp "Solve Obligations with solve_struct_obligations.@;"
  in
  let rec sort_structs found strs =
    match strs with
    | []                     -> []
    | (id, s) as str :: strs ->
    if List.for_all (fun id -> List.mem id found) s.struct_deps then
      str :: sort_structs (id :: found) strs
    else
      sort_structs found (strs @ [str])
  in
  let pp_struct_union ((_, {struct_is_union; _}) as s) =
    if struct_is_union then pp_union s else pp_struct s
  in
  List.iter pp_struct_union (sort_structs [] ast.structs);

  (* Definition of functions. *)
  let pp_function (id, def) =
    pp "\n@;(* Definition of function [%s]. *)@;" id;
    pp "@[<v 2>Definition impl_%s : function := {|@;" id;

    pp "@[<v 2>f_args := [";
    begin
      let n = List.length def.func_args in
      let fn i (id, layout) =
        let sc = if i = n - 1 then "" else ";" in
        pp "@;(%S, %a)%s" id pp_layout layout sc
      in
      List.iteri fn def.func_args
    end;
    pp "@]@;];@;";

    pp "@[<v 2>f_local_vars := [";
    begin
      let n = List.length def.func_vars in
      let fn i (id, layout) =
        let sc = if i = n - 1 then "" else ";" in
        pp "@;(%S, %a)%s" id pp_layout layout sc
      in
      List.iteri fn def.func_vars
    end;
    pp "@]@;];@;";

    pp "f_init := \"#0\";@;";

    pp "@[<v 2>f_code := (";
    begin
      let fn id (attrs, stmt) =
        pp "@;@[<v 2><[ \"%s\" :=@;" id;

        pp_stmt ff stmt;
        pp "@]@;]> $";
      in
      SMap.iter fn def.func_blocks;
      pp "∅"
    end;
    pp "@]@;)%%E";
    pp "@]@;|}.";
  in
  List.iter pp_function ast.functions;

  (* Closing the section. *)
  pp "@]@;End code.@]"

type guard_mode =
  | Guard_none
  | Guard_in_def of string
  | Guard_in_lem of string

let guard_mode = ref Guard_none

let pp_coq_expr : coq_expr pp = fun ff e ->
  match e with
  | Coq_ident(x) -> pp_str ff x
  | Coq_all(s)   -> fprintf ff "(%s)" s

let rec pp_constr : constr pp = fun ff c ->
  let pp_kind ff k =
    match k with
    | Own     -> pp_str ff "◁ₗ"
    | Shr     -> pp_str ff "◁ₗ{Shr}"
    | Frac(e) -> fprintf ff "◁ₗ{%a}" pp_coq_expr e
  in
  match c with
  | Constr_Iris(s)     -> pp_str ff s
  | Constr_exist(x,c)  -> fprintf ff "(∃ %s, %a)" x pp_constr c
  | Constr_own(x,k,ty) -> fprintf ff "%s %a %a" x pp_kind k pp_type_expr ty
  | Constr_Coq(e)      -> fprintf ff "⌜%a⌝" pp_coq_expr e

and pp_type_expr : type_expr pp = fun ff ty ->
  let pp_kind ff k =
    match k with
    | Own     -> pp_str ff "&own"
    | Shr     -> pp_str ff "&shr"
    | Frac(e) -> fprintf ff "&frac{%a}" pp_coq_expr e
  in
  let rec pp_patt ff p =
    match p with
    | Pat_var(x)    -> pp_str ff x
    | Pat_tuple(ps) -> fprintf ff "%a" (pp_as_tuple_pat pp_patt) ps
  in
  let rec pp wrap ff ty =
    match ty with
    (* Don't need wrapping. *)
    | Ty_Coq(e)         -> pp_coq_expr ff e
    | Ty_dots           -> Panic.panic_no_pos "Unexpected ellipsis."
    | Ty_params(id,[])  -> pp_str ff id
    (* Always wrapped. *)
    | Ty_lambda(p,ty)   -> fprintf ff "(λ %a, %a)" pp_patt p (pp false) ty
    (* Insert wrapping if needed. *)
    | _ when wrap       -> fprintf ff "(%a)" (pp false) ty
    (* Remaining constructors (no need for explicit wrapping). *)
    | Ty_refine(e,ty)   ->
        begin
          let normal () = fprintf ff "%a @@ %a" pp_coq_expr e (pp true) ty in
          match (!guard_mode, ty) with
          | (Guard_in_def(s), Ty_params(c,tys)) when c = s ->
              assert (tys = []); (* FIXME *)
              fprintf ff "guarded (nroot.@%S) " s;
              fprintf ff "(apply_dfun self %a)" pp_coq_expr e
          | (Guard_in_lem(s), Ty_params(c,tys)) when c = s ->
              assert (tys = []); (* FIXME *)
              fprintf ff "guarded (nroot.@%S) (" s; normal (); pp_str ff ")"
          | (_              , _               )            -> normal ()
        end
    | Ty_ptr(k,ty)      -> fprintf ff "%a %a" pp_kind k (pp true) ty
    | Ty_exists(x,ty)   -> fprintf ff "∃ %s, %a" x (pp false) ty
    | Ty_constr(ty,c)   -> assert false
    | Ty_params(id,tys) ->
    pp_str ff id;
    match (id, tys) with
    | ("optional", [ty]) -> fprintf ff " %a null" (pp true) ty
    | (_         , _   ) -> List.iter (fprintf ff " %a" (pp true)) tys
  in
  pp true ff ty

let pp_constrs : constr list pp = fun ff cs ->
  match cs with
  | []      -> pp_str ff "True"
  | c :: cs -> pp_constr ff c; List.iter (fprintf ff ", %a" pp_constr) cs

(* Functions for looking for recursive occurences of a type. *)

let in_coq_expr : string -> coq_expr -> bool = fun s e ->
  match e with
  | Coq_ident(x) -> x = s
  | Coq_all(e)   -> e = s (* In case of [{s}]. *)

let rec in_type_expr : string -> type_expr -> bool = fun s ty ->
  match ty with
  | Ty_refine(e,ty)  -> in_coq_expr s e || in_type_expr s ty
  | Ty_ptr(_,ty)     -> in_type_expr s ty
  | Ty_dots          -> false
  | Ty_exists(x,ty)  -> x <> s && in_type_expr s ty
  | Ty_lambda(p,ty)  -> assert false
  | Ty_constr(ty,c)  -> assert false
  | Ty_params(x,tys) -> x = s || List.exists (in_type_expr s) tys
  | Ty_Coq(e)        -> in_coq_expr s e

let pp_spec : import list -> Coq_ast.t pp = fun imports ff ast ->
  (* Stuff for import of the code. *)
  let basename =
    let name = Filename.basename ast.source_file in
    try Filename.chop_extension name with Invalid_argument(_) -> name
  in
  let import_path = "refinedc.examples." ^ basename in (* FIXME generic? *)

  (* Formatting utilities. *)
  let pp fmt = Format.fprintf ff fmt in

  (* Printing some header. *)
  pp "@[<v 0>From refinedc.typing Require Import typing.@;";
  pp "From %s Require Import %s_code.@;" import_path basename;
  List.iter (pp_import ff) imports;
  pp "Set Default Proof Using \"Type\".@;@;";

  (* Printing generation data in a comment. *)
  pp "(* Generated from [%s]. *)@;" ast.source_file;

  (* Opening the section. *)
  pp "@[<v 2>Section spec.@;";
  pp "Context `{typeG Σ}.";

  (* Definition of types. *)
  let pp_struct (id, s) =
    match s.struct_annot with None -> assert false | Some(annot) ->
    let fields =
      let fn (x, (ty_opt, _)) =
        match ty_opt with
        | Some(ty) -> (x, ty)
        | None     -> assert false
      in
      List.map fn s.struct_members
    in
    let (ref_names, ref_types) = List.split annot.st_refined_by in
    let is_rec = List.exists (fun (_,ty) -> in_type_expr id ty) fields in
    if is_rec then begin
      pp "@[<v 2>Definition %s_rec : (%a -d> typeO) → (%a -d> typeO) := " id
        (pp_as_prod pp_coq_expr) ref_types (pp_as_prod pp_coq_expr) ref_types;
      pp "(λ self %a,@;@[<hov 2>" (pp_as_tuple pp_print_string) ref_names;
      Option.iter (fun _ -> pp "padded (") annot.st_size;
      pp "struct struct_%s [" id;
      begin
        match fields with
        | []               -> ()
        | (_,ty) :: fields ->
        guard_mode := Guard_in_def(id);
        pp "@;%a" pp_type_expr ty;
        List.iter (fun (_,ty) -> pp " ;@;%a" pp_type_expr ty) fields;
        guard_mode := Guard_none
      end;
      pp "@]@;]";
      Option.iter (pp ") struct_%s %a" id pp_coq_expr) annot.st_size;
      pp "@]@;)%%I.@;Arguments %s_rec /.\n" id;

      pp "@;Global Instance %s_rec_ne : Contractive %s_rec." id id;
      pp "@;Proof. solve_type_proper. Qed.\n@;";

      pp "@[<v 2>Definition %s : rtype := {|@;" id;
      pp "rty_type := %a;@;" (pp_as_prod pp_coq_expr) ref_types;
      pp "rty := fixp %s_rec" id;
      pp "@]@;|}\n";

      (* Generation of the unfolding lemma. *)
      pp "@;@[<v 2>Lemma %s_unfold" id;
      List.iter (pp " %s") ref_names; pp " : (@;";
      pp "%a @@ %s ≡@@{type}@;" (pp_as_tuple pp_print_string) ref_names id;
      pp "@[<v 2>";
      Option.iter (fun _ -> pp "padded (") annot.st_size;
      pp "struct struct_%s [" id;
      begin
        match fields with
        | []               -> ()
        | (_,ty) :: fields ->
        guard_mode := Guard_in_lem(id);
        pp "@;%a" pp_type_expr ty;
        List.iter (fun (_,ty) -> pp " ;@;%a" pp_type_expr ty) fields;
        guard_mode := Guard_none
      end;
      pp "@]@;]";
      Option.iter (pp ") struct_%s %a" id pp_coq_expr) annot.st_size;
      pp "@]@;)%%I.@;";
      pp "Proof. by rewrite {1}/with_refinement/=fixp_unfold. Qed.\n";

      (* Generation of the global instances. *)
      let pp_instance inst_name type_name =
        pp "@;Global Instance %s_%s_inst l β" id inst_name;
        List.iter (pp " %s") ref_names; pp " :@;";
        pp "  %s l β (%a @@ %s)%%I (Some 100%%N) :=@;" type_name
          (pp_as_tuple pp_print_string) ref_names id;
        pp "  λ T, i2p (simplify_goal_place_eq l β _ _ T (%s_unfold" id;
        List.iter (fun _ -> pp " _") ref_names; pp "))."
      in
      pp_instance "simplify_hyp_place" "SimplifyHypPlace";
      pp_instance "simplify_goal_place" "SimplifyGoalPlace";


      pp "\n@;Global Program Instance %s_rmovable : RMovable (%s) :=@;" id id;
      pp "  {| rmovable arg := movable_eq _ _ (%s_unfold" id;
      List.iter (fun _ -> pp " _") ref_names; pp ")).";
      pp ") |}.@;Next Obligation. done. Qed."
    end else begin
      (* Definition of the [rtype]. *)
      pp "@[<v 2>Definition %s : rtype := {|@;" id;
      pp "rty_type := %a;@;" (pp_as_prod pp_coq_expr) ref_types;
      pp "@[<hov 2>rty %a := " (pp_as_tuple_pat pp_str) ref_names;
      Option.iter (fun _ -> pp "(padded (") annot.st_size;
      pp "struct struct_%s [" id;
      begin
        match fields with
        | []               -> ()
        | (_,ty) :: fields ->
        pp "@;%a" pp_type_expr ty;
        List.iter (fun (_,ty) -> pp " ;@;%a" pp_type_expr ty) fields
      end;
      pp "@]@;]";
      Option.iter (pp ") struct_%s %a)" id pp_coq_expr) annot.st_size;
      pp "%%I@]@;|}\n";
      (* Typeclass stuff. *)
      pp "@;Global Program Instance %s_movable : RMovable %s :=" id id;
      pp "@;  {| rmovable %a := _ |}." (pp_as_tuple pp_str) ref_names;
      pp "@;Next Obligation. unfold with_refinement => /= ?. ";
      pp "apply _. Defined.";
      pp "@;Next Obligation. solve_typing. Qed."
    end
  in
  let pp_union s =
    pp "(* Printing for Unions not implemented. *)" (* TODO *)
  in
  let pp_struct_union ((_, {struct_is_union; struct_name; _}) as s) =
    pp "\n@;(* Definition of type [%s]. *)@;" struct_name;
    if struct_is_union then pp_union s else pp_struct s
  in
  List.iter pp_struct_union ast.structs;

  (* Function specs. *)
  let pp_spec (id, def) =
    pp "\n@;(* Specifications for function [%s]. *)" id;
    match def.func_annot with None -> assert false | Some(annot) ->
    let (param_names, param_types) = List.split annot.fa_parameters in
    let (exist_names, exist_types) = List.split annot.fa_exists in
    let pp_args ff tys =
      match tys with
      | [] -> ()
      | _  -> pp "; "; pp_sep ", " pp_type_expr ff tys
    in
    pp "@;Definition type_of_%s " id;
    List.iter (pp "%s ") (fst def.func_deps);
    pp ":=@;  @[<hov 2>";
    pp "fn(∀ %a : %a%a; %a)@;→ ∃ %a : %a, %a; %a.@]"
      (pp_as_tuple pp_str) param_names (pp_as_prod pp_coq_expr) param_types
      pp_args annot.fa_args pp_constrs annot.fa_requires (pp_as_tuple pp_str)
      exist_names (pp_as_prod pp_coq_expr) exist_types pp_type_expr
      annot.fa_returns pp_constrs annot.fa_ensures
  in
  List.iter pp_spec ast.functions;

  (* Typing proofs. *)
  let pp_proof (id, def) =
    match def.func_annot with None -> assert false | Some(annot) ->
    let (used_globals, used_functions) = def.func_deps in
    let deps =
      (* This includes global variables on which the used function depend. *)
      let fn acc (id, def) =
        if List.mem id used_functions then fst def.func_deps @ acc else acc
      in
      let all_used_globals = List.fold_left fn used_globals ast.functions in
      let transitive_used_globals =
        (* Use filter to preserve definition order. *)
        List.filter (fun x -> List.mem x all_used_globals) ast.global_vars
      in
      transitive_used_globals @ used_functions
    in
    let pp_args ff xs =
      match xs with
      | [] -> ()
      | _  -> fprintf ff " (%a : loc)" (pp_sep " " pp_str) xs
    in
    pp "\n@;(* Typing proof for [%s]. *)@;" id;
    pp "@[<v 2>Lemma type_%s%a :@;" id pp_args deps;
    begin
      match used_functions with
      | [] -> pp "⊢ typed_function impl_%s type_of_%s." id id
      | _  ->
      let pp_impl ff id =
        let wrap = used_globals <> [] || used_functions <> [] in
        if wrap then fprintf ff "(";
        fprintf ff "impl_%s" id;
        List.iter (fprintf ff " %s") used_globals;
        List.iter (fprintf ff " %s") used_functions;
        if wrap then fprintf ff ")"
      in
      let pp_type ff id =
        let used_globals =
          try fst (List.assoc id ast.functions).func_deps
          with Not_found -> assert false
        in
        if used_globals <> [] then fprintf ff "(";
        fprintf ff "type_of_%s" id;
        List.iter (fprintf ff " %s") used_globals;
        if used_globals <> [] then fprintf ff ")"
      in
      let pp_dep f = pp "%s ◁ᵥ %s @@ function_ptr %a -∗@;" f f pp_type f in
      List.iter pp_dep used_functions;
      pp "typed_function %a %a." pp_impl id pp_type id
    end;
    let pp_intros ff xs =
      let pp_intro ff (x,_) = pp_str ff x in
      match xs with
      | [x] -> pp_intro ff x
      | _   -> fprintf ff "[%a]" (pp_sep " " pp_intro) xs
    in
    let pp_local_vars ff = List.iter (fun (x,_) -> pp " %s" x) in
    pp "@]@;@[<v 2>Proof.@;";
    pp "start_function (%a) =>%a.@;" pp_intros annot.fa_parameters
      pp_local_vars def.func_vars;
    pp "split_blocks (∅ : gmap block_id (iProp Σ)).@;";
    pp "repeat do_step; do_finish.@;";
    pp "Unshelve. all: try solve_goal.";
    pp "@]@;Qed."
  in
  List.iter pp_proof ast.functions;

  (* Closing the section. *)
  pp "@]@;End spec.@]"

type mode = Code | Spec

let write : import list -> mode -> string -> Coq_ast.t -> unit =
    fun imports mode fname ast ->
  let oc = open_out fname in
  let ff = Format.formatter_of_out_channel oc in
  let pp = match mode with Code -> pp_code | Spec -> pp_spec in
  Format.fprintf ff "%a@." (pp imports) ast;
  close_out oc
