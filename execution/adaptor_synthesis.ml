(* Extra file with helper code for adaptor synthesis. The functions 
   defined here are used in exec_fuzzloop.ml and exec_runloop.ml *)

module V = Vine;;

open Fragment_machine;;
open Exec_options;;

(*** general helper code used in multiple adaptors ***)

let get_ite_expr arg op const_type const then_val else_val = 
  V.Ite(V.BinOp(op, arg, V.Constant(V.Int(const_type, const))),
        then_val,
        else_val)

let rec get_ite_arg_expr fm arg regs n =
  if n = 1L
  then fm#get_reg_symbolic (List.nth regs 0) 
  else get_ite_expr arg V.EQ V.REG_32 (Int64.sub n 1L) 
         (fm#get_reg_symbolic (List.nth regs ((Int64.to_int n) - 1)))
         (get_ite_arg_expr fm arg regs (Int64.sub n 1L))

(* build an arithmetic expression tree; this function is a little messy because 
   it takes so many arguments, but it's useful to reuse code between the integer 
   and floating point adaptor code *)
let get_arithmetic_expr fm var arg_regs val_type out_nargs get_oper_expr depth =
  let rec build_tree d base =
    if d <= 0 then failwith "Bad tree depth for arithmetic adaptor"
    else 
      let node_type = fm#get_fresh_symbolic (var ^ "_type_" ^ base) 8 in
      let node_val = fm#get_fresh_symbolic (var ^ "_val_" ^ base) 
                       (if val_type = V.REG_32 then 32 else 64) in
      if d = 1 
      then get_ite_expr node_type V.EQ V.REG_8 0L 
             node_val 
             (let reg_expr = get_ite_arg_expr fm node_val arg_regs out_nargs in
              if val_type = V.REG_32 
              then V.Cast(V.CAST_LOW, V.REG_32, reg_expr)
              else reg_expr)
      else
        let left_expr = build_tree (d-1) (base ^ "0") in
        let right_expr = build_tree (d-1) (base ^ "1") in
        get_ite_expr node_type V.EQ V.REG_8 0L 
          node_val 
          (get_ite_expr node_type V.EQ V.REG_8 1L
             (let reg_expr = get_ite_arg_expr fm node_val arg_regs out_nargs in
              if val_type = V.REG_32 
              then V.Cast(V.CAST_LOW, V.REG_32, reg_expr)
              else reg_expr) 
             (get_oper_expr node_val left_expr right_expr)) in
  build_tree depth "R"

(* add extra conditions on the structure of the int/float arithmetic adaptors' 
   expression trees; there are a lot of arguments here too, but this saves
   some copying & pasting later *)
let add_arithmetic_tree_conditions fm var_name val_type out_nargs 
      restrict_const_node binops unops depth =
  (* zeros-out nodes in an arithmetic expression subtree *)
  let rec zero_lower d base =
    let node_type = fm#get_fresh_symbolic (var_name ^ "_type_" ^ base) 8 in
    let node_val = fm#get_fresh_symbolic (var_name ^ "_val_" ^ base)
                     (if val_type = V.REG_32 then 32 else 64) in
    if d = 1 
    then 
      V.BinOp(V.BITAND, 
              V.BinOp(V.EQ, node_type, V.Constant(V.Int(V.REG_8, 0L))), 
              V.BinOp(V.EQ, node_val, V.Constant(V.Int(val_type, 0L))))
    else
      V.BinOp(V.BITAND, 
              V.BinOp(
                V.BITAND, 
                V.BinOp(V.EQ, node_type, V.Constant(V.Int(V.REG_8, 0L))), 
                V.BinOp(V.EQ, node_val, V.Constant(V.Int(val_type, 0L)))),
              V.BinOp(
                V.BITAND, 
                zero_lower (d-1) (base ^ "0"),
                zero_lower (d-1) (base ^ "1"))) in
  (* adds various conditions for every node in a tree *)
  let rec traverse_tree d base = 
    if d <= 0 then failwith "Bad tree depth for arithmetic adaptor"
    else 
      let node_type = fm#get_fresh_symbolic (var_name ^ "_type_" ^ base) 8 in
      let node_val = fm#get_fresh_symbolic (var_name ^ "_val_" ^ base)
                       (if val_type = V.REG_32 then 32 else 64) in
        if d = 1
        then 
          (* in this case we are at a leaf in the tree, we require:
             - type <= 1
             - if type = 1, then val < (# of arguments)
             - if type = 0, then val must be in the specified range,
               or be one of the specified values *)
          synth_extra_conditions := 
            (V.BinOp(V.LE, node_type, V.Constant(V.Int(V.REG_8, 1L)))) ::
            (V.BinOp(
               V.BITOR,
               V.BinOp(V.NEQ, node_type, V.Constant(V.Int(V.REG_8, 1L))),
               V.BinOp(V.LT, node_val, V.Constant(V.Int(val_type, out_nargs))))) :: 
            (restrict_const_node node_type node_val) ::
            !synth_extra_conditions
        else
          (* in this case we are at a non-leaf node, we require:
             - type <= 2
             - if type = 1, then val < (# of arguments)
             - if type = 2, then val < (# of operators)
             - if type = 0, then val must be in the specified range,
               or be one of the specified values
             - if the type is 0 or 1 (constant or variable) then the nodes in
               the left and right subtrees must be zero
             - if type = 2 and val corresponds to a unary operator, then nodes
               in the right subtree must be zero *)
          (synth_extra_conditions := 
            (V.BinOp(V.LE, node_type, V.Constant(V.Int(V.REG_8, 2L)))) ::
            (V.BinOp(
               V.BITOR,
               V.BinOp(V.NEQ, node_type, V.Constant(V.Int(V.REG_8, 1L))),
               V.BinOp(V.LT, node_val, V.Constant(V.Int(val_type, out_nargs))))) :: 
            (V.BinOp(
               V.BITOR,
               V.BinOp(V.NEQ, node_type, V.Constant(V.Int(V.REG_8, 2L))),
               V.BinOp(
                 V.LT, 
                 node_val, 
                 V.Constant
                 (V.Int(
                    val_type, 
                    Int64.of_int ((List.length binops) + (List.length unops))))))) ::
            (restrict_const_node node_type node_val) ::
            (V.BinOp(
               V.BITOR,
               V.BinOp(V.EQ, node_type, V.Constant(V.Int(V.REG_8, 2L))),
               V.BinOp(V.BITAND, 
                       zero_lower (d-1) (base ^ "0"), 
                       zero_lower (d-1) (base ^ "1")))) ::
            (V.BinOp(
               V.BITOR,
               V.BinOp(
                 V.BITOR, 
                 V.BinOp(V.NEQ, node_type, V.Constant(V.Int(V.REG_8, 2L))), 
                 V.BinOp(V.LT, node_val, 
                         V.Constant(
                           V.Int(
                             val_type, 
                             Int64.of_int (List.length binops))))),
               zero_lower (d-1) (base ^ "1"))) ::
            !synth_extra_conditions;
            traverse_tree (d-1) (base ^ "0");
            traverse_tree (d-1) (base ^ "1")) in
  traverse_tree depth "R"

(*** integer arithmetic adaptor ***)

(* use the variables below to specify the kinds of adaptors and 
   counterexamples that can be synthesized; these variables will be used
   in arithmetic_int_adaptor and arithmetic_int_extra_conditions *)
(* tree depth *)
let int_arith_depth = 3
(* 32 or 64-bit values (int vs. long int) *)
let int_val_type = V.REG_32
(* binary and unary operators; all possible operators:
   V.PLUS; V.MINUS; V.TIMES; V.BITAND; V.BITOR; V.XOR; V.DIVIDE; 
   V.SDIVIDE;V.MOD; V.SMOD; V.LSHIFT; V.RSHIFT; V.ARSHIFT;
   V.NEG; V.NOT *)
let int_binops = [V.PLUS; V.MINUS; V.TIMES; V.BITAND; V.BITOR; V.XOR]
let int_unops = [V.NEG; V.NOT]
(* restrict the constant values generated; int_restrict_constant_range
   should be 'None' or 'Some (lower, upper)' and int_restrict_constant_list 
   should be 'None' or 'Some [v1; v2; ...; vn]' *)
let int_restrict_constant_range = None
let int_restrict_constant_list = None
(* restrict the counterexamples generated; int_restrict_counterexample_range
   should be 'None' or 'Some (lower, upper)' and int_restrict_counterexample_list 
   should be 'None' or 'Some [v1; v2; ...; vn]' *)
let int_restrict_counterexample_range = None
let int_restrict_counterexample_list = None

(* creates symbolic variables representing the adaptor function and encodes
   the rules for applying the adaptor function; this function is called in 
   exec_runloop *)
let arithmetic_int_adaptor fm out_nargs in_nargs =
  (* argument registers -- assumes x86-64 *)
  let arg_regs = [R_RDI;R_RSI;R_RDX;R_RCX;R_R8;R_R9] in
  (* operators that require special handling *)
  let special_type1 = [V.DIVIDE; V.SDIVIDE; V.MOD; V.SMOD] in
  let special_type2 = [V.LSHIFT; V.RSHIFT; V.ARSHIFT] in
  (* builds an expression that applies some operator to apply to l and r *)
  let get_oper_expr node_value l r =
    let rec unop_expr ops n =
      match ops with 
      | [] -> failwith "Missing operators for the arithmetic adaptor"
      | unop::[] -> V.UnOp(unop, l)
      | unop::tl -> 
          get_ite_expr node_value V.EQ int_val_type n
            (V.UnOp(unop, l))
            (unop_expr tl (Int64.add n 1L)) in
    let rec binop_expr ops n =
      match ops with 
      | [] -> unop_expr int_unops n
      | binop::tl -> 
          let expr = 
            if (List.mem binop special_type1)
            then (* accounts for div. by zero *)
              V.BinOp(
                binop, l, 
                get_ite_expr r V.EQ int_val_type 0L 
                  (V.Constant(V.Int(int_val_type, 1L))) r)
            else 
              if (List.mem binop special_type2)
              then (* forces shifts by valid values *)
                V.BinOp(
                  binop, l, 
                  V.BinOp(
                    V.BITAND, r, 
                    if int_val_type = V.REG_32
                    then V.Constant(V.Int(int_val_type, 31L))
                    else V.Constant(V.Int(int_val_type, 63L))))
              else (* standard binary operator application *)
                V.BinOp(binop, l, r) in
          if (tl = [] && int_unops = [])
          then expr
          else get_ite_expr node_value V.EQ int_val_type n
                 expr (binop_expr tl (Int64.add n 1L)) in
    binop_expr int_binops 0L in
  let rec main_loop n =
    let var_name = String.make 1 (Char.chr ((Char.code 'a') + n)) in
    fm#set_reg_symbolic (List.nth arg_regs n) 
      (get_arithmetic_expr fm var_name arg_regs int_val_type out_nargs 
         get_oper_expr int_arith_depth);
    if n > 0 then main_loop (n-1) else () in
  main_loop ((Int64.to_int in_nargs) - 1)

(* adds extra conditions on the input variables and associated 
   adaptor variables; this function is called in exec_fuzzloop *)
let rec arithmetic_int_extra_conditions fm out_nargs n = 
  let var_name = String.make 1 (Char.chr ((Char.code 'a') + n)) in
  let var = fm#get_fresh_symbolic var_name 
              (if int_val_type = V.REG_32 then 32 else 64) in
  (* restrict a value to be in a certain range; the lower and upper bounds 
     are inclusive *)
  let restrict_range v lower upper =
    V.BinOp(V.BITAND, 
            V.UnOp(
              V.NOT, 
              V.BinOp(V.SLT, v, V.Constant(V.Int(int_val_type, lower)))),
            V.BinOp(V.SLE, v, V.Constant(V.Int(int_val_type, upper)))) in
  (* restrict a value to be one of a specified list
     NOTE: for implementation reasons, we always add 0L to the list of 
           possible values *)
  let rec specify_vals v vals =
    match vals with
    | [] -> failwith "Bad value list for arithmetic adaptor"
    | v'::[] -> 
        V.BinOp(V.BITOR, 
                V.BinOp(V.EQ, v, V.Constant(V.Int(int_val_type, v'))),
                V.BinOp(V.EQ, v, V.Constant(V.Int(int_val_type, 0L))))
    | v'::t -> 
        V.BinOp(V.BITOR, 
                V.BinOp(V.EQ, v, V.Constant(V.Int(int_val_type, v'))),
                specify_vals v t) in
  (* restrict the value of a constant node to be in a specified range or 
     one of a specified value *)
  let restrict_const_node node_type node_val =
    match int_restrict_constant_range with
    | None -> 
        (match int_restrict_constant_list with
         | None -> V.exp_true
         | Some l -> 
             V.BinOp(
               V.BITOR,
               V.BinOp(V.NEQ, node_type, V.Constant(V.Int(V.REG_8, 0L))),
               specify_vals node_val l))
    | Some (lower, upper) ->
        V.BinOp(
          V.BITOR,
          V.BinOp(V.NEQ, node_type, V.Constant(V.Int(V.REG_8, 0L))),
          restrict_range node_val lower upper) in
  (* restrict the value of the input variable to be in a specified range 
     or one of a specified value *)
  let restrict_input input =
    match int_restrict_counterexample_range with
    | None -> 
        (match int_restrict_counterexample_list with
         | None -> V.exp_true
         | Some l -> specify_vals input l)
    | Some (lower, upper) -> restrict_range input lower upper in
  (* restrict the generated counterexamples *)
  let _ = synth_extra_conditions := 
            (restrict_input var) ::
            !synth_extra_conditions in
  add_arithmetic_tree_conditions fm var_name int_val_type out_nargs 
    restrict_const_node int_binops int_unops int_arith_depth;
  if n > 0 then arithmetic_int_extra_conditions fm out_nargs (n-1) else ()

(*** floating point arithmetic adaptor ***)

(* use the variables below to specify the kinds of adaptors and 
   counterexamples that can be synthesized; these variables will be used
   in arithmetic_float_adaptor and arithmetic_float_extra_conditions *)
(* tree depth *)
let float_arith_depth = 2
(* 32 or 64-bit values (float vs. double) *)
let float_val_type = V.REG_32
(* binary and unary operators; all possible operators:
   V.FPLUS; V.FMINUS; V.FTIMES; V.FDIVIDE; V.FNEG *)
let float_binops = [V.FPLUS; V.FMINUS; V.FTIMES]
let float_unops = [V.FNEG]
let float_rm = Vine_util.ROUND_NEAREST
(* restrict the constant values generated; float_restrict_constant_range
   should be 'None' or 'Some (lower, upper)' and float_restrict_constant_list 
   should be 'None' or 'Some [v1; v2; ...; vn]'; these may not actually
   be useful because e.g. the restricting range has to be very narrow to 
   noticeably reduce the search space *)
let float_restrict_constant_range = None
let float_restrict_constant_list = None
(* restrict the counterexamples generated; float_restrict_counterexample_range
   should be 'None' or 'Some (lower, upper)' and float_restrict_counterexample_list 
   should be 'None' or 'Some [v1; v2; ...; vn]'; same note as above: these may
   not be very useful *)
let float_restrict_counterexample_range = None
let float_restrict_counterexample_list = None

(* creates symbolic variables representing the adaptor function and encodes
   the rules for applying the adaptor function; this function is called in 
   exec_runloop *)
let arithmetic_float_adaptor fm out_nargs in_nargs =
  (* argument registers -- assumes SSE floating point *)
  let arg_regs = [R_YMM0_0; R_YMM1_0; R_YMM2_0; R_YMM3_0] in
  (* operators that require special handling *)
  let special_type = [V.FDIVIDE] in
  (* builds an expression that applies some operator to apply to l and r *)
  let get_oper_expr node_value l r =
    let rec unop_expr ops n =
      match ops with 
      | [] -> failwith "Missing operators for the arithmetic adaptor"
      | unop::[] -> V.FUnOp(unop, float_rm, l)
      | unop::tl -> 
          get_ite_expr node_value V.EQ float_val_type n
            (V.FUnOp(unop, float_rm, l))
            (unop_expr tl (Int64.add n 1L)) in
    let rec binop_expr ops n =
      match ops with 
      | [] -> unop_expr float_unops n
      | binop::tl -> 
          let expr = 
            if (List.mem binop special_type)
            then (* accounts for div. by zero *)
              V.FBinOp(
                binop, float_rm, l, 
                get_ite_expr r V.EQ V.REG_32 0L 
                  (V.Constant(V.Int(V.REG_32, 1L))) r) 
            else (* standard binary operator application *)
              V.FBinOp(binop, float_rm, l, r) in
          if (tl = [] && float_unops = [])
          then expr
          else get_ite_expr node_value V.EQ float_val_type n
                 expr (binop_expr tl (Int64.add n 1L)) in
    binop_expr float_binops 0L in
  let rec main_loop n =
    let var_name = String.make 1 (Char.chr ((Char.code 'a') + n)) in
    fm#set_reg_symbolic (List.nth arg_regs n)
      (get_arithmetic_expr fm var_name arg_regs float_val_type out_nargs 
         get_oper_expr float_arith_depth);
    if n > 0 then main_loop (n-1) else () in
  main_loop ((Int64.to_int in_nargs) - 1)
  
(* adds extra conditions on the input variables and associated adaptor 
   variables; this function is called in exec_fuzzloop; note that we use 
   integer comparisons (instead of floating point comparisons) in some of 
   our extra conditions, we can do this because the symbolic variables 
   just correspond to (kind of) typeless sequences of bits  *)
let rec arithmetic_float_extra_conditions fm out_nargs n = 
  let var_name = String.make 1 (Char.chr ((Char.code 'a') + n)) in
  let var = fm#get_fresh_symbolic var_name 
              (if float_val_type = V.REG_32 then 32 else 64) in
  let get_bits v = 
    if float_val_type = V.REG_32
    then Int64.of_int32 (Int32.bits_of_float v)
    else Int64.bits_of_float v in
  (* restrict a value to be in a certain range; the lower and upper bounds 
     are inclusive *)
  let restrict_range v lower upper =
    V.BinOp(V.BITAND, 
            V.UnOp(
              V.NOT, 
              V.FBinOp(V.FLT, float_rm, v, 
                       V.Constant(V.Int(float_val_type, get_bits lower)))),
            V.FBinOp(V.FLE, float_rm, v, 
                     V.Constant(V.Int(float_val_type, get_bits upper)))) in
  (* restrict a value to be one of a specified list
     NOTE: for implementation reasons, we always add 0L to the list of 
           possible values *)
  let rec specify_vals v vals =
    match vals with
    | [] -> failwith "Bad value list for arithmetic adaptor"
    | v'::[] -> 
        V.BinOp(V.BITOR, 
                V.BinOp(V.EQ, v, V.Constant(V.Int(float_val_type, get_bits v'))),
                V.BinOp(V.EQ, v, V.Constant(V.Int(float_val_type, 0L))))
    | v'::t -> 
        V.BinOp(V.BITOR, 
                V.BinOp(V.EQ, v, V.Constant(V.Int(float_val_type, get_bits v'))),
                specify_vals v t) in
  (* restrict the value of a constant node to be in a specified range or 
     one of a specified value *)
  let restrict_const_node node_type node_val =
    match float_restrict_constant_range with
    | None -> 
        (match float_restrict_constant_list with
         | None -> V.exp_true
         | Some l -> 
             V.BinOp(
               V.BITOR,
               V.BinOp(V.NEQ, node_type, V.Constant(V.Int(V.REG_8, 0L))),
               specify_vals node_val l))
    | Some (lower, upper) ->
        V.BinOp(
          V.BITOR,
          V.BinOp(V.NEQ, node_type, V.Constant(V.Int(V.REG_8, 0L))),
          restrict_range node_val lower upper) in
  (* restrict the value of the input variable to be in a specified range 
     or one of a specified value *)
  let restrict_input input =
    match float_restrict_counterexample_range with
    | None -> 
        (match float_restrict_counterexample_list with
         | None -> V.exp_true
         | Some l -> specify_vals input l)
    | Some (lower, upper) -> restrict_range input lower upper in
  (* restrict the generated counterexamples *)
  let _ = synth_extra_conditions := 
            (restrict_input var) ::
            !synth_extra_conditions in
  add_arithmetic_tree_conditions fm var_name float_val_type out_nargs 
    restrict_const_node float_binops float_unops float_arith_depth;
  if n > 0 then arithmetic_float_extra_conditions fm out_nargs (n-1) else ()  
  


