open Report
module IT = IndexTerms
module BT = BaseTypes
module RE = Resources
module RET = ResourceTypes
module LC = LogicalConstraints
module LS = LogicalSorts
module SymSet = Set.Make(Sym)
module SymMap = Map.Make(Sym)
module StringMap = Map.Make(String)
module SymPairMap = Map.Make(SymRel.SymPair)
module C = Context
module Loc = Locations
module S = Solver

open ResourceTypes
open IndexTerms
open Pp
open C
open Resources








let clause_has_resource req c =
  let open LogicalArgumentTypes in
  let rec f = function
    | Resource ((_, (r, _)), _, c) -> RET.same_predicate_name req r || f c
    | Constraint (_, _, c) -> f c
    | Define (_, _, c) -> f c
    | I _ -> false
  in
  let open ResourcePredicates in
  f c.packing_ft

let relevant_predicate_clauses global oname req =
  let open Global in
  let open ResourcePredicates in
  let clauses = 
    let defs = SymMap.bindings global.resource_predicates in
    List.concat_map (fun (nm, def) -> 
        match def.clauses with
        | Some clauses -> List.map (fun c -> (nm, c)) clauses
        | None -> []
      ) defs
  in
  List.filter (fun (nm, c) -> Option.equal Sym.equal (Some nm) oname
    || clause_has_resource req c) clauses

let state ctxt (model_with_q : Solver.model_with_q) (orequest : RET.t option) =

  let prev = ! Pp.html_escapes in
  Pp.html_escapes := true;

  let model, quantifier_counter_model = model_with_q in

  let l_tr = let open Context in ctxt.location_trace in
  let location_trace = List.map (fun l -> Pp.string (Locations.to_string l))
    (List.rev l_tr) in

  let evaluate it = Solver.eval ctxt.global model it in

  let mevaluate it = 
    match evaluate it with
    | Some v -> IT.pp v
    | None -> parens !^"not evaluated"
  in

  let variables = 
    List.map (fun ((s, ls), _) ->
        {var = Sym.pp s; 
         value = mevaluate (sym_ (s, ls))}
      ) ctxt.logical
  in

  let constraints = List.map LC.pp (LCSet.elements ctxt.constraints) in

  let req_cmp = Option.bind orequest (Spans.spans_compare_for_pp model ctxt.global) in
  let req_entry req_cmp req = {
      res = RET.pp req;
      res_span = Spans.pp_model_spans model ctxt.global req_cmp req
    } 
  in
  let res_entry req_cmp res = {
      res = RE.pp res;
      res_span = Spans.pp_model_spans model ctxt.global req_cmp (RE.request res)
    } 
  in

  begin match orequest with
    | None -> ()
    | Some req -> Spans.diag_req (get_rs ctxt) req model ctxt.global
  end;


  let resources = 
    let (same_res, diff_res) = match orequest with
      | None -> ([], get_rs ctxt)
      | Some req -> List.partition (fun r -> RET.same_predicate_name req (RE.request r)) (get_rs ctxt)
    in
    List.map (res_entry req_cmp) (same_res @ diff_res)
  in

  let predicate_hints = 
    let predicate_name = match Option.map predicate_name orequest with
      | Some (PName sym) -> Some sym
      | _ -> None
    in
    let predicate_clauses = match orequest with
      | None -> []
      | Some req -> relevant_predicate_clauses ctxt.global predicate_name req
    in
    let doc_clause (nm, c) =
      let open ResourcePredicates in
      {
        cond = IT.pp c.guard;
        clause = LogicalArgumentTypes.pp OutputDef.pp c.packing_ft
      }
    in
    List.map doc_clause predicate_clauses 
  in
  let requested = match orequest with
    | None -> []
    | Some req -> [req_entry None req]
  in

  Pp.html_escapes := prev;

  { location_trace;
    variables;
    requested;
    resources;
    predicate_hints;
    constraints }







