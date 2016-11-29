open Decl_kinds
open Pp
open Term
open Loc
open Names
open Tacmach
open Entries
open Declarations
open Declare
open Libnames
open Util
open Constrintern
open Topconstr
open Constrexpr
open Constrexpr_ops
open Context

let cnt = ref 0 
       
let dl x = (dummy_loc, x)
let hole = CHole (dummy_loc, None, Misctypes.IntroAnonymous, None)

(* Everything marked "Opaque" should have its implementation be hidden in the .mli *)

type coq_expr = constr_expr (* Opaque *)
                 
(* Non-dependent version *)
type var = Id.t (* Opaque *)

let gVar (x : var) : coq_expr =
  CRef (Ident (dl x),None)

(* Maybe this should do checks? *)
let gInject s = CRef (Qualid (Loc.ghost, qualid_of_string s), None)

type ty_param = Id.t (* Opaque *)
let ty_param_to_string (x : Id.t) = Id.to_string x

let gTyParam = mkIdentC

type ty_ctr   = Id.t (* Opaque *)
let ty_ctr_to_string (x : ty_ctr) = Id.to_string x

let gTyCtr = mkIdentC

type arg = local_binder
let gArg ?assumName:(an=hole) ?assumType:(at=hole) ?assumImplicit:(ai=false) ?assumGeneralized:(ag=false) _ =
  let n = match an with
    | CRef (Ident (loc,id),_) -> (loc,Name id)
    | CRef (Qualid (loc, q), _) -> let (_,id) = repr_qualid q in (loc, Name id)
    | CHole (loc,_,_,_) -> (loc,Anonymous)
    | a -> failwith "This expression should be a name" in
  LocalRawAssum ( [n],
                  (if ag then Generalized (Implicit, Implicit, false)                       
                   else if ai then Default Implicit else Default Explicit),
                  at )
               
let str_lst_to_string sep (ss : string list) = 
  List.fold_left (fun acc s -> acc ^ sep ^ s) "" ss

type coq_type = 
  | Arrow of coq_type * coq_type
  | TyCtr of ty_ctr * coq_type list
  | TyParam of ty_param

let rec coq_type_to_string ct = 
  match ct with
  | Arrow (c1, c2) -> Printf.sprintf "%s -> %s" (coq_type_to_string c1) (coq_type_to_string c2)
  | TyCtr (ty_ctr, cs) -> ty_ctr_to_string ty_ctr ^ " " ^ str_lst_to_string " " (List.map coq_type_to_string cs)
  | TyParam tp -> ty_param_to_string tp

type constructor = Id.t (* Opaque *)
let constructor_to_string (x : constructor) = Id.to_string x
let gCtr = mkIdentC
let injectCtr s = Id.of_string s

type ctr_rep = constructor * coq_type 
let ctr_rep_to_string (ctr, ct) = 
  Printf.sprintf "%s : %s" (constructor_to_string ctr) (coq_type_to_string ct)

type dt_rep = ty_ctr * ty_param list * ctr_rep list
let dt_rep_to_string (ty_ctr, ty_params, ctrs) = 
  Printf.sprintf "%s %s :=\n%s" (ty_ctr_to_string ty_ctr) 
                                (str_lst_to_string " "  (List.map ty_param_to_string ty_params))
                                (str_lst_to_string "\n" (List.map ctr_rep_to_string  ctrs))
                                 

let (>>=) m f = 
  match m with
  | Some x -> f x 
  | None -> None

let isSome m = 
  match m with 
  | Some _ -> true
  | None   -> false
              
let rec cat_maybes = function 
  | [] -> []
  | (Some x :: mxs) -> x :: cat_maybes mxs
  | None :: mxs -> cat_maybes mxs

let foldM f b l = List.fold_left (fun accm x -> 
                                  accm >>= fun acc ->
                                  f acc x
                                 ) b l
let sequenceM f l = 
  (foldM (fun acc x -> f x >>= fun x' -> Some (x' :: acc)) (Some []) l) >>= fun l -> Some (List.rev l)

let parse_type_params arity_ctxt =
  let param_names =
    foldM (fun acc (n, _, _) -> 
           match n with
           | Name id   -> Some (id  :: acc)
           | Anonymous -> msgerr (str "Unnamed type parameter?" ++ fnl ()); None
          ) (Some []) arity_ctxt in
  param_names
