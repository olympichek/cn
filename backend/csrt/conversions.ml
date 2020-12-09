module CF=Cerb_frontend
open List
(* open Sym *)
open Resultat
open Pp
(* open Tools *)
module BT = BaseTypes
module LRT = LogicalReturnTypes
module RT = ReturnTypes
module LFT = ArgumentTypes.Make(LogicalReturnTypes)
module FT = ArgumentTypes.Make(ReturnTypes)
module LT = ArgumentTypes.Make(False)
open TypeErrors
open IndexTerms
open BaseTypes
open LogicalConstraints
open Resources
open Parse_ast


module StringMap = Map.Make(String)
module SymSet = Set.Make(Sym)




let get_loc_ annots = Cerb_frontend.Annot.get_loc_ annots


let struct_predicates = true




let annot_of_ct (CF.Ctype.Ctype (annot,_)) = annot


(* base types *)

let sct_of_ct loc ct = 
  match Sctypes.of_ctype ct with
  | Some ct -> return ct
  | None -> fail loc (Unsupported (!^"ctype" ^^^ CF.Pp_core_ctype.pp_ctype ct))

let bt_of_core_object_type loc ot =
  let open CF.Core in
  match ot with
  | OTy_integer -> return BT.Integer
  | OTy_pointer -> return BT.Loc
  | OTy_array cbt -> Debug_ocaml.error "arrays"
  | OTy_struct tag -> return (BT.Struct tag)
  | OTy_union _tag -> Debug_ocaml.error "union types"
  | OTy_floating -> fail loc (Unsupported !^"floats")

let rec bt_of_core_base_type loc cbt =
  let open CF.Core in
  match cbt with
  | BTy_unit -> return BT.Unit
  | BTy_boolean -> return BT.Bool
  | BTy_object ot -> bt_of_core_object_type loc ot
  | BTy_loaded ot -> bt_of_core_object_type loc ot
  | BTy_list bt -> 
     let* bt = bt_of_core_base_type loc bt in
     return (BT.List bt)
  | BTy_tuple bts -> 
     let* bts = ListM.mapM (bt_of_core_base_type loc) bts in
     return (BT.Tuple bts)
  | BTy_storable -> Debug_ocaml.error "BTy_storageble"
  | BTy_ctype -> Debug_ocaml.error "BTy_ctype"










let struct_layout loc members tag = 
  let rec aux members position =
    match members with
    | [] -> 
       return []
    | (member, (attrs, qualifiers, ct)) :: members ->
       let* sct = sct_of_ct loc ct in
       let offset = Memory.member_offset tag member in
       let size = Memory.size_of_ctype sct in
       let to_pad = Z.sub offset position in
       let padding = 
         if Z.gt_big_int to_pad Z.zero 
         then [Global.{offset = position; size = to_pad; member_or_padding = None}] 
         else [] 
       in
       let member = [Global.{offset; size; member_or_padding = Some (member, sct)}] in
       let* rest = aux members (Z.add_big_int to_pad size) in
       return (padding @ member @ rest)
  in
  (aux members Z.zero)



module CA = CF.Core_anormalise

