(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
open Llair2TextualType

let builtin_qual_proc_name name : Textual.QualifiedProcName.t =
  { enclosing_class= Enclosing (Textual.TypeName.of_string "$builtins")
  ; name= Textual.ProcName.of_string name }


let reg_to_var_name reg = Textual.VarName.of_string (Reg.name reg)

let reg_to_id reg = Textual.Ident.of_int (Reg.id reg)

let reg_to_annot_typ reg = to_annotated_textual_typ (Reg.typ reg)

let to_textual_loc {Loc.line; col} = Textual.Location.Known {line; col}

let translate_llair_globals globals =
  let to_textual_global global =
    let global = global.GlobalDefn.name in
    let global_name = Global.name global in
    let name = Textual.VarName.of_string global_name in
    let typ = to_textual_typ (Global.typ global) in
    Textual.Global.{name; typ; attributes= []}
  in
  let globals = StdUtils.iarray_to_list globals in
  List.map ~f:to_textual_global globals


let to_qualified_proc_name ?loc func_name =
  let func_name = FuncName.name func_name in
  let loc = Option.map ~f:to_textual_loc loc in
  Textual.QualifiedProcName.
    {enclosing_class= TopLevel; name= Textual.ProcName.of_string ?loc func_name}


let to_result_type func_name =
  let typ = FuncName.typ func_name in
  to_annotated_textual_typ typ


let to_formals func =
  let to_textual_formal formal = reg_to_var_name formal in
  let to_textual_formal_type formal = reg_to_annot_typ formal in
  let llair_formals = StdUtils.iarray_to_list func.Llair.formals in
  let formals = List.map ~f:to_textual_formal llair_formals in
  let formals_types = List.map ~f:to_textual_formal_type llair_formals in
  (formals, formals_types)


let to_locals func =
  let to_textual_local local =
    let local_name = reg_to_var_name local in
    let typ = reg_to_annot_typ local in
    (local_name, typ)
  in
  let locals = Reg.Set.to_list func.Llair.locals in
  List.map ~f:to_textual_local locals


let block_to_node_name block =
  let name = block.Llair.lbl in
  Textual.NodeName.of_string name


(* TODO: translate expressions *)
let to_textual_exp _exp = assert false

let to_textual_bool_exp exp = Textual.BoolExp.Exp (to_textual_exp exp)

let to_textual_call (call : 'a Llair.call) =
  let loc = to_textual_loc call.loc in
  let proc, kind, exp_opt =
    match call.callee with
    | Direct {func} ->
        (to_qualified_proc_name func.Llair.name, Textual.Exp.NonVirtual, None)
    | Indirect {ptr} ->
        let proc = builtin_qual_proc_name "llvm_dynamic_call" in
        (proc, Textual.Exp.NonVirtual, Some (to_textual_exp ptr))
    | _ ->
        assert false (* TODO translate Intrinsic *)
  in
  let id = Option.map call.areturn ~f:(fun reg -> reg_to_id reg) in
  let args = List.map ~f:to_textual_exp (StdUtils.iarray_to_list call.Llair.actuals) in
  let args = List.append (Option.to_list exp_opt) args in
  Textual.Instr.Let {id; exp= Call {proc; args; kind}; loc}


let to_textual_jump jump =
  let label = block_to_node_name jump.dst in
  let node_call = Textual.Terminator.{label; ssa_args= []} in
  Textual.Terminator.Jump [node_call]


let to_terminator term =
  match term with
  | Call call ->
      to_textual_jump call.return
  | Return {exp= Some exp} ->
      Textual.Terminator.Ret (to_textual_exp exp)
  | Return {exp= None} ->
      Textual.Terminator.Ret (Textual.Exp.Typ Textual.Typ.Void)
  | Throw {exc} ->
      Textual.Terminator.Throw (to_textual_exp exc)
  | Switch {key; tbl; els} -> (
    match StdUtils.iarray_to_list tbl with
    | [(exp, zero_jump)] when Exp.equal exp Exp.false_ ->
        let bexp = to_textual_bool_exp key in
        let else_ = to_textual_jump zero_jump in
        let then_ = to_textual_jump els in
        Textual.Terminator.If {bexp; then_; else_}
    | _ ->
        Textual.Terminator.Unreachable (* TODO translate Switch *) )
  | Iswitch _ | Abort _ | Unreachable ->
      Textual.Terminator.Unreachable


let cmnd_to_instrs block =
  let to_instr inst =
    (* TODO translate instructions *)
    match inst with
    | Move _
    | Load _
    | Store _
    | AtomicRMW _
    | AtomicCmpXchg _
    | Alloc _
    | Free _
    | Nondet _
    | Builtin _ ->
        assert false
  in
  let call_instr_opt =
    match block.term with Call call -> Some (to_textual_call call) | _ -> None
  in
  let instrs = List.map ~f:to_instr (StdUtils.iarray_to_list block.cmnd) in
  List.append instrs (Option.to_list call_instr_opt)


(* TODO still various parts of the node left to be translated *)
let block_to_node (block : Llair.block) =
  Textual.Node.
    { label= block_to_node_name block
    ; ssa_parameters= []
    ; exn_succs= []
    ; last= to_terminator block.term
    ; instrs= cmnd_to_instrs block
    ; last_loc= Textual.Location.Unknown
    ; label_loc= Textual.Location.Unknown }


let func_to_nodes func =
  let node = block_to_node func.Llair.entry in
  (* TODO translate all nodes *)
  [node]


let translate_llair_functions functions =
  let function_to_formal proc_descs (func_name, func) =
    let formals_, formals_types = to_formals func in
    let locals = to_locals func in
    let qualified_name = to_qualified_proc_name func_name ~loc:func.Llair.loc in
    let result_type = to_result_type func_name in
    let procdecl =
      Textual.ProcDecl.
        {qualified_name; result_type; attributes= []; formals_types= Some formals_types}
    in
    let nodes = func_to_nodes func in
    Textual.ProcDesc.
      { params= formals_
      ; locals
      ; procdecl
      ; start= block_to_node_name func.Llair.entry
      ; nodes
      ; exit_loc= Unknown (* TODO: get this location *) }
    :: proc_descs
  in
  let values = FuncName.Map.to_list functions in
  List.fold values ~f:function_to_formal ~init:[]


let translate sourcefile (llair_program : Llair.Program.t) : Textual.Module.t =
  let globals = translate_llair_globals llair_program.Llair.globals in
  (* We'll build the procdesc partially until we have all the pieces required in Textual
     and can add them to the list of declarations *)
  let proc_descs = translate_llair_functions llair_program.Llair.functions in
  let proc_decls =
    List.map ~f:(fun Textual.ProcDesc.{procdecl} -> Textual.Module.Procdecl procdecl) proc_descs
  in
  let proc_desc_declarations =
    List.map ~f:(fun proc_desc -> Textual.Module.Proc proc_desc) proc_descs
  in
  let globals = List.map ~f:(fun global -> Textual.Module.Global global) globals in
  let structs =
    List.map
      ~f:(fun (_, struct_) -> Textual.Module.Struct struct_)
      (Textual.TypeName.Map.bindings !Llair2TextualType.structMap)
  in
  let decls = List.append proc_decls globals in
  let decls = List.append decls proc_desc_declarations in
  let decls = List.append decls structs in
  Textual.Module.{attrs= []; decls; sourcefile}