(* For /trunk 
    Rel.fold_inside
      (fun accm decl ->
       accm >>= fun acc ->
       match Rel.Declaration.get_name decl with
       | Name id -> Some (id :: acc)
       | Anonymous -> msgerr (str "Unnamed type parameter?" ++ fnl ()); None
      ) [] arity_ctxt in 
  param_names
*)

let rec arrowify terminal l = 
  match l with
  | [] -> terminal
  | x::xs -> Arrow (x, arrowify terminal xs)

(* Receives number of type parameters and one_inductive_body.
   -> Possibly ty_param list as well? 
   Returns list of constructor representations 
 *)
let parse_constructors nparams param_names result_ty oib : ctr_rep list option =
  
  let parse_constructor branch =
    let (ctr_id, ty_ctr) = branch in

    let (_, ty) = Term.decompose_prod_n nparams ty_ctr in
    
    let ctr_pats = if Term.isConst ty then [] else fst (Term.decompose_prod ty) in

    let _, pat_types = List.split (List.rev ctr_pats) in

    msgerr (str (Id.to_string ctr_id) ++ fnl ());
    let rec aux i ty = 
      if isRel ty then begin 
        msgerr (int (i + nparams) ++ str " Rel " ++ int (destRel ty) ++ fnl ());
        let db = destRel ty in
        if i + nparams = db then (* Current inductive, no params *)
          Some (TyCtr (oib.mind_typename, []))
        else (* [i + nparams - db]th parameter *)
          try Some (TyParam (List.nth param_names (i + nparams - db - 1)))
          with _ -> msgerr (str "nth failed: " ++ int (i + nparams - db - 1) ++ fnl ()); None
      end 
      else if isApp ty then begin
        let (ctr, tms) = decompose_app ty in 
        foldM (fun acc ty -> 
               aux i ty >>= fun ty' -> Some (ty' :: acc)
              ) (Some []) tms >>= fun tms' ->
        match aux i ctr with
        | Some (TyCtr (c, _)) -> Some (TyCtr (c, List.rev tms'))
(*        | Some (TyParam p) -> Some (TyCtr (p, tms')) *)
        | None -> msgerr (str "Aux failed?" ++ fnl ()); None
      end
      else if isInd ty then begin
        let ((mind,_),_) = destInd ty in
        Some (TyCtr (Label.to_id (MutInd.label mind), []))
      end
      else (msgerr (str "Case Not Handled" ++ fnl()); None)

    in sequenceM (fun x -> x) (List.mapi aux (List.map (Vars.lift (-1)) pat_types)) >>= fun types ->
       Some (ctr_id, arrowify result_ty types)
  in

  sequenceM parse_constructor (List.combine (Array.to_list oib.mind_consnames)
                                            (Array.to_list oib.mind_nf_lc))

(* Convert mutual_inductive_body to this representation, if possible *)
let dt_rep_from_mib mib = 
  if Array.length mib.mind_packets > 1 then begin
    msgerr (str "Mutual inductive types not supported yet." ++ fnl());
    None
  end else 
    let oib = mib.mind_packets.(0) in
    let ty_ctr = oib.mind_typename in 
    parse_type_params oib.mind_arity_ctxt >>= fun ty_params ->
    let result_ctr = TyCtr (ty_ctr, List.map (fun x -> TyParam x) ty_params) in
    parse_constructors mib.mind_nparams ty_params result_ctr oib >>= fun ctr_reps ->
    Some (ty_ctr, ty_params, ctr_reps)

let coerce_reference_to_dt_rep c = 
  let r = match c with
    | CRef (r,_) -> r
    | _ -> failwith "Not a reference" in

  (* Extract id/string representation - which to use? :/ *)
  let qidl = qualid_of_reference r in

  let env = Global.env () in
  
  let glob_ref = Nametab.global r in
  let (mind,_) = Globnames.destIndRef glob_ref in
  let mib = Environ.lookup_mind mind env in
  
  dt_rep_from_mib mib
                  
let fresh_name n : Id.t =
    let base = Names.id_of_string n in

  (** [is_visible_name id] returns [true] if [id] is already
      used on the Coq side. *)
    let is_visible_name id =
      try
        ignore (Nametab.locate (Libnames.qualid_of_ident id));
        true
      with Not_found -> false
    in
    (** Safe fresh name generation. *)
    Namegen.next_ident_away_from base is_visible_name

let make_up_name () : Id.t =
  let id = fresh_name (Printf.sprintf "mu%d" (!cnt)) in
  cnt := !cnt + 1;
  id

let gApp ?explicit:(expl=false) c cs =
  if expl then
    match c with
    | CRef (r,_) -> CAppExpl (dummy_loc, (None, r, None), cs)
    | _ -> failwith "invalid argument to gApp"
  else mkAppC (c, cs)

let gFunWithArgs args f_body =
  let xvs = List.map (fun (LocalRawAssum ([_, n], _, _)) ->
                      match n with
                      | Name x -> x
                      | _ -> make_up_name ()
                     ) args in
  let fun_body = f_body xvs in
  mkCLambdaN dummy_loc args fun_body

let gFun xss (f_body : var list -> coq_expr) =
  let xvs = List.map (fun x -> fresh_name x) xss in
  (* TODO: optional argument types for xss *)
  let binder_list = List.map (fun x -> LocalRawAssum ([(dummy_loc, Name x)], Default Explicit, hole)) xvs in
  let fun_body = f_body xvs in
  mkCLambdaN dummy_loc binder_list fun_body 

let gFunTyped xts (f_body : var list -> coq_expr) =
  let xvs = List.map (fun (x,t) -> (fresh_name x,t)) xts in
  (* TODO: optional argument types for xss *)
  let binder_list = List.map (fun (x,t) -> LocalRawAssum ([(dummy_loc, Name x)], Default Explicit, t)) xvs in
  let fun_body = f_body (List.map fst xvs) in
  mkCLambdaN dummy_loc binder_list fun_body 

(* with Explicit/Implicit annotations *)  
let gRecFunInWithArgs (fs : string) args (f_body : (var * var list) -> coq_expr) (let_body : var -> coq_expr) = 
  let fv  = fresh_name fs in
  let xvs = List.map (fun (LocalRawAssum ([_, n], _, _)) ->
                      match n with
                      | Name x -> x
                      | _ -> make_up_name ()
                     ) args in
  let fix_body = f_body (fv, xvs) in
  CLetIn (dummy_loc, dl (Name fv), 
          G_constr.mk_fix (dummy_loc, true, dl fv, [(dl fv, args, (None, CStructRec), fix_body, (dl None))]),
          let_body fv)
             
let gRecFunIn (fs : string) (xss : string list) (f_body : (var * var list) -> coq_expr) (let_body : var -> coq_expr) =
  let xss' = List.map (fun s -> fresh_name s) xss in
  gRecFunInWithArgs fs (List.map (fun x -> gArg ~assumName:(gVar x) ()) xss') f_body let_body 

let gMatch discr (branches : (constructor * string list * (var list -> coq_expr)) list) : coq_expr =
  CCases (dummy_loc,
          Term.RegularStyle,
          None (* return *), 
          [(discr, (None, None))], (* single discriminee, no as/in *)
          List.map (fun (c, cs, bf) -> 
                      let cvs : Id.t list = List.map fresh_name cs in
                      (dummy_loc,
                       [dl [CPatCstr (dummy_loc,
                                      Ident (dl c), (* constructor  *)
                                      [],
                                      List.map (fun s -> CPatAtom (dummy_loc, Some (Ident (dl s)))) cvs (* Constructor applied to patterns *)
                                     )
                           ]
                       ],
                       bf cvs 
                      )
                   ) branches)

let gRecord names_and_bodies =
  CRecord (dummy_loc, None, List.map (fun (n,b) -> (Ident (dummy_loc, id_of_string n), b)) names_and_bodies)

let gAnnot (p : coq_expr) (tau : coq_expr) =
  CCast (dummy_loc, p, CastConv tau)

(* Generic List Manipulations *)
let list_nil = gInject "nil"
let lst_append c1 c2 = gApp (gInject "app") [c1; c2]
let rec lst_appends = function
  | [] -> list_nil
  | c::cs -> lst_append c (lst_appends cs)
let gCons x xs = gApp (gInject "cons") [x; xs]                        
let rec gList = function 
  | [] -> gInject "nil"
  | x::xs -> gCons x (gList xs)

(* Generic String Manipulations *)
let gStr s = CPrim (dummy_loc, String s)
let emptyString = gInject "Coq.Strings.String.EmptyString"
let str_append c1 c2 = gApp (gInject "Coq.Strings.String.append") [c1; c2]
let rec str_appends cs = 
  match cs with 
  | []  -> emptyString
  | [c] -> c
  | c1::cs' -> str_append c1 (str_appends cs')

(* Pair *)
let gPair (c1, c2) = gApp (gInject "pair") [c1;c2]

(* Int *)
let gInt n = CPrim (dummy_loc, Numeral (Bigint.of_int n))
let gSucc x = gApp (gInject "S") [x]
let rec maximum = function
  | [] -> failwith "maximum called with empty list"
  | [c] -> c
  | (c::cs) -> gApp (gInject "max") [c; maximum cs]
let gle x y = gApp (gInject "leq") [x; y]
let glt x y = gle (gApp (gInject "S") [x]) y
                          
(* Gen combinators *)
let returnGen c = gApp (gInject "returnGen") [c]
let bindGen cg xn cf = 
  gApp (gInject "bindGen") [cg; gFun [xn] (fun [x] -> cf x)]

let oneof l =
  match l with
  | [] -> failwith "oneof used with empty list"
  | [c] -> c
  | c::cs -> gApp (gInject "oneof") [c; gList l]
       
let frequency l =
  match l with
  | [] -> failwith "frequency used with empty list"
  | [(_,c)] -> c
  | (_,c)::cs -> gApp (gInject "frequency") [c; gList (List.map gPair l)]
       
(* Recursion combinators / fold *)
(* fold_ty : ( a -> coq_type -> a ) -> ( ty_ctr * coq_type list -> a ) -> ( ty_param -> a ) -> coq_type -> a *)
let rec fold_ty arrow_f ty_ctr_f ty_param_f ty = 
  match ty with
  | Arrow (ty1, ty2) -> 
     let acc = fold_ty arrow_f ty_ctr_f ty_param_f ty2 in 
     arrow_f acc ty1 
  | TyCtr (ctr, tys) -> ty_ctr_f (ctr, tys)
  | TyParam tp -> ty_param_f tp

let fold_ty' arrow_f base ty = 
  fold_ty arrow_f (fun _ -> base) (fun _ -> base) ty

(* Generate Type Names *)
let generate_names_from_type base_name ty =
  snd (fold_ty' (fun (i, names) _ -> (i+1, (Printf.sprintf "%s%d" base_name i) :: names)) (0, []) ty)

(* a := var list -> var -> a *)
let fold_ty_vars (f : var list -> var -> coq_type -> 'a) (mappend : 'a -> 'a -> 'a) (base : 'a) ty : var list -> 'a =
  fun allVars -> fold_ty' (fun acc ty -> fun allVars (v::vs) -> mappend (f allVars v ty) (acc allVars vs)) (fun _ _ -> base) ty allVars allVars

(* Declarations *)

let defineConstant s c = 
  let id = fresh_name s in 
  Vernacentries.interp (dummy_loc,  Vernacexpr.VernacDefinition ((None, Definition), (dl id, None), DefineBody ([], None, c, None)));
  id 
                          
(* Declare an instance *)
let create_names_for_anon a =
  match a with 
  | LocalRawAssum ([(loc, n)], x, y) ->
     begin match n with
           | Name x -> (x, a)
           | Anonymous -> let n = make_up_name () in
                          (n, LocalRawAssum ([(loc, Name n)], x, y))
     end
  | _ -> failwith "Non RawAssum in create_names"
    
let declare_class_instance instance_arguments instance_name instance_type instance_record =
  let (vars,iargs) = List.split (List.map create_names_for_anon instance_arguments) in
  ignore (Classes.new_instance true 
                               iargs
                       (((dummy_loc, (Name (id_of_string instance_name))), None)
                       , Decl_kinds.Explicit, instance_type) 
                       (Some (true, instance_record vars)) (* TODO: true or false? *)
                       None
         )