let struct_decl loc (tagDefs : (CA.st, CA.ut) CF.Mucore.mu_tag_definitions) fields (tag : BT.tag) = 

  let get_struct_members tag = 
    match Pmap.lookup tag tagDefs with
    | None -> fail loc (Missing_struct tag)
    | Some (M_UnionDef _) -> fail loc (Generic !^"expected struct")
    | Some (M_StructDef (fields, _)) -> return fields
  in

  let* members = 
    ListM.mapM (fun (member, (_,_, ct)) ->
        let loc = Loc.update loc (get_loc_ (annot_of_ct ct)) in
        let* sct = sct_of_ct loc ct in
        let bt = BT.of_sct sct in
        return (member, (sct, bt))
    ) fields
  in

  let* layout = 
    struct_layout loc fields tag
  in

  let* closed_stored =
    let open RT in
    let open LRT in
    let rec aux loc tag struct_p = 
      let* def_members = get_struct_members tag in
      let* layout = struct_layout loc def_members tag in
      let* members = 
        ListM.mapM (fun Global.{offset; size; member_or_padding} ->
            let pointer = IT.Offset (struct_p, Num offset) in
            match member_or_padding with
            | None -> return ([(pointer, size, None)], [])
            | Some (member, sct) -> 
               let (Sctypes.Sctype (annots, sct_)) = sct in
               match sct_ with
               | Sctypes.Struct tag -> 
                  let* (components, s_value) = aux loc tag pointer in
                  return (components, [(member, s_value)])
               | _ ->
                  let v = Sym.fresh () in
                  let bt = BT.of_sct sct in
                  return ([(pointer, size, Some (v, bt))], [(member, S (bt, v))])
            ) layout
      in
      let (components, values) = List.split members in
      return (List.flatten components, IT.Struct (tag, List.flatten values))
    in
    let struct_pointer = Sym.fresh () in
    let* components, struct_value = aux loc tag (S (BT.Loc, struct_pointer)) in
    let lrt = 
      List.fold_right (fun (member_p, size, member_or_padding) lrt ->
          match member_or_padding with
          | Some (member_v, bt) ->
             LRT.Logical ((member_v, Base bt), 
             LRT.Resource (RE.Points {pointer = member_p; pointee = member_v; size}, lrt))
          | None ->
             LRT.Resource (RE.Block {pointer = member_p; size = Num size; block_type = Padding}, lrt)           
        ) components LRT.I
    in
    let st = ST.ST_Ctype (Sctypes.Sctype ([], Struct tag)) in
    let rt = 
      Computational ((struct_pointer, BT.Loc), 
      Constraint (LC (IT.Representable (ST_Pointer, S (BT.Loc, struct_pointer))),
      Constraint (LC (Aligned (st, S (BT.Loc, struct_pointer))),
      (* Constraint (LC (EQ (AllocationSize (S struct_pointer), Num size)), *)
      lrt @@ 
      Constraint (LC (IT.Representable (st, struct_value)), LRT.I))))
    in
    return rt
  in


  let* closed_stored_predicate_definition = 
    let open RT in
    let open LRT in
    let struct_value_s = Sym.fresh () in
    (* let size = Memory.size_of_struct loc tag in *)
    let* def_members = get_struct_members tag in
    let* layout = struct_layout loc def_members tag in
    let clause struct_pointer = 
      let (lrt, values) = 
        List.fold_right (fun Global.{offset; size; member_or_padding} (lrt, values) ->
            let member_p = Offset (struct_pointer, Num offset) in
            match member_or_padding with
            | Some (member, sct) ->
               let member_v = Sym.fresh () in
               let (Sctypes.Sctype (annots, sct_)) = sct in
               let resource = match sct_ with
                 | Sctypes.Struct tag ->
                    RE.Predicate {pointer = member_p; name = Tag tag; args = [member_v]}
                 | _ -> 
                    RE.Points {pointer = member_p; pointee = member_v; size}
               in
               let bt = BT.of_sct sct in
               let lrt = 
                 LRT.Logical ((member_v, LS.Base bt), 
                 LRT.Resource (resource, lrt))
               in
               let value = (member, S (bt, member_v)) :: values in
               (lrt, value)
            | None ->
               let lrt = LRT.Resource (RE.Block {pointer = member_p; size = Num size; block_type = Padding}, lrt) in
               (lrt, values)
          ) layout (LRT.I, [])
      in
      let value = IT.Struct (tag, values) in
      let st = ST.ST_Ctype (Sctypes.Sctype ([], Sctypes.Struct tag)) in
      let lrt = 
        Constraint (LC (IT.Representable (ST_Pointer, struct_pointer)),
        Constraint (LC (Aligned (st, struct_pointer)),
        lrt @@ Constraint (LC (IT.Representable (st, value)), LRT.I)))
      in
      let constr = LC (IT.EQ (S (BT.Struct tag, struct_value_s), value)) in
      (lrt, constr)
    in
    let predicate struct_pointer = 
      Predicate {pointer = struct_pointer; 
                 name = Tag tag; 
                 args = [struct_value_s]} 
    in
    let unpack_function struct_pointer = 
      let (lrt, constr) = clause struct_pointer in
      LFT.Logical ((struct_value_s, LS.Base (Struct tag)), 
      LFT.Resource (predicate struct_pointer,
      LFT.I (LRT.concat lrt (LRT.Constraint (constr, LRT.I)))))
    in
    let pack_function struct_pointer = 
      let (arg_lrt, constr) = clause struct_pointer in
      LFT.of_lrt arg_lrt
      (LFT.I
        (LRT.Logical ((struct_value_s, LS.Base (Struct tag)), 
         LRT.Resource (predicate struct_pointer,
         LRT.Constraint (constr, LRT.I)))))
    in
    return (Global.{pack_function; unpack_function})
  in


  let open Global in
  let decl = { layout; closed_stored; closed_stored_predicate_definition } in
  return decl










let make_unowned_pointer pointer stored_type = 
  let open RT in
  let pointer_it = S (BT.Loc, pointer) in
  Computational ((pointer,Loc),
  Constraint (LC (IT.Representable (ST_Pointer, pointer_it)),
  Constraint (LC (IT.Aligned (stored_type, pointer_it)),
  (* Constraint (LC (EQ (AllocationSize (S pointer), Num size)), *)
  LRT.I)))

let make_block_pointer pointer block_type stored_type = 
  let open RT in
  let pointer_it = S (BT.Loc, pointer) in
  let size = Memory.size_of_stored_type stored_type in
  let uninit = RE.Block {pointer = pointer_it; size = Num size; block_type} in
  Computational ((pointer,Loc),
  Resource ((uninit, 
  Constraint (LC (IT.Representable (ST_Pointer, pointer_it)),
  Constraint (LC (IT.Aligned (stored_type, pointer_it)),
  (* Constraint (LC (EQ (AllocationSize (S pointer), Num size)), *)
  LRT.I)))))

let make_owned_pointer pointer stored_type rt = 
  let open RT in
  let pointer_it = S (BT.Loc, pointer) in
  let (Computational ((pointee,bt),lrt)) = rt in
  let size = Memory.size_of_stored_type stored_type in
  let points = RE.Points {pointer = pointer_it; pointee; size} in
  Computational ((pointer,Loc),
  Logical ((pointee, Base bt), 
  Resource ((points, 
  Constraint (LC (IT.Representable (ST_Pointer, pointer_it)),
  Constraint (LC (IT.Aligned (stored_type, pointer_it)),
  (* Constraint (LC (EQ (AllocationSize (S pointer), Num size)), *)
  lrt))))))

let make_pred_pointer pointer stored_type rt = 
  let open RT in
  let pointer_it = S (BT.Loc, pointer) in
  let (Computational ((pointee,bt),lrt)) = rt in
  let size = Memory.size_of_stored_type stored_type in
  let points = RE.Points {pointer = pointer_it; pointee; size} in
  Computational ((pointer,Loc),
  Logical ((pointee, Base bt), 
  Resource ((points, 
  Constraint (LC (IT.Representable (ST_Pointer, pointer_it)),
  Constraint (LC (IT.Aligned (stored_type, pointer_it)),
  (* Constraint (LC (EQ (AllocationSize (S pointer), Num size)), *)
  lrt))))))




(* function types *)

let update_values_lrt lrt =
  let subst_non_pointer = LRT.subst_var_fancy ~re_subst_var:RE.subst_non_pointer in
  let rec aux = function
    | LRT.Logical ((s,ls),lrt) ->
       let s' = Sym.fresh () in
       let lrt' = subst_non_pointer {before=s;after=s'} lrt in
       LRT.Logical ((s',ls), aux lrt')
    | LRT.Resource (re,lrt) -> LRT.Resource (re,aux lrt)
    | LRT.Constraint (lc,lrt) -> LRT.Constraint (lc,aux lrt)
    | LRT.I -> LRT.I
  in
  aux lrt




type addr_or_path = Object.AddrOrPath.t
type mapping = Object.mapping


let rec rt_of_ect v (aop : addr_or_path) typ : (RT.t * mapping, type_error) m =
  let open ECT in
  let open Object in
  let open Object.Mapping in
  let (Typ (loc, typ_)) = typ in
  match typ_ with
  (* unowned pointer *)
  | Pointer (_qualifiers, _, Unowned, typ2) ->
     let rt = make_unowned_pointer v (ST_Ctype (to_sct typ2)) in
     return (rt, [{obj = Obj (aop, None); res = (BT.Loc, v)}])
  (* pointer with predcate *)
  | Pointer (_qualifiers, loc, Pred pid, typ2) ->
     let* def = match Global.IdMap.find_opt pid Global.builtin_predicates with
       | Some def -> return def
       | None -> fail loc (Missing_predicate pid)
     in
     let* (args, mapping, lrt) = 
       ListM.fold_rightM (fun (name, LS.Base bt) (args, mapping, lrt) ->
           let s = Sym.fresh_named name in
           let lrt = LRT.Logical ((s, Base bt), lrt) in
           let args = s :: args in
           let mapping = 
             {obj = Obj (aop, Some {pred = Pred pid; arg = name}); 
              res = (bt, s)} :: mapping 
           in
           return (args, mapping, lrt)
         ) def.Global.arguments ([], [], LRT.I)
     in
     failwith "asd"
  (* block pointer *)
  | Pointer (_qualifiers, _, Block, typ2) -> (*  *)
     let rt = make_block_pointer v Nothing (ST_Ctype (to_sct typ2)) in
     return (rt, [{obj = Obj (aop, None); res = (BT.Loc, v)}])
  (* void* *)
  | Pointer (_qualifiers, _, Owned, (Typ (_, Void))) ->
     let size = Sym.fresh () in
     print stderr (item "size symbol" (Sym.pp size));
     let predicate = RE.Block {pointer = S (BT.Loc, v); size = S (Integer, size); block_type = Nothing} in
     let rt = 
       RT.Computational ((v, BT.Loc), 
       Logical ((size, Base BT.Integer), 
       Resource (predicate, I)))
     in
     let mapping = 
       [{obj = Obj (aop, Some {pred = Block; arg = "size"}); res = (Integer, size)};
        {obj = Obj (aop, None); res = (BT.Loc, v)}]
     in
     return (rt, mapping)
  (* owned struct pointer *)
  | Pointer (_qualifiers, _, Owned, (Typ (_, Struct tag))) ->
     let v2 = Sym.fresh () in
     let predicate = Predicate {pointer = S (BT.Loc, v); name = Tag tag; args = [v2]} in
     let rt = 
       RT.Computational ((v, BT.Loc), 
       Logical ((v2, Base (BT.Struct tag)), 
       Resource (predicate, I)))
     in
     let mapping = 
       [{obj = Obj (Object.AddrOrPath.pointee aop, None); res = (BT.Struct tag, v2)};
        {obj = Obj (aop, None); res = (BT.Loc, v)}]
     in
     return (rt, mapping)
  (* other owned pointer *)
  | Pointer (_qualifiers, _, Owned, typ2) ->
     let v2 = Sym.fresh () in
     let* (rt',mapping') = rt_of_ect v2 (Object.AddrOrPath.pointee aop) typ2 in
     let rt = make_owned_pointer v (ST_Ctype (to_sct typ2)) rt' in
     let mapping = 
       {obj = Obj (aop, None); res= (BT.Loc, v)} :: mapping' 
     in
     return (rt, mapping)
  | Void
  | Integer _
  | Struct _ ->
     let sct = to_sct typ in
     let bt = BT.of_sct sct in
     let rt = 
       RT.Computational ((v, bt), 
       Constraint (LC (IT.Representable (ST_Ctype sct, S (bt, v))),I))
     in
     let mapping = [{obj = Obj (aop, None); res = (bt, v)}] in
     return (rt, mapping)
     


let owned_pointer_ect typ = 
  let ECT.Typ (loc, _) = typ in
  let qs = CF.Ctype.{const = false; restrict = false; volatile = false} in
  ECT.Typ (loc, (Pointer (qs, loc, Owned, typ)))


type funinfo_extra = 
  {mapping : mapping;
   globs : Parse_ast.aarg list;
   fargs : Parse_ast.aarg list}

let make_fun_spec loc struct_decls globals arguments ret_sct attrs 
    : (FT.t * funinfo_extra, type_error) m = 
  let open FT in
  let open RT in
  let open Object.AddrOrPath in
  let* typ = Assertions.parse_function_type loc attrs globals (ret_sct, arguments) in

  let mapping = [] in
  let arg_ftt = fun rt -> rt in

  let (FT (FA {globs;args}, pre)) = typ in
  (* glob arguments *)
  let* (arg_ftt, mapping) = 
    ListM.fold_rightM (fun {name; asym; typ} (arg_ftt, mapping) ->
        let aop = Addr {label = Assertions.label_name Pre; v = name} in
        let* (arg_rt, mapping') = rt_of_ect asym aop (owned_pointer_ect typ) in
        return (Tools.comp (FT.of_lrt (RT.lrt arg_rt)) arg_ftt, mapping' @ mapping)
      ) globs (arg_ftt, mapping)
  in
  (* function arguments *)
  let* (arg_ftt, mapping) = 
    ListM.fold_rightM (fun {name; asym; typ} (arg_ftt, mapping) ->
        let aop = Addr {label = Assertions.label_name Pre; v = name} in
        let* (arg_rt, mapping') = rt_of_ect asym aop (owned_pointer_ect typ) in
        return (Tools.comp (FT.of_rt arg_rt) arg_ftt, mapping' @ mapping)
      ) args (arg_ftt, mapping)
  in
  let (FPre (preconditions, ret)) = pre in
  let* arg_ftt = 
    let* requires = Assertions.resolve_constraints mapping preconditions in
    return (Tools.comp arg_ftt (FT.mConstraints requires))
  in
  let init_mapping = mapping in

  let (FRet (FRT {ret; glob_rets; arg_rets}, post)) = ret in
  (* ret *)
  let* (ret_rt, mapping) = 
    let { name; vsym; typ } = ret in
    let aop = Path (Var {label = Assertions.label_name Post; v = name}) in
    let* (rt, mapping') = rt_of_ect vsym aop typ in
    return (rt, mapping' @ mapping)
  in
  let arg_ret_lrt = LRT.I in
  (* glob return resources *)
  let* (arg_ret_lrt, mapping) = 
    ListM.fold_rightM (fun {name; asym; typ} (arg_ret_lrts, mapping) ->
        let aop = Addr {label = Assertions.label_name Post; v = name} in
        let* (arg_ret_lrt, mapping') = rt_of_ect asym aop (owned_pointer_ect typ) in
        return (LRT.concat (RT.lrt arg_ret_lrt) arg_ret_lrts, mapping' @ mapping)
      ) glob_rets (arg_ret_lrt, mapping)
  in
  (* argument return resources *)
  let* (arg_ret_lrt, mapping) = 
    ListM.fold_rightM (fun {name; asym; typ} (arg_ret_lrts, mapping) ->
        let aop = Addr {label = Assertions.label_name Post; v = name} in
        let* (arg_ret_lrt, mapping') = rt_of_ect asym aop (owned_pointer_ect typ) in
        return (LRT.concat (RT.lrt arg_ret_lrt) arg_ret_lrts, mapping' @ mapping)
      ) arg_rets (arg_ret_lrt, mapping)
  in
  let ret_rt = RT.concat ret_rt arg_ret_lrt in
  let (FPost postconditions) = post in
  let* ret_rt = 
    let* ensures = Assertions.resolve_constraints mapping postconditions in
    return (RT.concat ret_rt (LRT.mConstraints ensures LRT.I))
  in

  let ft = arg_ftt (FT.I ret_rt) in

  return (ft, {mapping = init_mapping; globs; fargs = args})


  
let make_label_spec
      (loc : Loc.t) 
      (lsym: Sym.t)
      (extra: funinfo_extra)
      (largs : (Sym.t option * Sctypes.t) list) 
      attrs = 

  let open Object.AddrOrPath in
  let lname = match Sym.name lsym with
    | Some lname -> lname
    | None -> Sym.pp_string lsym (* check *)
  in
  let largs = List.map (fun (os, t) -> (Option.value (Sym.fresh ()) os, t)) largs in
  let* ltyp = Assertions.parse_label_type loc lname attrs extra.globs extra.fargs largs in
  
  let mapping = extra.mapping in
  let ltt = fun rt -> rt in
  let (LT (LA {globs; fargs; largs}, inv)) = ltyp in
  (* globs *)
  let* (ltt, mapping) = 
    ListM.fold_rightM (fun {name; asym; typ} (ltt, mapping) ->
        let aop = Addr {label = Assertions.label_name (Inv lname); v = name} in
        let* (arg_rt, mapping') = rt_of_ect asym aop (owned_pointer_ect typ) in
        return (Tools.comp (LT.of_lrt (RT.lrt arg_rt)) ltt, mapping' @ mapping)
      ) globs (ltt, mapping)
  in
  (* function arguments *)
  let* (ltt, mapping) = 
    ListM.fold_rightM (fun {name; asym; typ} (ltt, mapping) ->
        let aop = Addr {label = Assertions.label_name (Inv lname); v = name} in
        let* (arg_rt, mapping') = rt_of_ect asym aop (owned_pointer_ect typ) in
        return (Tools.comp (LT.of_lrt (RT.lrt arg_rt)) ltt, mapping' @ mapping)
      ) fargs (ltt, mapping)
  in
  (* label arguments *)
  let* (ltt, mapping) = 
    ListM.fold_rightM (fun {name; vsym; typ} (ltt, mapping) ->
        let aop = Path (Var {label = Assertions.label_name (Inv lname); v = name}) in
        let* (larg_rt, mapping') = rt_of_ect vsym aop typ in
        return (Tools.comp (LT.of_rt larg_rt) ltt, mapping' @ mapping)
      ) largs (ltt, mapping)
  in

  let (LInv lcs) = inv in
  let* ltt = 
    let* lcs = Assertions.resolve_constraints mapping lcs in
    return (Tools.comp ltt (LT.mConstraints lcs))
  in

  let lt = ltt (LT.I False.False) in
  return (lt, mapping)




