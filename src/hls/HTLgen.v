(* 
 * Vericert: Verified high-level synthesis.
 * Copyright (C) 2020 Yann Herklotz <yann@yannherklotz.com>
 *               2020 James Pollard <j@mes.dev>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *)

Require Import Coq.micromega.Lia.

Require Import compcert.lib.Maps.
Require compcert.common.Errors.
Require compcert.common.Globalenvs.
Require compcert.lib.Integers.
Require Import compcert.common.AST.
Require Import compcert.backend.RTL.

Require Import vericert.common.Statemonad.
Require Import vericert.common.Vericertlib.
Require Import vericert.common.Maps.
Require Import vericert.hls.AssocMap.
Require Import vericert.hls.HTL.
Require Import vericert.hls.ValueInt.
Require Import vericert.hls.Verilog.

Hint Resolve AssocMap.gempty : htlh.
Hint Resolve AssocMap.gso : htlh.
Hint Resolve AssocMap.gss : htlh.
Hint Resolve Ple_refl : htlh.
Hint Resolve Ple_succ : htlh.

Record state: Type := mkstate {
  st_st : reg;
  st_freshreg: reg;
  st_freshstate: node;
  st_scldecls: AssocMap.t (option io * scl_decl);
  st_arrdecls: AssocMap.t (option io * arr_decl);
  st_externctrl : AssocMap.t (ident * controlsignal);
  st_datapath: datapath;
  st_controllogic: controllogic;
}.

Definition init_state (st : reg) : state :=
  mkstate st
          1%positive
          1%positive
          (AssocMap.empty (option io * scl_decl))
          (AssocMap.empty (option io * arr_decl))
          (AssocMap.empty (ident * controlsignal))
          (AssocMap.empty datapath_stmnt)
          (AssocMap.empty control_stmnt).

Module HTLState <: State.

  Definition st := state.

  Inductive st_incr: state -> state -> Prop :=
    state_incr_intro:
      forall (s1 s2: state),
        st_st s1 = st_st s2 ->
        Ple s1.(st_freshreg) s2.(st_freshreg) ->
        Ple s1.(st_freshstate) s2.(st_freshstate) ->
        (forall n,
            s1.(st_datapath)!n = None \/ s2.(st_datapath)!n = s1.(st_datapath)!n) ->
        (forall n,
            s1.(st_controllogic)!n = None
            \/ s2.(st_controllogic)!n = s1.(st_controllogic)!n) ->
        st_incr s1 s2.
  Hint Constructors st_incr : htlh.

  Definition st_prop := st_incr.
  Hint Unfold st_prop : htlh.

  Lemma st_refl : forall s, st_prop s s. Proof. auto with htlh. Qed.

  Lemma st_trans :
    forall s1 s2 s3, st_prop s1 s2 -> st_prop s2 s3 -> st_prop s1 s3.
  Proof.
    intros. inv H. inv H0. apply state_incr_intro; eauto using Ple_trans; intros; try congruence.
    - destruct H4 with n; destruct H8 with n; intuition congruence.
    - destruct H5 with n; destruct H9 with n; intuition congruence.
  Qed.

End HTLState.
Export HTLState.

Module HTLMonad := Statemonad(HTLState).
Export HTLMonad.

Module HTLMonadExtra := Monad.MonadExtra(HTLMonad).
Import HTLMonadExtra.
Export MonadNotation.

Definition bop (op : binop) (r1 r2 : reg) : expr :=
  Vbinop op (Vvar r1) (Vvar r2).

Definition boplit (op : binop) (r : reg) (l : Integers.int) : expr :=
  Vbinop op (Vvar r) (Vlit (intToValue l)).

Definition boplitz (op: binop) (r: reg) (l: Z) : expr :=
  Vbinop op (Vvar r) (Vlit (ZToValue l)).

Definition state_goto (st : reg) (n : node) : control_stmnt :=
  Vnonblock (Vvar st) (Vlit (posToValue n)).

Definition state_cond (st : reg) (c : expr) (n1 n2 : node) : control_stmnt :=
  Vnonblock (Vvar st) (Vternary c (posToExpr n1) (posToExpr n2)).

Definition state_wait (st wait_reg : reg) (n : node) : control_stmnt :=
  Vnonblock (Vvar st) (Vternary (boplitz Veq wait_reg 1) (posToExpr n) (Vvar st)).

Definition nonblock (dst : reg) (e : expr) := (Vnonblock (Vvar dst) e).

Definition block (dst : reg) (e : expr) := (Vblock (Vvar dst) e).

Definition check_empty_node_datapath:
  forall (s: state) (n: node), { s.(st_datapath)!n = None } + { True }.
Proof.
  intros. case (s.(st_datapath)!n); tauto.
Defined.

Definition check_empty_node_controllogic:
  forall (s: state) (n: node), { s.(st_controllogic)!n = None } + { True }.
Proof.
  intros. case (s.(st_controllogic)!n); tauto.
Defined.

