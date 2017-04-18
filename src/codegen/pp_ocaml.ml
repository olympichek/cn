(* Created by Victor Gomes 2016-01-19 *)
(* It generates an Ocaml file from CPS-Core AST *)

open Util
open Pp_prelude
open Core
open Cps_core
open AilTypes
open Defacto_memory_types
open Core_ctype

exception Type_expected of core_base_type
exception Unexpected of string

let ( ^//^ ) x y = x ^^ P.break 1 ^^ P.break 1 ^^ y
let ( !> ) x = P.nest 2 (P.break 1 ^^ x)

let rec get_labels e ls =
  match e with
  | Elet (_, _, e) -> get_labels e ls
  | Eloc (_, e) -> get_labels e ls
  | Eindet (_, e) -> get_labels e ls
  | Ebound (_, e) -> get_labels e ls
  | End (e::_) -> get_labels e ls
  | Eif (_, e2, e3) -> get_labels e2 ls |> get_labels e3
  | Ewseq (_, e1, e2) -> get_labels e1 ls |> get_labels e2
  | Esseq (_, e1, e2) -> get_labels e1 ls |> get_labels e2
  | Esave ((sym, bT), ps, e) ->
    let params = List.map (fun (s, (bt, _)) -> (s, bt)) ps in
    get_labels e ((sym, bT, params, e)::ls)
  | Ecase (_, cases) ->
    List.map snd cases
    |> List.fold_left (flip get_labels) ls
  | _ -> ls

(* String helper function *)
let string_tr target replace str =
  String.map (fun c -> if c = target then replace else c) str

(* Print TODO *)
let todo str = !^"raise (A.Error \"" ^^ !^str ^^ !^"\")"

(* Extend pretty printer *)
let print_comment doc = P.parens (P.star ^^^ doc ^^^ P.star)

let print_if b x y =
  !^"if" ^^^ b ^^^ !^"then (" ^^ !> x ^/^ !^") else (" ^^ !> y ^/^ !^")"

let print_seq p x y = x ^^ !> (!^">>= fun" ^^^ p ^^ !^" ->") ^/^ y

let print_bool b = if b then !^"true" else !^"false"

let print_option_type pp = function
  | Some e  -> !^"Some" ^^^ P.parens (pp e)
  | None    -> !^"None"

(* Print symbols (variables name, function names, etc...) *)
(* let print_symbol a = !^(Pp_symbol.to_string_pretty a) *)
let print_symbol a = !^(Pp_symbol.to_string a)

let print_raw_symbol = function
  | Symbol.Symbol (i, None)     ->
    !^"Symbol.Symbol" ^^^ P.parens (!^(string_of_int i) ^^ P.comma ^^^ !^"None")
  | Symbol.Symbol (i, Some str) ->
    !^"Symbol.Symbol" ^^^ P.parens (!^(string_of_int i) ^^ P.comma
                                    ^^^ !^"Some" ^^^ P.dquotes !^str)

(* Take out all '.' and add 'impl_' as prefix *)
let print_impl_name i = !^("_"
  ^ (string_tr '.' '_' (Implementation_.string_of_implementation_constant i)))

(* It was print an unknown location *)
let print_cabs_id (Cabs.CabsIdentifier (_, str)) =
  !^("Cabs.CabsIdentifier (Location_ocaml.unknown, " ^ str ^ ")")

let print_list pp xs =
  let rec print_elem xs =
    match xs with
    | [] -> P.empty
    | [x] -> pp x
    | x :: xs -> pp x ^^ P.semi ^^^ (print_elem xs)
  in !^"[" ^^ print_elem xs ^^ !^"]"

let print_name = function
  | Sym a  -> print_symbol a
  | Impl i -> print_impl_name i

(* Printing types *)
let rec print_core_object = function
 | OTy_integer    -> !^"M.integer_value"
 | OTy_floating   -> !^"M.floating_value"
 | OTy_pointer    -> !^"M.pointer_value"
 | OTy_cfunction (ret_oTy, naparams, isVariadic) ->
     (* TODO: K wip *)
     !^"M.pointer_value" (* cfunction is a pointer value? *)
                       (*TODO: I am not sure about these: *)
 | OTy_array obj  -> !^"[" ^^ print_core_object obj ^^ !^"]"
 | OTy_struct sym -> !^"struct" ^^^ print_symbol sym
 | OTy_union sym  -> !^"union" ^^^ print_symbol sym

let rec print_base_type = function
  | BTy_unit       -> !^"()"
  | BTy_boolean    -> !^"bool"
  | BTy_ctype      -> !^"C.ctype0"
  | BTy_list bTys  -> P.parens (print_base_type bTys) ^^^ !^"list"
  | BTy_tuple bTys -> P.parens (P.separate_map P.star print_base_type bTys)
  | BTy_object obj -> print_core_object obj
  | BTy_loaded obj -> P.parens (print_core_object obj)  ^^^ !^"A.loaded"

let print_core_type = function
  | TyBase   baseTy -> print_base_type baseTy
  | TyEffect baseTy -> print_base_type baseTy

(* Print functions and function implementation specific *)
let print_params params =
  if List.length params = 0
  then P.parens P.empty
  else
    let args (sym, ty) = P.parens (print_symbol sym ^^ P.colon ^^ print_base_type ty)
    in P.separate_map P.space args params


let print_let r p args x y =
  !^"let" ^^ (if r then !^" rec" else P.empty)
  ^^^ p ^^ args ^^^ P.equals ^^^ x
  ^^^ !^"in" ^/^ (if y = P.empty then P.empty else !> y)

let print_function name pmrs ty body =
  name ^^^ print_params pmrs (*^^ P.colon ^^^ ty *)^^^ P.equals ^^ !> body

let print_eff_function name pmrs ty body =
  name ^^^ print_params pmrs ^^^ P.equals ^^ !> body
  (*name ^^^ print_params pmrs ^^^ P.parens (!^"return" ^^ P.colon ^^ ty
    ^^ !^" -> ('a, b) Continuation") ^^^ P.equals ^^ !> body *)

(* Binary operations and precedences *)

(* FIXME: test if t1 and t2 are the same up to loaded *)
(* TODO: all the binops case *)
let print_binop binop pp (Pexpr (t1, pe1_) as pe1) (Pexpr (t2, pe2_) as pe2) =
  match binop with
  | OpAdd -> !^"(M.op_ival M.IntAdd (" ^^ pp pe1 ^^ !^") (" ^^ pp pe2 ^^ !^"))"
  | OpSub -> !^"(M.op_ival M.IntSub (" ^^ pp pe1 ^^ !^") (" ^^ pp pe2 ^^ !^"))"
  | OpMul -> !^"(M.op_ival M.IntMul (" ^^ pp pe1 ^^ !^") (" ^^ pp pe2 ^^ !^"))"
  | OpDiv -> !^"(M.op_ival M.IntDiv (" ^^ pp pe1 ^^ !^") (" ^^ pp pe2 ^^ !^"))"
  | OpRem_t -> !^"(M.op_ival M.IntRem_t (" ^^ pp pe1 ^^ !^") (" ^^ pp pe2 ^^ !^"))"
  | OpRem_f -> !^"(M.op_ival M.IntRem_f (" ^^ pp pe1 ^^ !^") (" ^^ pp pe2 ^^ !^"))"
  | OpExp -> !^"(M.op_ival M.IntExp (" ^^ pp pe1 ^^ !^") (" ^^ pp pe2 ^^ !^"))"
  | OpEq  -> (
      match t1 with
      | BTy_object (OTy_integer)
      | BTy_loaded (OTy_integer) ->
        !^"A.eq" ^^^ P.parens (pp pe1) ^^^ P.parens (pp pe2)
        (*!^"(O.get (M.eq_ival M.initial_mem_state0 Symbolic.Constraints_TODO  ("
          ^^ pp pe1 ^^ !^") (" ^^ pp pe2 ^^ !^")))"*)
      | BTy_object (OTy_pointer)
      | BTy_loaded (OTy_pointer) ->
        !^"(M.eq_ptrval Symbolic.Constraints_TODO  (" ^^ pp pe1 ^^ !^") ("
          ^^ pp pe2 ^^ !^"))"
      | BTy_ctype ->
        !^"(C.ctypeEqual0 (" ^^ pp pe1 ^^ !^") (" ^^ pp pe2 ^^ !^"))"
      | _ -> todo "binop eq"
    )
  | OpLt  -> (
      match t1 with
      | BTy_object (OTy_integer)
      | BTy_loaded (OTy_integer) ->
        !^"A.lt" ^^^ P.parens (pp pe1) ^^^  P.parens (pp pe2)
        (*
        !^"(O.get (M.lt_ival Symbolic.Constraints_TODO (" ^^ pp pe1 ^^ !^") ("
          ^^ pp pe2 ^^ !^")))"*)
      | BTy_object (OTy_pointer)
      | BTy_loaded (OTy_pointer) ->
        !^"(O.get (M.lt_ptrval Symbolic.Constraints_TODO (" ^^ pp pe1 ^^ !^") ("
          ^^ pp pe2 ^^ !^")))"
      | _ -> todo "binop lt"
    )
  | OpLe  -> (
      match t1 with
      | BTy_object (OTy_integer)
      | BTy_loaded (OTy_integer) ->
        !^"A.le" ^^^ P.parens (pp pe1) ^^^  P.parens (pp pe2)
       (* !^"(O.get (M.le_ival Symbolic.Constraints_TODO (" ^^ pp pe1 ^^ !^") ("
          ^^ pp pe2 ^^ !^")))"*)
      | BTy_object (OTy_pointer)
      | BTy_loaded (OTy_pointer) ->
        !^"(O.get (M.le_ptrval Symbolic.Constraints_TODO (" ^^ pp pe1 ^^ !^") ("
          ^^ pp pe2 ^^ !^")))"
      | _ -> todo "binop lt"
    )
  | OpGt  -> (
      match t1 with
      | BTy_object (OTy_integer)
      | BTy_loaded (OTy_integer) ->
        !^"A.gt" ^^^ P.parens (pp pe1) ^^^  P.parens (pp pe2)
        (*!^"(O.get (M.gt_ival Symbolic.Constraints_TODO (" ^^ pp pe1 ^^ !^") ("
          ^^ pp pe2 ^^ !^")))"*)
      | BTy_object (OTy_pointer)
      | BTy_loaded (OTy_pointer) ->
        !^"(O.get (M.gt_ptrval Symbolic.Constraints_TODO (" ^^ pp pe1 ^^ !^") ("
          ^^ pp pe2 ^^ !^")))"
      | _ -> todo "binop gt"
    )
  | OpGe  -> (
      match t1 with
      | BTy_object (OTy_integer)
      | BTy_loaded (OTy_integer) ->
        !^"A.ge" ^^^ P.parens (pp pe1) ^^^  P.parens (pp pe2)
        (*!^"(O.get (M.ge_ival Symbolic.Constraints_TODO (" ^^ pp pe1 ^^ !^") ("
          ^^ pp pe2 ^^ !^")))"*)
      | BTy_object (OTy_pointer)
      | BTy_loaded (OTy_pointer) ->
        !^"(O.get (M.ge_ptrval Symbolic.Constraints_TODO (" ^^ pp pe1 ^^ !^") ("
          ^^ pp pe2 ^^ !^")))"
      | _ -> todo "binop ge"
    )
  | OpAnd -> pp pe1 ^^^ !^" && " ^^^ pp pe2
  | OpOr  -> pp pe1 ^^^ !^ "||" ^^^ pp pe2

let binop_precedence (Pexpr (_, pe)) = match pe with
  | PEop (OpExp, _, _) -> Some 1
  | PEop (OpMul, _, _)
  | PEop (OpDiv, _, _)
  | PEop (OpRem_t, _, _)
  | PEop (OpRem_f, _, _) -> Some 2
  | PEop (OpAdd, _, _)
  | PEop (OpSub, _, _) -> Some 3
  | PEop (OpLt,  _, _)
  | PEop (OpLe,  _, _) -> Some 4
  | PEop (OpGt,  _, _)
  | PEop (OpGe,  _, _) -> Some 4
  | PEop (OpEq,  _, _) -> Some 5
  | PEop (OpAnd, _, _) -> Some 6
  | PEop (OpOr,  _, _) -> Some 7
  | _ -> None

let lt_precedence p1 p2 =
  match (p1, p2) with
    | (Some n1, Some n2) -> n1 <= n2
    | _                  -> true

(* Print let expression patterns *)

(* These will not really match *)
let rec print_pattern = function
  | CaseBase (None, _) -> P.underscore
  | CaseBase (Some sym, _) -> print_symbol sym
  | CaseCtor (ctor, pas) -> print_match_ctor (match pas with
    | []   -> P.underscore
    | [pa] -> print_pattern pa
    | _    -> P.parens (comma_list print_pattern pas)) ctor
and print_match_ctor arg = function
  | Cnil _       -> !^"[]"
  | Ccons        -> !^"Cons"
  | Ctuple       -> arg
  | Carray       -> !^"array"
  | Civmax       -> !^"A.ivmax"
  | Civmin       -> !^"A.ivmin"
  | Civsizeof    -> !^"M.sizeof_ival"
  | Civalignof   -> !^"M.alignof_ival"
  | Cspecified   -> !^"A.Specified" ^^ P.parens arg
  | Cunspecified -> !^"A.Unspecified" ^^ P.parens arg

let print_match pe pp pas =
  (* ensure that the pattern "_" is the first in the list, it will be the last
     by fold_left *)
  let cmp (pat1, pe1) (pat2, pe2) =
    match pat1, pat2 with
    | _, CaseBase (None, _) -> 1
    | _ -> 0
  in
  let pas = List.fast_sort cmp pas in
  !^"(match" ^^^ pe ^^^ !^"with" ^^ !> (List.fold_left (
      fun acc (pat, pe) -> !^"|" ^^^print_pattern pat ^^^ !^"->" ^^^ pp pe ^/^ acc
    ) P.empty pas) ^^ !^")"

let print_nat_big_num n =
  !^"Nat_big_num.of_string" ^^^ P.dquotes (!^(Nat_big_num.to_string n))

let print_symbol_prefix = function
  | Symbol.PrefSource syms ->
    !^"Symbol.PrefSource" ^^^ print_list print_raw_symbol syms
  | Symbol.PrefOther str   ->
    !^"Symbol.PrefOther" ^^^ P.dquotes !^str

(* TODO: Int_leastN_t *)
let print_ail_integer_base_type = function
  | Ichar          -> !^"T.Ichar"
  | Short          -> !^"T.Short"
  | Int_           -> !^"T.Int_"
  | Long           -> !^"T.Long"
  | LongLong       -> !^"T.LongLong"
   (* Things defined in the standard libraries *)
  | IntN_t n       -> !^"T.IntN_t" ^^^ !^(string_of_int n)
  | Int_leastN_t n -> !^"T.Int_leastN_t" ^^^ todo "int_leastnt"
  | Int_fastN_t n  -> !^"T.Int_fastN_t" ^^^ todo "int+fastnt"
  | Intmax_t       -> !^"T.Intmax_t"
  | Intptr_t       -> !^"T.Intptr_t"

let print_ail_integer_type = function
  | Char         -> !^"T.Char"
  | Bool         -> !^"T.Bool"
  | Signed ibt   -> !^"T.Signed" ^^^ P.parens (print_ail_integer_base_type ibt)
  | Unsigned ibt -> !^"T.Unsigned" ^^^ P.parens (print_ail_integer_base_type ibt)
  | IBuiltin str -> !^"T.IBuiltin" ^^^ !^str
  | Enum ident   -> !^"T.Enum" ^^^ P.parens (print_symbol ident)
  | Size_t       -> !^"T.Size_t"
  | Ptrdiff_t    -> !^"T.Ptrdiff_t"

let print_integer_value_base = function
  | IVconcrete bignum             ->
    !^"I.IVconcrete" ^^^ P.parens (print_nat_big_num bignum)
  | IVaddress (Address0 (sym, n))  ->
    !^"I.IVAddress" ^^^ P.parens (!^"I" ^^^ P.parens (print_symbol_prefix sym
                                   ^^ P.comma ^^^ !^(string_of_int n)))
  | IVmax ait                     -> !^"I.IVmax" ^^^ P.parens
                                       (print_ail_integer_type ait)
  | IVmin ait                     -> !^"I.IVmin" ^^^ P.parens
                                       (print_ail_integer_type ait)
  | IVunspecified                 -> !^"I.IVunspecified"
  | IVop (op, ivs)                -> raise (Unsupported "ivop")
  | IVsizeof cty                  -> raise (Unsupported "ivssizeof")
  | IValignof cty                 -> raise (Unsupported "ivalignod")
  | IVoffsetof (sym, cabs_id)     -> raise (Unsupported "ivoffsetof")
  | IVbyteof (ivb, mv)            -> raise (Unsupported "ifbyteof")
  | IVcomposite ivs               -> raise (Unsupported "ivcomposite")
  | IVfromptr (ivb, mv)           -> raise (Unsupported "ivfromptr")
  | IVptrdiff (ivb, mv)           -> raise (Unsupported "ivptrdiff")
  | IVconcurRead (_, _)           -> raise (Unsupported "ivconcured")

let print_ail_qualifier {
  AilTypes.const = c;
  AilTypes.restrict = r;
  AilTypes.volatile = v;
  AilTypes.atomic = a;
} = !^"{" ^^ P.nest 2 (P.break 1 ^^
    !^"T.const = " ^^ print_bool c ^^ !^";" ^/^
    !^"T.restrict = " ^^ print_bool r ^^ !^";" ^/^
    !^"T.volatile = " ^^ print_bool v ^^ !^";" ^/^
    !^"T.atomic = " ^^ print_bool a ^^ !^";"
    ) ^^ P.break 1 ^^ !^"}"

let print_ail_basic_type = function
  | Integer it  -> !^"T.Integer" ^^^ P.parens (print_ail_integer_type it)
  | Floating ft -> todo "floating type"

let rec print_ctype = function
  | Void0 -> !^"C.Void0"
  | Basic0 abt ->
    !^"C.Basic0" ^^^ P.parens (print_ail_basic_type abt)
  | Array0 (cty, num) ->
    !^"C.Array0" ^^^ P.parens (print_ctype cty ^^ P.comma
                               ^^^ print_option_type print_nat_big_num num)
  | Function0 (cty, params, variad) ->
    !^"C.Function0" ^^^ P.parens
      (print_ctype cty ^^ P.comma ^^^ print_list
         (fun (q, cty) -> print_ail_qualifier q ^^ P.comma ^^^ print_ctype cty)
         params
       ^^ P.comma ^^^ print_bool variad)
  | Pointer0 (q, cty) ->
    !^"C.Pointer0" ^^^ P.parens (print_ail_qualifier q ^^ P.comma ^^^ print_ctype cty)
  | Atomic0 cty -> !^"C.Atomic0" ^^^ P.parens (print_ctype cty)
  | Struct0 strct -> !^"C.Struct0" ^^^ P.parens (print_raw_symbol strct)
  | Union0 union -> !^"C.Union0" ^^^ P.parens (print_raw_symbol union)
  | Builtin0 str -> !^"C.Builtin0" ^^^ !^str

let print_provenance = function
  | Prov_wildcard -> !^"I.Prov_wildcard"
  | Prov_none     -> !^"I.Prov_none"
  | Prov_device   -> !^"I.Prov_device"
  | Prov_some ids -> todo "prov_some"

let print_iv_value = function
  | IV (Prov_none, IVconcrete n) -> !^"A.mk_int" ^^^ P.dquotes (!^(Nat_big_num.to_string n))
  | IV (prov, ivb) -> !^"I.IV" ^^^ P.parens (print_provenance prov ^^ P.comma
                                             ^^^ print_integer_value_base ivb)

let rec print_pointer_value_base = function
  | PVnull cty        -> !^"I.PVnull" ^^^ P.parens (print_ctype cty)
  | PVfunction sym    -> !^"I.PVfunction" ^^^ P.parens (print_symbol sym)
  | PVbase (id, pre)  -> !^"I.PVbase" ^^^ P.parens (!^(string_of_int id) ^^ P.comma
                                                    ^^^ print_symbol_prefix pre)
  | PVfromint ivb     -> !^"I.PVfromint" ^^^ P.parens (print_integer_value_base ivb)
  | PVunspecified cty -> !^"I.PVunspecified" ^^^ P.parens (print_ctype cty)

and print_shift_path_element = function
  | SPE_array (cty, ivb)  ->
    !^"I.SPE_array" ^^^ P.parens (print_ctype cty ^^ P.comma
                                  ^^^ print_integer_value_base ivb)
  | SPE_member (_, _)     -> todo "spe member"

and print_shift_path sp = print_list print_shift_path_element sp

and print_pointer_value = function
  | PV (p, pvb, sp) ->
    !^"I.PV" ^^^ P.parens (print_provenance p ^^ P.comma
                           ^^^ print_pointer_value_base pvb ^^ P.comma
                           ^^^ print_shift_path sp)

let print_floating_value = function
  | FVunspecified   -> !^"I.FVunspecified"
  | FVconcrete str  -> !^"I.FVconcrete" ^^^ !^str

let rec print_object_value = function
  | OVstruct _
  | OVunion  _     -> todo "print_obj_value"
  | OVcfunction nm -> print_name nm
  | OVinteger iv   -> print_iv_value iv
  | OVfloating fv  -> print_floating_value fv
  | OVpointer pv   -> print_pointer_value pv
  | OVarray obvs   -> print_list print_object_value obvs

let rec print_mem_value = function
  | MVinteger (ait, iv) -> !^"I.MVinteger" ^^ P.parens
                             (print_ail_integer_type ait ^^ P.comma ^^^ print_iv_value iv)
  | MVfloating _        -> todo "mvfloating"
  | MVpointer (cty, pv) -> !^"I.MVpointer" ^^ P.parens
                             (print_ctype cty ^^P.comma ^^^ print_pointer_value pv)
  | MVarray mvs         -> !^"I.MVarray" ^^^ print_list print_mem_value mvs
  | MVstruct (sym, sls) -> !^"I.MVstruct" ^^^ print_list
                             (fun (cid, mv) -> P.parens (print_cabs_id cid ^^ P.comma
                                                         ^^^ print_mem_value mv)) sls
  | MVunion (sym,cid,mv) -> !^"I.MVunion" ^^^ P.parens
                             (print_symbol sym ^^ P.comma ^^^ print_cabs_id cid
                              ^^ P.comma ^^^ print_mem_value mv)

(* Print type values *)
let rec print_value = function
  | Vunit            -> P.parens P.empty
  | Vtrue            -> !^"true"
  | Vfalse           -> !^"false"
  | Vlist (_, cvals) -> print_list print_value cvals
  | Vtuple cvals     -> P.parens (comma_list print_value cvals)
  | Vctype ty        -> print_ctype ty
  | Vunspecified ty  -> !^"A.Unspecified" ^^^ P.parens (print_ctype ty)
  | Vobject obv      -> print_object_value obv
  | Vconstrained _   -> todo "vconstrained"
  | Vspecified v     -> !^"A.Specified" ^^^ P.parens (print_object_value v)
                          (* TODO: it shouldn't be possible v evaluates to IVunspecified *)


(* Print expressions (pure and eff) *)
let print_pure_expr globs pe =
  let rec pp prec pe =
    let prec' = binop_precedence pe in
    let pp z  = P.group (pp prec' z) in
    (if lt_precedence prec' prec then fun z -> z else P.parens)
    begin
      match pe with Pexpr (t, pe') ->
      match pe' with
      | PEsym sym ->
        (if List.mem sym globs then !^"!" else P.empty) ^^ print_symbol sym
      | PEimpl iCst -> print_impl_name iCst ^^^ P.parens P.space
      | PEval cval -> print_value cval
      | PEconstrained _ -> todo "peconstrained"
      | PEundef ub ->
        !^"raise" ^^^ P.parens (
          !^"A.Undefined" ^^^ P.dquotes
            (!^(Undefined.stringFromUndefined_behaviour ub))
        )
      | PEerror (str, pe) ->
        !^"raise" ^^^ !^"(A.Error" ^^^ P.dquotes (!^str ^^^ pp pe) ^^ !^")"
      | PEctor (ctor, pes) ->
          let pp_args sep = P.parens (P.separate_map sep (fun x -> P.parens (pp x)) pes) in
          begin
          match ctor with
          | Cnil _ -> !^"[]"
          | Ccons ->
            (match pes with
             | []       -> raise (Rt_ocaml.Error "Ccons: empty list")
             | [pe]     -> !^"[" ^^ pp pe ^^ !^"]"
             | [pe;pes] -> pp pe ^^^ !^"::" ^^^ pp pes
             | _        -> raise (Rt_ocaml.Error "Ccons: more than 2 args")
            )
          | Ctuple       -> pp_args P.comma
          | Carray       -> !^"array"
          | Civmax       -> !^"A.ivmax" ^^^ pp_args P.space
          | Civmin       -> !^"A.ivmin" ^^^ pp_args P.space
          | Civsizeof    -> !^"M.sizeof_ival" ^^^ pp_args P.space
          | Civalignof   -> !^"M.alignof_ival" ^^^ pp_args P.space
          | Cspecified   -> !^"A.Specified" ^^^ pp_args P.space
          | Cunspecified -> !^"A.Unspecified"  ^^^ pp_args P.space
          end
      | PEcase (pe, pas) -> print_match (pp pe) pp pas
      | PEarray_shift (pe1, ty, pe2) -> 
        !^"(M.array_shift_ptrval (" ^^ pp pe1 ^^ !^") ("
          ^^ print_ctype ty ^^ !^") (" ^^ pp pe2 ^^ !^"))"
      | PEmember_shift (pe, tag_sym, memb_ident) -> todo "pure: member_shift"
      | PEnot pe -> !^"not" ^^^ P.parens (pp pe)
      | PEop (bop, pe1, pe2) -> print_binop bop pp pe1 pe2
      | PEstruct _ -> todo "struct"
      | PEunion _ -> todo "union"
      | PEcall (nm, pes) -> 
        print_name nm ^^^ (
          if List.length pes = 0
          then P.parens P.empty
          else P.separate_map P.space (fun (Pexpr (t, x)) ->
              match x with
              | (PEsym sym) -> pp (Pexpr (t, PEsym sym))
              | _           -> P.parens (pp (Pexpr (t, x)))
            ) pes
        )
      | PElet (pat, pe1, pe2) ->
        !^"let" ^^^ print_pattern pat ^^^ P.equals ^^^ pp pe1
          ^^^ !^"in" ^/^ pp pe2
      | PEif (pe1, pe2, pe3) -> print_if (pp pe1) (pp pe2) (pp pe3)
      | PEis_scalar pe -> (
          match pe with
          | Pexpr (_, PEval (Vctype ty)) ->
            !^"(AilTypesAux.is_scalar(Core_aux.unproj_ctype " ^^ pp pe ^^ !^"))"
          | Pexpr (_, PEsym sym) ->
            !^"(AilTypesAux.is_scalar(Core_aux.unproj_ctype " ^^ pp pe ^^ !^"))"
          | _ -> !^"is_scalar" ^^^ pp pe
        )
      | PEis_integer pe -> (
          match pe with
          | Pexpr (_, PEval (Vctype ty)) ->
            !^"(AilTypesAux.is_integer (Core_aux.unproj_ctype "^^ pp pe ^^ !^"))"
          | Pexpr (_, PEsym sym) ->
            !^"(AilTypesAux.is_integer (Core_aux.unproj_ctype "^^ pp pe ^^ !^"))"
          | _ -> !^"is_integer" ^^^ pp pe
        )
      | PEis_signed pe -> (
          match pe with
          | Pexpr (_, PEval (Vctype ty)) ->
            !^"(AilTypesAux.is_signed_integer_type (Core_aux.unproj_ctype "
              ^^ pp pe ^^ !^"))"
          | Pexpr (_, PEsym sym) ->
            !^"(AilTypesAux.is_signed_integer_type (Core_aux.unproj_ctype "
              ^^ pp pe ^^ !^"))"
          | _ -> !^"is_signed" ^^^ pp pe
        )
      | PEis_unsigned pe -> (
          match pe with
          | Pexpr (_, PEval (Vctype ty)) ->
            !^"(AilTypesAux.is_unsigned_integer_type (Core_aux.unproj_ctype "
              ^^ pp pe ^^ !^"))"
          | Pexpr (_, PEsym sym) ->
            !^"(AilTypesAux.is_unsigned_integer_type (Core_aux.unproj_ctype "
              ^^ pp pe ^^ !^"))"
          | _ -> !^"is_unsigned" ^^^ pp pe
        )
    end
  in pp None pe

let print_args globs pes =
  if List.length pes = 0
  then P.parens P.empty
  else (P.separate_map P.space (P.parens % print_pure_expr globs )) pes

let print_memop globs memop pes =
  (match memop with
  | Mem.PtrEq -> !^"A.eq_ptrval"
  | Mem.PtrNe -> !^"A.ne_ptrval"
  | Mem.PtrGe -> !^"A.ge_ptrval"
  | Mem.PtrLt -> !^"A.lt_ptrval"
  | Mem.PtrGt -> !^"A.gt_ptrval"
  | Mem.PtrLe -> !^"A.le_ptrval"
  | Mem.Ptrdiff -> !^"A.diff_ptrval"
  | Mem.IntFromPtr -> !^"A.intcast_ptrval"
  | Mem.PtrFromInt -> !^"A.ptrvast_ival"
  | Mem.PtrValidForDeref -> !^"A.validForDeref_ptrval"
  ) ^^^ (P.separate_map P.space (P.parens % print_pure_expr globs)) pes


let get_ctype (Pexpr (_, pe)) =
  match pe with
  | PEval (Vctype ty) -> ty
  | _ -> print_string "ctype"; raise (Type_expected BTy_ctype)

let choose_load_type (Pexpr (_, PEval cty)) =
  match cty with
  | Vctype (Basic0 (Integer ity)) ->
    !^"A.load_integer" ^^^ P.parens (print_ail_integer_type ity)
  | Vctype (Pointer0 (q, cty)) ->
    !^"A.load_pointer" ^^^ P.parens (print_ail_qualifier q)
      ^^^ P.parens (print_ctype cty)
  | _ -> todo "load not implemented"

let choose_store_type (Pexpr (_, PEval cty)) =
  match cty with
  | Vctype (Basic0 (Integer ity)) ->
    !^"A.store_integer" ^^^ P.parens (print_ail_integer_type ity)
  | Vctype (Pointer0 (q, cty)) ->
    !^"A.store_pointer" ^^^ P.parens (print_ail_qualifier q)
      ^^^ P.parens (print_ctype cty)
  | _ -> todo "store not implemented"

let rec print_mem_value globs ty e =
  match ty with
  | Basic0 (Integer ait) ->
    !^"I.MVinteger" ^^^ P.parens (print_ail_integer_type ait ^^ P.comma
                                  ^^^ print_pure_expr globs e)
  | Basic0 (Floating aif) -> todo "mvfloating"
  | Array0 (cty, _) -> (
    match e with
    | Pexpr(t, PEval (Vobject (OVarray cvals))) ->
      !^"I.MVarray" ^^^ print_list (print_mem_value globs cty)
        (List.map (fun x -> Pexpr (t, PEval (Vobject x))) cvals)
    | _ -> raise (Rt_ocaml.Error "Array expected")
  )
  | Pointer0 (_, cty) ->
    !^"I.MVpointer" ^^^ P.parens (print_ctype cty ^^ P.comma 
      ^^^ !^"A.pointer_from_integer_value" ^^^ P.parens (print_pure_expr globs e))
  | _ -> todo "print_mem_value"

let print_action globs act =
  match act with
  | Create (al, ty, pre) ->
    !^"A.create" ^^^ P.parens (print_symbol_prefix pre) ^^^
      P.parens (print_pure_expr globs al) ^^^ P.parens (print_pure_expr globs ty)
  | Alloc0 (al, n, pre) ->
    !^"A.alloc" ^^^ P.parens (print_symbol_prefix pre) ^^^
      P.parens (print_pure_expr globs al) ^^^ P.parens (print_pure_expr globs n)
  | Kill e ->
    !^"kill" ^^ P.parens (print_pure_expr globs e)
  | Store0 (ty, pe1, pe2, _) ->
    choose_store_type ty ^^^ P.parens (print_pure_expr globs pe1) ^^^
      P.parens (print_pure_expr globs pe2)
  | Load0 (ty, e, _) ->
    choose_load_type ty ^^^ P.parens (print_pure_expr globs e)
  | RMW0 _ -> raise (Unsupported "rmw0")
  | Fence0 _ -> raise (Unsupported "fence")


let print_impls globs impl =
  Pmap.fold (fun iCst iDecl acc ->
    acc ^//^
    (if acc = P.empty then !^"let rec" else !^"and") ^^^
    match iDecl with
    | Def (bTy, pe) ->
      print_function (print_impl_name iCst) [] (print_base_type bTy)
        (print_pure_expr globs pe)
    | IFun (bTy, params, pe) ->
      print_function (print_impl_name iCst) params (print_base_type bTy)
        (print_pure_expr globs pe)
  ) impl P.empty


let rec print_basic_expr globs = function
  | CpsPure pe            -> !^"A.value" ^^^ P.parens (print_pure_expr globs pe)
  | CpsMemop (memop, pes) -> print_memop globs memop pes
  | CpsAction (Core.Paction (p, (Action (_, bs, act)))) -> print_action globs act

let rec print_pattern2 = function
  | CaseBase (None, _) -> P.parens P.empty
  | CaseBase (Some sym, _) -> print_symbol sym
  | CaseCtor (ctor, pas) -> print_match_ctor2 (match pas with
    | []   -> P.parens P.empty
    | [pa] -> print_pattern2 pa
    | _    -> P.parens (comma_list print_pattern2 pas)) ctor
and print_match_ctor2 arg _ = arg

let rec print_pattern3 = function
  | CaseBase (None, _) -> P.underscore
  | CaseBase (Some sym, _) -> print_symbol sym
  | CaseCtor (ctor, pas) -> print_match_ctor2 (match pas with
    | []   -> P.underscore
    | [pa] -> print_pattern3 pa
    | _    -> P.parens (comma_list print_pattern3 pas)) ctor
and print_match_ctor2 arg _ = arg

let print_call globs (sym, pes, pato) =
  P.parens (print_symbol sym (*^^  !^"[@tailcall]"*)) ^^^
  P.parens (P.separate_map (P.comma ^^ P.space) (print_pure_expr globs) pes) ^^^
  P.parens (match pato with
      | None -> P.empty
      | Some pat -> print_pattern2 pat
    )

let rec print_control globs = function
  | CpsGoto goto -> print_call globs goto
  | CpsIf (pe1, goto2, goto3) -> print_if (print_pure_expr globs pe1) (print_control globs goto2) (print_control globs goto3)
  | CpsCase (pe, cases) -> print_match (print_pure_expr globs pe) (print_control globs) cases
  | CpsProc (nm, (l, fvs), pes) ->
      print_name nm ^^^ P.parens (print_symbol l ^^^ P.parens (P.separate_map (P.comma ^^ P.space) print_symbol fvs)) ^^^ (P.separate_map P.space (fun z -> P.parens (print_pure_expr globs z))) pes

  | CpsCcall (nm, (l, fvs), es) ->
    print_pure_expr globs nm ^^^
    P.parens (print_symbol l ^^^ P.parens (P.separate_map (P.comma ^^ P.space) print_symbol fvs)) ^^^
    (
      if List.length es = 0
      then P.parens P.space
      else (P.separate_map P.space (fun x -> P.parens (print_pure_expr globs x)) es)
    )
  | CpsCont sym -> !^"cont_0" ^^^ print_symbol sym

let print_pato p =
  !^">>= fun" ^^^
  (match p with
   | None -> !^"_"
   | Some pat -> print_pattern pat
  ) ^^ !^" ->"

let print_bb globs (es, (pato, ct)) =
  match es with
  | [] -> print_control globs ct
  | ((_, e)::es) -> print_basic_expr globs e ^^
                         (List.fold_left (fun acc (p, e) ->
                           acc ^/^ print_pato p ^/^ print_basic_expr globs e
                            ) P.space es) ^^^ !> (print_pato pato) ^/^ print_control globs ct

let print_decl globs (BB ((sym, pes, pato), bb)) =
  print_symbol sym ^^^
  P.parens (P.separate_map (P.comma ^^ P.space) print_symbol pes) ^^^
  P.parens (match pato with
      | None -> P.underscore
      | Some pat -> print_pattern3 pat
    ) ^^^
  !^"=" ^^ !> (print_bb globs bb)

let print_transformed globs bbs bb =
  let bbs = List.sort_uniq block_compare bbs in
  if List.length bbs = 0 then
    print_bb globs bb
  else
    !^"let rec" ^^^ print_decl globs (List.hd bbs) ^^^
    List.fold_left (fun acc decl -> acc ^/^ !^"and" ^^^ print_decl globs decl) P.space (List.tl bbs)
    ^/^ !^"in" ^/^ print_bb globs bb

let print_funs globs funs =
  Pmap.fold (fun sym decl acc ->
    acc ^//^ !^"and" ^^^
    match decl with
    | CpsFun  (bTy, params, pe) ->
      print_function (print_symbol sym) params (print_base_type bTy)
        (print_pure_expr globs pe)
    | CpsProc (bTy, params, bbs, bbody) ->
      print_eff_function (print_symbol sym ^^^ print_symbol default) params
        (P.parens (print_base_type bTy) ^^^ !^"M.memM")
        (print_transformed globs bbs bbody)
  ) funs P.empty
