module BT = BaseTypes
module IT = IndexTerms
module GT = GenTerms
module CtA = Fulminate.Cn_to_ail
module Utils = Fulminate.Executable_spec_utils

let gen_syms_bits (name : string) : (BT.t * Sym.t) list =
  let aux (bt : BT.t) : BT.t * Sym.t =
    match BT.is_bits_bt bt with
    | Some (sgn, bits) ->
      let bt = BT.Bits (sgn, bits) in
      ( bt,
        Sym.fresh
          (String.concat
             "_"
             [ "cn_gen";
               name;
               Option.get (Utils.get_typedef_string (CtA.bt_to_ail_ctype bt))
             ]) )
    | None -> failwith Pp.(plain (BT.pp bt ^^ space ^^ at ^^ space ^^ string __LOC__))
  in
  [ aux (BT.Bits (Unsigned, 8));
    aux (BT.Bits (Signed, 8));
    aux (BT.Bits (Unsigned, 16));
    aux (BT.Bits (Signed, 16));
    aux (BT.Bits (Unsigned, 32));
    aux (BT.Bits (Signed, 32));
    aux (BT.Bits (Unsigned, 64));
    aux (BT.Bits (Signed, 64))
  ]


let mult_check (it_mult : IT.t) gt loc =
  GT.assert_
    (T (IT.gt_ (it_mult, IT.num_lit_ Z.zero (IT.get_bt it_mult) loc) loc), gt)
    loc


let lt_check (it_max : IT.t) gt loc =
  let sgn, sz = Option.get (BT.is_bits_bt (IT.get_bt it_max)) in
  let min, _ = BT.bits_range (sgn, sz) in
  GT.assert_ (T (IT.gt_ (it_max, IT.num_lit_ min (IT.get_bt it_max) loc) loc), gt) loc


let range_check (it_min : IT.t) (it_max : IT.t) gt loc =
  let it_min, cmp, it_max =
    match (it_min, it_max) with
    | IT (Binop (Sub, it_min', IT (Const (Bits (_, n)), _, _)), _, _), _
    | IT (Binop (Sub, it_min', IT (Const (Z n), _, _)), _, _), _
      when Z.equal n Z.one ->
      (it_min', IT.le_, it_max)
    | _, IT (Binop (Add, it_max', IT (Const (Bits (_, n)), _, _)), _, _)
    | _, IT (Binop (Add, it_max', IT (Const (Z n), _, _)), _, _) ->
      (it_min, IT.le_, it_max')
    | _ -> (it_min, IT.lt_, it_max)
  in
  GT.assert_ (T (cmp (it_min, it_max) loc), lt_check it_max gt loc) loc


let mult_range_check (it_mult : IT.t) (it_min : IT.t) (it_max : IT.t) gt loc =
  mult_check it_mult (range_check it_min it_max gt loc) loc


let min_sym = Sym.fresh "min"

let ge_gen_sym_db = gen_syms_bits "ge"

let ge_gen (it_min : IT.t) (bt : BT.t) loc : GT.t =
  let fsym = List.assoc BT.equal bt ge_gen_sym_db in
  GT.call_ (fsym, [ (min_sym, it_min) ]) bt loc


let max_sym = Sym.fresh "max"

let lt_gen_sym_db = gen_syms_bits "lt"

let lt_gen (it_max : IT.t) (bt : BT.t) loc : GT.t =
  let fsym = List.assoc BT.equal bt lt_gen_sym_db in
  lt_check it_max (GT.call_ (fsym, [ (max_sym, it_max) ]) bt loc) loc


let range_gen_sym_db = gen_syms_bits "range"

let range_gen (it_min : IT.t) (it_max : IT.t) (bt : BT.t) loc : GT.t =
  let fsym = List.assoc BT.equal bt range_gen_sym_db in
  range_check
    it_min
    it_max
    (GT.call_ (fsym, [ (min_sym, it_min); (max_sym, it_max) ]) bt loc)
    loc


let mult_sym = Sym.fresh "mult"

let mult_gen_sym_db = gen_syms_bits "mult"

let mult_gen (it_mult : IT.t) (bt : BT.t) loc : GT.t =
  let fsym = List.assoc BT.equal bt mult_gen_sym_db in
  mult_check
    it_mult
    (GT.assert_
       ( T (IT.gt_ (it_mult, IT.num_lit_ Z.zero bt loc) loc),
         GT.call_ (fsym, [ (mult_sym, it_mult) ]) bt loc )
       loc)
    loc


let mult_ge_gen_sym_db = gen_syms_bits "mult_ge"

let mult_ge_gen (it_mult : IT.t) (it_min : IT.t) (bt : BT.t) loc : GT.t =
  let fsym = List.assoc BT.equal bt mult_ge_gen_sym_db in
  mult_check
    it_mult
    (GT.call_ (fsym, [ (mult_sym, it_mult); (min_sym, it_min) ]) bt loc)
    loc


let mult_lt_gen_sym_db = gen_syms_bits "mult_lt"

let mult_lt_gen (it_mult : IT.t) (it_max : IT.t) (bt : BT.t) loc : GT.t =
  let fsym = List.assoc BT.equal bt mult_lt_gen_sym_db in
  mult_check
    it_mult
    (lt_check
       it_max
       (GT.call_ (fsym, [ (mult_sym, it_mult); (max_sym, it_max) ]) bt loc)
       loc)
    loc


let mult_range_gen_sym_db = gen_syms_bits "mult_range"

let mult_range_gen (it_mult : IT.t) (it_min : IT.t) (it_max : IT.t) (bt : BT.t) loc : GT.t
  =
  let fsym = List.assoc BT.equal bt mult_range_gen_sym_db in
  mult_range_check
    it_mult
    it_min
    it_max
    (GT.call_
       (fsym, [ (mult_sym, it_mult); (min_sym, it_min); (max_sym, it_max) ])
       bt
       loc)
    loc


let align_sym = Sym.fresh "align"

let size_sym = Sym.fresh "size"

let aligned_alloc_gen_sym = Sym.fresh "cn_gen_aligned_alloc"

let aligned_alloc_gen (it_align : IT.t) (it_size : IT.t) loc : GT.t =
  let it_align =
    if BT.equal (IT.get_bt it_align) Memory.size_bt then
      it_align
    else
      IT.cast_ Memory.size_bt it_align loc
  in
  let it_size =
    if BT.equal (IT.get_bt it_size) Memory.size_bt then
      it_size
    else
      IT.cast_ Memory.size_bt it_align loc
  in
  GT.call_
    (aligned_alloc_gen_sym, [ (align_sym, it_align); (size_sym, it_size) ])
    (BT.Loc ())
    loc


let is_builtin (sym : Sym.t) : bool =
  [ ge_gen_sym_db;
    lt_gen_sym_db;
    range_gen_sym_db;
    mult_gen_sym_db;
    mult_range_gen_sym_db
  ]
  |> List.map (List.map snd)
  |> List.flatten
  |> List.cons aligned_alloc_gen_sym
  |> List.mem Sym.equal sym