Program Definition declare_reg (i : option io) (r : reg) (sz : nat) : mon unit :=
  fun s => OK tt (mkstate
                (st_st s)
                (st_freshreg s)
                (st_freshstate s)
                (AssocMap.set r (i, VScalar sz) s.(st_scldecls))
                (st_arrdecls s)
                (st_externctrl s)
                (st_datapath s)
                (st_controllogic s)) _.
Next Obligation. auto with htlh. Qed.

Program Definition create_reg (i : option io) (sz : nat) : mon reg :=
  fun s => let r := s.(st_freshreg) in
           OK r (mkstate
                   s.(st_st)
                   (Pos.succ r)
                   (st_freshstate s)
                   (AssocMap.set s.(st_freshreg) (i, VScalar sz) s.(st_scldecls))
                   (st_arrdecls s)
                   (st_externctrl s)
                   (st_datapath s)
                   (st_controllogic s)) _.
Next Obligation. constructor; simpl; auto with htlh. Qed.

Program Definition map_externctrl (othermod : ident) (ctrl : controlsignal) : mon reg :=
  do r <- create_reg None (controlsignal_sz ctrl);
  fun s => let r := s.(st_freshreg) in
           OK r (mkstate
                   s.(st_st)
                   (Pos.succ r)
                   (st_freshstate s)
                   (st_scldecls s)
                   (st_arrdecls s)
                   (AssocMap.set r (othermod, ctrl) (st_externctrl s))
                   (st_datapath s)
                   (st_controllogic s)) _.
Next Obligation. constructor; simpl; auto with htlh. Qed.

Program Definition create_state : mon node :=
  fun s => let r := s.(st_freshstate) in
           OK r (mkstate
                   s.(st_st)
                   (st_freshreg s)
                   (Pos.succ (st_freshstate s))
                   (st_scldecls s)
                   (st_arrdecls s)
                   (st_externctrl s)
                   (st_datapath s)
                   (st_controllogic s)) _.
Next Obligation. constructor; simpl; eauto with htlh. Qed.

Program Definition add_instr (n : node) (n' : node) (st : datapath_stmnt) : mon unit :=
  fun s =>
    match check_empty_node_datapath s n, check_empty_node_controllogic s n with
    | left STM, left TRANS =>
      OK tt (mkstate
               s.(st_st)
               s.(st_freshreg)
               (st_freshstate s)
               s.(st_scldecls)
               s.(st_arrdecls)
               (st_externctrl s)
               (AssocMap.set n st s.(st_datapath))
               (AssocMap.set n (state_goto s.(st_st) n') s.(st_controllogic))) _
    | _, _ => Error (Errors.msg "HTL.add_instr")
    end.
Next Obligation.
  constructor; intros;
    try (simpl; destruct (peq n n0); subst);
    auto with htlh.
  Qed.

Program Definition add_instr_wait (wait_reg : reg) (n : node) (n' : node) (st : datapath_stmnt) : mon unit :=
  fun s =>
    match check_empty_node_datapath s n, check_empty_node_controllogic s n with
    | left STM, left TRANS =>
      OK tt (mkstate
               s.(st_st)
               s.(st_freshreg)
               (st_freshstate s)
               s.(st_scldecls)
               s.(st_arrdecls)
               (st_externctrl s)
               (AssocMap.set n st s.(st_datapath))
               (AssocMap.set n (state_wait (st_st s) wait_reg n') s.(st_controllogic))) _
    | _, _ => Error (Errors.msg "HTL.add_instr_wait")
    end.
Next Obligation.
  constructor; intros;
    try (simpl; destruct (peq n n0); subst);
    auto with htlh.
Qed.

Program Definition add_instr_skip (n : node) (st : datapath_stmnt) : mon unit :=
  fun s =>
    match check_empty_node_datapath s n, check_empty_node_controllogic s n with
    | left STM, left TRANS =>
      OK tt (mkstate
               s.(st_st)
               s.(st_freshreg)
               (st_freshstate s)
               s.(st_scldecls)
               s.(st_arrdecls)
               (st_externctrl s)
               (AssocMap.set n st s.(st_datapath))
               (AssocMap.set n Vskip s.(st_controllogic)))
         _
    | _, _ => Error (Errors.msg "HTL.add_instr")
    end.
Next Obligation.
  constructor; intros;
    try (simpl; destruct (peq n n0); subst);
    auto with htlh.
Qed.

Program Definition add_node_skip (n : node) (st : control_stmnt) : mon unit :=
  fun s =>
    match check_empty_node_datapath s n, check_empty_node_controllogic s n with
    | left STM, left TRANS =>
      OK tt (mkstate
               s.(st_st)
               s.(st_freshreg)
               (st_freshstate s)
               s.(st_scldecls)
               s.(st_arrdecls)
               (st_externctrl s)
               (AssocMap.set n Vskip s.(st_datapath))
               (AssocMap.set n st s.(st_controllogic)))
         _
    | _, _ => Error (Errors.msg "HTL.add_instr")
    end.
Next Obligation.
  constructor; intros;
    try (simpl; destruct (peq n n0); subst);
    auto with htlh.
Qed.

Definition translate_comparison (c : Integers.comparison) (args : list reg) : mon expr :=
  match c, args with
  | Integers.Ceq, r1::r2::nil => ret (bop Veq r1 r2)
  | Integers.Cne, r1::r2::nil => ret (bop Vne r1 r2)
  | Integers.Clt, r1::r2::nil => ret (bop Vlt r1 r2)
  | Integers.Cgt, r1::r2::nil => ret (bop Vgt r1 r2)
  | Integers.Cle, r1::r2::nil => ret (bop Vle r1 r2)
  | Integers.Cge, r1::r2::nil => ret (bop Vge r1 r2)
  | _, _ => error (Errors.msg "Htlgen: comparison instruction not implemented: other")
  end.

Definition translate_comparison_imm (c : Integers.comparison) (args : list reg) (i: Integers.int)
  : mon expr :=
  match c, args with
  | Integers.Ceq, r1::nil => ret (boplit Veq r1 i)
  | Integers.Cne, r1::nil => ret (boplit Vne r1 i)
  | Integers.Clt, r1::nil => ret (boplit Vlt r1 i)
  | Integers.Cgt, r1::nil => ret (boplit Vgt r1 i)
  | Integers.Cle, r1::nil => ret (boplit Vle r1 i)
  | Integers.Cge, r1::nil => ret (boplit Vge r1 i)
  | _, _ => error (Errors.msg "Htlgen: comparison_imm instruction not implemented: other")
  end.

Definition translate_comparisonu (c : Integers.comparison) (args : list reg) : mon expr :=
  match c, args with
  | Integers.Clt, r1::r2::nil => ret (bop Vltu r1 r2)
  | Integers.Cgt, r1::r2::nil => ret (bop Vgtu r1 r2)
  | Integers.Cle, r1::r2::nil => ret (bop Vleu r1 r2)
  | Integers.Cge, r1::r2::nil => ret (bop Vgeu r1 r2)
  | _, _ => error (Errors.msg "Htlgen: comparison instruction not implemented: other")
  end.

Definition translate_comparison_immu (c : Integers.comparison) (args : list reg) (i: Integers.int)
  : mon expr :=
  match c, args with
  | Integers.Clt, r1::nil => ret (boplit Vltu r1 i)
  | Integers.Cgt, r1::nil => ret (boplit Vgtu r1 i)
  | Integers.Cle, r1::nil => ret (boplit Vleu r1 i)
  | Integers.Cge, r1::nil => ret (boplit Vgeu r1 i)
  | _, _ => error (Errors.msg "Htlgen: comparison_imm instruction not implemented: other")
  end.

Definition translate_condition (c : Op.condition) (args : list reg) : mon expr :=
  match c, args with
  | Op.Ccomp c, _ => translate_comparison c args
  | Op.Ccompu c, _ => translate_comparisonu c args
  | Op.Ccompimm c i, _ => translate_comparison_imm c args i
  | Op.Ccompuimm c i, _ => translate_comparison_immu c args i
  | Op.Cmaskzero n, _ => error (Errors.msg "Htlgen: condition instruction not implemented: Cmaskzero")
  | Op.Cmasknotzero n, _ => error (Errors.msg "Htlgen: condition instruction not implemented: Cmasknotzero")
  | _, _ => error (Errors.msg "Htlgen: condition instruction not implemented: other")
  end.

Definition check_address_parameter_signed (p : Z) : bool :=
  Z.leb Integers.Ptrofs.min_signed p
  && Z.leb p Integers.Ptrofs.max_signed.

Definition check_address_parameter_unsigned (p : Z) : bool :=
  Z.leb p Integers.Ptrofs.max_unsigned.

Definition translate_eff_addressing (a: Op.addressing) (args: list reg) : mon expr :=
  match a, args with (* TODO: We should be more methodical here; what are the possibilities?*)
  | Op.Aindexed off, r1::nil =>
    if (check_address_parameter_signed off)
    then ret (boplitz Vadd r1 off)
    else error (Errors.msg "Veriloggen: translate_eff_addressing (Aindexed): address out of bounds")
  | Op.Ascaled scale offset, r1::nil =>
    if (check_address_parameter_signed scale) && (check_address_parameter_signed offset)
    then ret (Vbinop Vadd (boplitz Vmul r1 scale) (Vlit (ZToValue offset)))
    else error (Errors.msg "Veriloggen: translate_eff_addressing (Ascaled): address out of bounds")
  | Op.Aindexed2 offset, r1::r2::nil =>
    if (check_address_parameter_signed offset)
    then ret (Vbinop Vadd (bop Vadd r1 r2) (Vlit (ZToValue offset)))
    else error (Errors.msg "Veriloggen: translate_eff_addressing (Aindexed2): address out of bounds")
  | Op.Aindexed2scaled scale offset, r1::r2::nil => (* Typical for dynamic array addressing *)
    if (check_address_parameter_signed scale) && (check_address_parameter_signed offset)
    then ret (Vbinop Vadd (Vvar r1) (Vbinop Vadd (boplitz Vmul r2 scale) (Vlit (ZToValue offset))))
    else error (Errors.msg "Veriloggen: translate_eff_addressing (Aindexed2scaled): address out of bounds")
  | Op.Ainstack a, nil => (* We need to be sure that the base address is aligned *)
    let a := Integers.Ptrofs.unsigned a in
    if (check_address_parameter_unsigned a)
    then ret (Vlit (ZToValue a))
    else error (Errors.msg "Veriloggen: translate_eff_addressing (Ainstack): address out of bounds")
  | _, _ => error (Errors.msg "Veriloggen: translate_eff_addressing unsuported addressing")
  end.

(** Translate an instruction to a statement. FIX mulhs mulhu *)
Definition translate_instr (op : Op.operation) (args : list reg) : mon expr :=
  match op, args with
  | Op.Omove, r::nil => ret (Vvar r)
  | Op.Ointconst n, _ => ret (Vlit (intToValue n))
  | Op.Oneg, r::nil => ret (Vunop Vneg (Vvar r))
  | Op.Osub, r1::r2::nil => ret (bop Vsub r1 r2)
  | Op.Omul, r1::r2::nil => ret (bop Vmul r1 r2)
  | Op.Omulimm n, r::nil => ret (boplit Vmul r n)
  | Op.Omulhs, r1::r2::nil => error (Errors.msg "Htlgen: Instruction not implemented: mulhs")
  | Op.Omulhu, r1::r2::nil => error (Errors.msg "Htlgen: Instruction not implemented: mulhu")
  | Op.Odiv, r1::r2::nil => ret (bop Vdiv r1 r2)
  | Op.Odivu, r1::r2::nil => ret (bop Vdivu r1 r2)
  | Op.Omod, r1::r2::nil => ret (bop Vmod r1 r2)
  | Op.Omodu, r1::r2::nil => ret (bop Vmodu r1 r2)
  | Op.Oand, r1::r2::nil => ret (bop Vand r1 r2)
  | Op.Oandimm n, r::nil => ret (boplit Vand r n)
  | Op.Oor, r1::r2::nil => ret (bop Vor r1 r2)
  | Op.Oorimm n, r::nil => ret (boplit Vor r n)
  | Op.Oxor, r1::r2::nil => ret (bop Vxor r1 r2)
  | Op.Oxorimm n, r::nil => ret (boplit Vxor r n)
  | Op.Onot, r::nil => ret (Vunop Vnot (Vvar r))
  | Op.Oshl, r1::r2::nil => ret (bop Vshl r1 r2)
  | Op.Oshlimm n, r::nil => ret (boplit Vshl r n)
  | Op.Oshr, r1::r2::nil => ret (bop Vshr r1 r2)
  | Op.Oshrimm n, r::nil => ret (boplit Vshr r n)
  | Op.Oshrximm n, r::nil => ret (Vternary (Vbinop Vlt (Vvar r) (Vlit (ZToValue 0)))
                                         (Vunop Vneg (Vbinop Vshru (Vunop Vneg (Vvar r)) (Vlit n)))
                                         (Vbinop Vshru (Vvar r) (Vlit n)))
  (*ret (Vbinop Vdiv (Vvar r)
    (Vbinop Vshl (Vlit (ZToValue 1))
    (Vlit (intToValue n))))*)
  | Op.Oshru, r1::r2::nil => ret (bop Vshru r1 r2)
  | Op.Oshruimm n, r::nil => ret (boplit Vshru r n)
  | Op.Ororimm n, r::nil => error (Errors.msg "Htlgen: Instruction not implemented: Ororimm")
  (*ret (Vbinop Vor (boplit Vshru r (Integers.Int.modu n (Integers.Int.repr 32)))
                                        (boplit Vshl r (Integers.Int.sub (Integers.Int.repr 32) (Integers.Int.modu n (Integers.Int.repr 32)))))*)
  | Op.Oshldimm n, r::nil => ret (Vbinop Vor (boplit Vshl r n) (boplit Vshr r (Integers.Int.sub (Integers.Int.repr 32) n)))
  | Op.Ocmp c, _ => translate_condition c args
  | Op.Osel c AST.Tint, r1::r2::rl =>
    do tc <- translate_condition c rl;
    ret (Vternary tc (Vvar r1) (Vvar r2))
  | Op.Olea a, _ => translate_eff_addressing a args
  | _, _ => error (Errors.msg "Htlgen: Instruction not implemented: other")
  end.

Program Definition add_branch_instr (e: expr) (n n1 n2: node) : mon unit :=
  fun s =>
    match check_empty_node_datapath s n, check_empty_node_controllogic s n with
    | left NSTM, left NTRANS =>
      OK tt (mkstate
               s.(st_st)
                (st_freshreg s)
                (st_freshstate s)
                s.(st_scldecls)
                s.(st_arrdecls)
                (st_externctrl s)
                (AssocMap.set n Vskip (st_datapath s))
                (AssocMap.set n (state_cond s.(st_st) e n1 n2) (st_controllogic s)))
         _
    | _, _ => Error (Errors.msg "Htlgen: add_branch_instr")
    end.
Next Obligation.
  intros. apply state_incr_intro; simpl;
            try (intros; destruct (peq n0 n); subst);
            auto with htlh.
Qed.

Definition translate_arr_access (mem : AST.memory_chunk) (addr : Op.addressing)
           (args : list reg) (stack : reg) : mon expr :=
  match mem, addr, args with (* TODO: We should be more methodical here; what are the possibilities?*)
  | Mint32, Op.Aindexed off, r1::nil =>
    if (check_address_parameter_signed off)
    then ret (Vvari stack (Vbinop Vdivu (boplitz Vadd r1 off) (Vlit (ZToValue 4))))
    else error (Errors.msg "HTLgen: translate_arr_access address out of bounds")
  | Mint32, Op.Aindexed2scaled scale offset, r1::r2::nil => (* Typical for dynamic array addressing *)
    if (check_address_parameter_signed scale) && (check_address_parameter_signed offset)
    then ret (Vvari stack
                    (Vbinop Vdivu
                            (Vbinop Vadd (boplitz Vadd r1 offset) (boplitz Vmul r2 scale))
                            (Vlit (ZToValue 4))))
    else error (Errors.msg "HTLgen: translate_arr_access address out of bounds")
  | Mint32, Op.Ainstack a, nil => (* We need to be sure that the base address is aligned *)
    let a := Integers.Ptrofs.unsigned a in
    if (check_address_parameter_unsigned a)
    then ret (Vvari stack (Vlit (ZToValue (a / 4))))
    else error (Errors.msg "HTLgen: eff_addressing out of bounds stack offset")
  | _, _, _ => error (Errors.msg "HTLgen: translate_arr_access unsuported addressing")
  end.

Fixpoint enumerate (i : nat) (ns : list node) {struct ns} : list (nat * node) :=
  match ns with
  | n :: ns' => (i, n) :: enumerate (i+1) ns'
  | nil => nil
  end.

Definition tbl_to_case_expr (st : reg) (ns : list node) : list (expr * stmnt) :=
  List.map (fun a => match a with
                    (i, n) => (Vlit (natToValue i), Vnonblock (Vvar st) (Vlit (posToValue n)))
                  end)
           (enumerate 0 ns).

(** [mk_fork] creates a datapath statement which sets up the execution of a *)
Definition mk_fork (m : ident) (args : list reg) : mon datapath_stmnt :=
  do reset_reg <- map_externctrl m ctrl_reset;
  do param_assigns <- traverselist
                (fun (a: (nat * reg)) => let (idx, arg) := a in
                                    do param_reg <- map_externctrl m (ctrl_param idx);
                                    ret (Vnonblock (Vvar param_reg) (Vvar arg)))
                (enumerate 0 args);
  let reset_mod := Vnonblock (Vvar reset_reg) (posToLit 1) in
  let assign_params :=
      List.fold_left (fun (acc : stmnt) (s : stmnt) => Vseq acc s)
                     param_assigns Vskip in
  ret (Vseq reset_mod assign_params).

Definition mk_join (m : ident) (dst : reg) : mon datapath_stmnt :=
  do return_reg <- map_externctrl m ctrl_return;
  do reset_reg <- map_externctrl m ctrl_reset;
  let set_result := Vnonblock (Vvar dst) (Vvar return_reg) in
  let stop_reset := Vnonblock (Vvar reset_reg) (Vlit (ZToValue 0)) in
  ret (Vseq stop_reset set_result).

Definition transf_instr (fin rtrn stack: reg) (ni: node * instruction) : mon unit :=
  match ni with
    (n, i) =>
    match i with
    | Inop n' =>
      if Z.leb (Z.pos n') Integers.Int.max_unsigned then
        add_instr n n' Vskip
      else error (Errors.msg "State is larger than 2^32.")
    | Iop op args dst n' =>
      if Z.leb (Z.pos n') Integers.Int.max_unsigned then
        do instr <- translate_instr op args;
        do _ <- declare_reg None dst 32;
        add_instr n n' (nonblock dst instr)
      else error (Errors.msg "State is larger than 2^32.")
    | Iload mem addr args dst n' =>
      if Z.leb (Z.pos n') Integers.Int.max_unsigned then
        do src <- translate_arr_access mem addr args stack;
        do _ <- declare_reg None dst 32;
        add_instr n n' (nonblock dst src)
      else error (Errors.msg "State is larger than 2^32.")
    | Istore mem addr args src n' =>
      if Z.leb (Z.pos n') Integers.Int.max_unsigned then
        do dst <- translate_arr_access mem addr args stack;
        add_instr n n' (Vnonblock dst (Vvar src)) (* TODO: Could juse use add_instr? reg exists. *)
      else error (Errors.msg "State is larger than 2^32.")
    | Icall sig (inl fn) args dst n' => error (Errors.msg "Indirect calls are not implemented.")
    | Icall sig (inr fn) args dst n' =>
      if Z.leb (Z.pos n') Integers.Int.max_unsigned then
        do _ <- declare_reg None dst 32;
        do join_state <- create_state;
        do fork_instr <- mk_fork fn args;
        do join_instr <- mk_join fn dst;
        do _ <- add_instr n join_state fork_instr;
        add_instr_wait fn join_state n' (join_instr)
      else error (Errors.msg "State is larger than 2^32.")
    | Itailcall _ _ _ => error (Errors.msg "Tailcalls are not implemented.")
    | Ibuiltin _ _ _ _ => error (Errors.msg "Builtin functions not implemented.")
    | Icond cond args n1 n2 =>
      if Z.leb (Z.pos n1) Integers.Int.max_unsigned && Z.leb (Z.pos n2) Integers.Int.max_unsigned then
        do e <- translate_condition cond args;
        add_branch_instr e n n1 n2
      else error (Errors.msg "State is larger than 2^32.")
    | Ijumptable r tbl =>
      (*do s <- get;
      add_node_skip n (Vcase (Vvar r) (tbl_to_case_expr s.(st_st) tbl) (Some Vskip))*)
      error (Errors.msg "Ijumptable: Case statement not supported.")
    | Ireturn r =>
      do idle_state <- create_state;
      let retval := match r with
                    | Some r' => Vvar r'
                    | None => Vlit (ZToValue 0%Z)
                    end in
      do _ <- add_instr n idle_state (Vseq (block fin (Vlit (ZToValue 1%Z))) (block rtrn retval));
      add_instr_skip idle_state (nonblock fin (Vlit (ZToValue 0%Z)))
    end
  end.

Program Definition create_arr (i : option io) (sz : nat) (ln : nat) : mon (reg * nat) :=
  fun s => let r := s.(st_freshreg) in
           OK (r, ln) (mkstate
                   s.(st_st)
                   (Pos.succ r)
                   (st_freshstate s)
                   s.(st_scldecls)
                   (AssocMap.set s.(st_freshreg) (i, VArray sz ln) s.(st_arrdecls))
                   (st_externctrl s)
                   (st_datapath s)
                   (st_controllogic s)) _.
Next Obligation. constructor; simpl; auto with htlh. Qed.

Definition stack_correct (sz : Z) : bool :=
  (0 <=? sz) && (sz <? Integers.Ptrofs.modulus) && (Z.modulo sz 4 =? 0).

Definition max_pc_map {A: Type} (m : Maps.PTree.t A) :=
  PTree.fold (fun m pc i => Pos.max m pc) m 1%positive.

Lemma max_pc_map_sound:
  forall A m pc i, m!pc = Some i -> Ple pc (@max_pc_map A m).
Proof.
  intros until i. unfold max_pc_function.
  apply PTree_Properties.fold_rec with (P := fun c m => c!pc = Some i -> Ple pc m).
  (* extensionality *)
  intros. apply H0. rewrite H; auto.
  (* base case *)
  rewrite PTree.gempty. congruence.
  (* inductive case *)
  intros. rewrite PTree.gsspec in H2. destruct (peq pc k).
  inv H2. xomega.
  apply Ple_trans with a. auto. xomega.
Qed.

Lemma max_pc_wf :
  forall T m, Z.pos (max_pc_map m) <= Integers.Int.max_unsigned ->
            @map_well_formed T m.
Proof.
  unfold map_well_formed. intros.
  exploit list_in_map_inv. eassumption. intros [x [A B]]. destruct x.
  apply Maps.PTree.elements_complete in B. apply max_pc_map_sound in B.
  unfold Ple in B. apply Pos2Z.pos_le_pos in B. subst.
  simplify. transitivity (Z.pos (max_pc_map m)); eauto.
Qed.

Definition transf_module (f: function) : mon HTL.module :=
  if stack_correct f.(fn_stacksize) then
    do fin <- create_reg (Some Voutput) 1;
    do rtrn <- create_reg (Some Voutput) 32;
    do (stack, stack_len) <- create_arr None 32 (Z.to_nat (f.(fn_stacksize) / 4));
    do _ <- collectlist (transf_instr fin rtrn stack) (Maps.PTree.elements f.(RTL.fn_code));
    do _ <- collectlist (fun r => declare_reg (Some Vinput) r 32) f.(RTL.fn_params);
    do start <- create_reg (Some Vinput) 1;
    do rst <- create_reg (Some Vinput) 1;
    do clk <- create_reg (Some Vinput) 1;
    do current_state <- get;
    match zle (Z.pos (max_pc_map current_state.(st_datapath))) Integers.Int.max_unsigned,
          zle (Z.pos (max_pc_map current_state.(st_controllogic))) Integers.Int.max_unsigned with
    | left LEDATA, left LECTRL =>
        ret (HTL.mkmodule
           f.(RTL.fn_params)
           current_state.(st_datapath)
           current_state.(st_controllogic)
           f.(fn_entrypoint)
           current_state.(st_st)
           stack
           stack_len
           fin
           rtrn
           start
           rst
           clk
           current_state.(st_scldecls)
           current_state.(st_arrdecls)
           current_state.(st_externctrl)
           (conj (max_pc_wf _ _ LECTRL) (max_pc_wf _ _ LEDATA)))
    | _, _ => error (Errors.msg "More than 2^32 states.")
    end
  else error (Errors.msg "Stack size misalignment.").

Definition max_state (f: function) : state :=
  let st := Pos.succ (max_reg_function f) in
  mkstate st
          (Pos.succ st)
          (Pos.succ (max_pc_function f))
          (AssocMap.set st (None, VScalar 32) (st_scldecls (init_state st)))
          (st_arrdecls (init_state st))
          (st_externctrl (init_state st))
          (st_datapath (init_state st))
          (st_controllogic (init_state st)).

Definition transl_module (f : function) : Errors.res HTL.module :=
  run_mon (max_state f) (transf_module f).

Definition transl_fundef := transf_partial_fundef transl_module.

(* Definition transl_program (p : RTL.program) := transform_partial_program transl_fundef p. *)

(*Definition transl_main_fundef f : Errors.res HTL.fundef :=
  match f with
  | Internal f => transl_fundef (Internal f)
  | External f => Errors.Error (Errors.msg "Could not find internal main function")
  end.

(** Translation of a whole program. *)

Definition transl_program (p: RTL.program) : Errors.res HTL.program :=
  transform_partial_program2 (fun i f => if Pos.eqb p.(AST.prog_main) i
                                         then transl_fundef f
                                         else transl_main_fundef f)
                             (fun i v => Errors.OK v) p.
*)

Record renumber_state: Type :=
  mk_renumber_state {
    renumber_freshreg : reg;
    renumber_regmap : PTree.t reg;
    renumber_clk : reg;
  }.

Module RenumberState <: State.
  Definition st := renumber_state.

  Definition st_prop (st1 st2 : st) := renumber_clk st1 = renumber_clk st2.

  Lemma st_refl : forall (s : st), st_prop s s.
  Proof. constructor. Qed.

  Lemma st_trans : forall s1 s2 s3, st_prop s1 s2 -> st_prop s2 s3 -> st_prop s1 s3.
  Proof. congruence. Qed.
End RenumberState.

Module RenumberMonad := Statemonad(RenumberState).
Module RenumberMonadExtra := Monad.MonadExtra(RenumberMonad).

Section RENUMBER.
  Import RenumberMonad.
  Import RenumberState.
  Import RenumberMonadExtra.
  Import MonadNotation.

  Program Definition map_reg (r: reg) : mon reg :=
    fun st => OK
         (renumber_freshreg st)
         (mk_renumber_state (Pos.succ (renumber_freshreg st))
                            (PTree.set r (renumber_freshreg st) (renumber_regmap st))
                            (renumber_clk st))
         _.
  Next Obligation. unfold st_prop; auto. Qed.

  Program Definition clear_mapping : mon unit :=
    fun st => OK
         tt
         (mk_renumber_state (renumber_freshreg st)
                            (PTree.empty reg)
                            (renumber_clk st))
         _.
  Next Obligation. unfold st_prop; auto. Qed.

  Definition renumber_reg (r : reg) : mon reg :=
    do st <- get;
    match PTree.get r (renumber_regmap st) with
    | Some reg' => ret reg'
    | None => map_reg r
    end.

  Definition get_clk : mon reg := do st <- get; ret (renumber_clk st).

  Fixpoint renumber_expr (expr : Verilog.expr) :=
    match expr with
    | Vlit val => ret (Vlit val)
    | Vvar reg =>
      do reg' <- renumber_reg reg;
      ret (Vvar reg')
    | Vvari reg e =>
      do reg' <- renumber_reg reg;
      do e' <- renumber_expr e;
      ret (Vvari reg' e')
    | Vinputvar reg =>
      do reg' <- renumber_reg reg;
      ret (Vvar reg')
    | Vbinop op e1 e2 =>
      do e1' <- renumber_expr e1;
      do e2' <- renumber_expr e2;
      ret (Vbinop op e1' e2')
    | Vunop op e =>
      do e' <- renumber_expr e;
      ret (Vunop op e')
    | Vternary e1 e2 e3 =>
      do e1' <- renumber_expr e1;
      do e2' <- renumber_expr e2;
      do e3' <- renumber_expr e3;
      ret (Vternary e1' e2' e3')
    | Vrange r e1 e2 =>
      do e1' <- renumber_expr e1;
      do e2' <- renumber_expr e2;
      do r' <- renumber_reg r;
      ret (Vrange r e1' e2')
    end.

  Fixpoint renumber_stmnt (stmnt : Verilog.stmnt) :=
    match stmnt with
    | Vskip => ret Vskip
    | Vseq s1 s2 =>
      do s1' <- renumber_stmnt s1;
      do s2' <- renumber_stmnt s2;
      ret (Vseq s1' s2')
    | Vcond e s1 s2 =>
      do e' <- renumber_expr e;
      do s1' <- renumber_stmnt s1;
      do s2' <- renumber_stmnt s2;
      ret (Vcond e' s1' s2')
    | Vcase e cs def =>
      do e' <- renumber_expr e;
      do cs' <- sequence (map
                       (fun (c : (Verilog.expr * Verilog.stmnt)) =>
                      let (c_expr, c_stmnt) := c in
                      do expr' <- renumber_expr c_expr;
                      do stmnt' <- renumber_stmnt c_stmnt;
                      ret (expr', stmnt')) cs);
      do def' <- match def with
                | None => ret None
                | Some d => do def' <- renumber_stmnt d; ret (Some def')
                end;
      ret (Vcase e' cs' def')
    | Vblock e1 e2 =>
      do e1' <- renumber_expr e1;
      do e2' <- renumber_expr e2;
      ret (Vblock e1' e2')
    | Vnonblock e1 e2 =>
      do e1' <- renumber_expr e1;
      do e2' <- renumber_expr e2;
      ret (Vnonblock e1' e2')
    end.

  Definition renumber_module (m : HTL.module) : mon HTL.module :=
      do mod_start' <- renumber_reg (HTL.mod_start m);
      do mod_reset' <- renumber_reg (HTL.mod_reset m);
      do mod_clk' <- get_clk;
      do mod_finish' <- renumber_reg (HTL.mod_finish m);
      do mod_return' <- renumber_reg (HTL.mod_return m);
      do mod_st' <- renumber_reg (HTL.mod_st m);
      do mod_stk' <- renumber_reg (HTL.mod_stk m);
      do mod_params' <- traverselist renumber_reg (HTL.mod_params m);
      do mod_controllogic' <- traverse_ptree1 renumber_stmnt (HTL.mod_controllogic m);
      do mod_datapath' <- traverse_ptree1 renumber_stmnt (HTL.mod_datapath m);

      do _ <- clear_mapping;

      match zle (Z.pos (max_pc_map mod_datapath')) Integers.Int.max_unsigned,
            zle (Z.pos (max_pc_map mod_controllogic')) Integers.Int.max_unsigned with
      | left LEDATA, left LECTRL =>
        ret (HTL.mkmodule
           mod_params'
           mod_datapath'
           mod_controllogic'
           (HTL.mod_entrypoint m)
           mod_st'
           (HTL.mod_stk m)
           (HTL.mod_stk_len m)
           mod_finish'
           mod_return'
           mod_start'
           mod_reset'
           mod_clk'
           (HTL.mod_scldecls m)
           (HTL.mod_arrdecls m)
           (HTL.mod_externctrl m)
           (conj (max_pc_wf _ _ LECTRL) (max_pc_wf _ _ LEDATA)))
      | _, _ => error (Errors.msg "More than 2^32 states.")
      end.

  Definition renumber_fundef (fundef : HTL.fundef) : mon HTL.fundef :=
    match fundef with
    | Internal m => do renumbered <- renumber_module m; ret (Internal renumbered)
    | _ => ret fundef
    end.

  Section TRANSF_PROGRAM_STATEFUL.
    Import RenumberMonad.
    Import RenumberState.
    Import RenumberMonadExtra.
    Import MonadNotation.

    Variables A B V : Type.
    Variable transf_fun: ident -> A -> RenumberMonad.mon B.

    Fixpoint transf_globdefs (l: list (ident * globdef A V)) : RenumberMonad.mon (list (ident * globdef B V)) :=
      match l with
      | nil => RenumberMonad.ret nil
      | (id, Gfun f) :: l' =>
        do tf <- transf_fun id f;
        do tl' <- transf_globdefs l';
        RenumberMonad.ret ((id, Gfun tf) :: tl')
      | (id, Gvar v) :: l' =>
        do tl' <- transf_globdefs l';
        RenumberMonad.ret ((id, Gvar v) :: tl')
      end.

    Definition transform_stateful_program (init_state : RenumberState.st) (p: AST.program A V) : Errors.res (AST.program B V) :=
      RenumberMonad.run_mon init_state (
                          do gl' <- transf_globdefs p.(prog_defs);
                          RenumberMonad.ret (mkprogram gl' p.(prog_public) p.(prog_main))).

  End TRANSF_PROGRAM_STATEFUL.

  Definition get_main_clk (p : HTL.program) : Errors.res reg :=
    let ge := Globalenvs.Genv.globalenv p in
    match Globalenvs.Genv.find_symbol ge p.(AST.prog_main) with
    | Some b =>
      match Globalenvs.Genv.find_funct_ptr ge b with
      | Some (AST.Internal m) => Errors.OK (HTL.mod_clk m)
      | _ => Errors.Error (Errors.msg "Cannot find internal main for renumbering")
      end
    | _ => Errors.Error (Errors.msg "Cannot find internal main for renumbering")
    end.

  Definition renumber_program (p : HTL.program) : Errors.res HTL.program :=
    Errors.bind (get_main_clk p)
                (fun main_clk => transform_stateful_program _ _ _
                                                         (fun _ => renumber_fundef)
                                                         (mk_renumber_state 1%positive (PTree.empty reg) main_clk)
                                                         p).
End RENUMBER.

Definition main_is_internal (p : RTL.program) : bool :=
  let ge := Globalenvs.Genv.globalenv p in
  match Globalenvs.Genv.find_symbol ge p.(AST.prog_main) with
  | Some b =>
    match Globalenvs.Genv.find_funct_ptr ge b with
    | Some (AST.Internal _) => true
    | _ => false
    end
  | _ => false
  end.

Definition transl_program (p : RTL.program) : Errors.res HTL.program :=
  if main_is_internal p
  then transform_partial_program transl_fundef p
  else Errors.Error (Errors.msg "Main function is not Internal.").
