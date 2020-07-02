(*
 * CoqUp: Verified high-level synthesis.
 * Copyright (C) 2020 Yann Herklotz <yann@yannherklotz.com>
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

(* begin hide *)
From bbv Require Import Word.
From bbv Require HexNotation WordScope.
From Coq Require Import ZArith.ZArith FSets.FMapPositive Lia.
From compcert Require Import lib.Integers common.Values.
(* end hide *)

(** * Value

A [value] is a bitvector with a specific size. We are using the implementation
of the bitvector by mit-plv/bbv, because it has many theorems that we can reuse.
However, we need to wrap it with an [Inductive] so that we can specify and match
on the size of the [value]. This is necessary so that we can easily store
[value]s of different sizes in a list or in a map.

Using the default [word], this would not be possible, as the size is part of the type. *)

Record value : Type :=
  mkvalue {
    vsize: nat;
    vword: word vsize
  }.

Search N.of_nat.

(** ** Value conversions

Various conversions to different number types such as [N], [Z], [positive] and
[int], where the last one is a theory of integers of powers of 2 in CompCert. *)

Definition wordToValue : forall sz : nat, word sz -> value := mkvalue.

Definition valueToWord : forall v : value, word (vsize v) := vword.

Definition valueToNat (v :value) : nat :=
  wordToNat (vword v).

Definition natToValue sz (n : nat) : value :=
  mkvalue sz (natToWord sz n).

Definition valueToN (v : value) : N :=
  wordToN (vword v).

Definition NToValue sz (n : N) : value :=
  mkvalue sz (NToWord sz n).

Definition ZToValue (s : nat) (z : Z) : value :=
  mkvalue s (ZToWord s z).

Definition valueToZ (v : value) : Z :=
  wordToZ (vword v).

Definition uvalueToZ (v : value) : Z :=
  uwordToZ (vword v).

Definition posToValue sz (p : positive) : value :=
  ZToValue sz (Zpos p).

Definition posToValueAuto (p : positive) : value :=
  let size := Pos.to_nat (Pos.size p) in
  ZToValue size (Zpos p).

Definition valueToPos (v : value) : positive :=
  Z.to_pos (uvalueToZ v).

Definition intToValue (i : Integers.int) : value :=
  ZToValue Int.wordsize (Int.unsigned i).

Definition valueToInt (i : value) : Integers.int :=
  Int.repr (uvalueToZ i).

Definition ptrToValue (i : Integers.ptrofs) : value :=
  ZToValue Ptrofs.wordsize (Ptrofs.unsigned i).

Definition valueToPtr (i : value) : Integers.ptrofs :=
  Ptrofs.repr (uvalueToZ i).

Definition valToValue (v : Values.val) : option value :=
  match v with
  | Values.Vint i => Some (intToValue i)
  | Values.Vptr b off => if Z.eqb (Z.modulo (uvalueToZ (ptrToValue off)) 4) 0%Z
                         then Some (ptrToValue off)
                         else None
  | Values.Vundef => Some (ZToValue 32 0%Z)
  | _ => None
  end.

(** Convert a [value] to a [bool], so that choices can be made based on the
result. This is also because comparison operators will give back [value] instead
of [bool], so if they are in a condition, they will have to be converted before
they can be used. *)

Definition valueToBool (v : value) : bool :=
  negb (weqb (@wzero (vsize v)) (vword v)).

Definition boolToValue (sz : nat) (b : bool) : value :=
  natToValue sz (if b then 1 else 0).

(** ** Arithmetic operations *)

Definition unify_word (sz1 sz2 : nat) (w1 : word sz2): sz1 = sz2 -> word sz1.
intros; subst; assumption. Defined.

Lemma unify_word_unfold :
  forall sz w,
  unify_word sz sz w eq_refl = w.
Proof. auto. Qed.

Definition value_eq_size:
  forall v1 v2 : value, { vsize v1 = vsize v2 } + { True }.
Proof.
  intros; destruct (Nat.eqb (vsize v1) (vsize v2)) eqn:?.
  left; apply Nat.eqb_eq in Heqb; assumption.
  right; trivial.
Defined.

Definition map_any {A : Type} (v1 v2 : value) (f : word (vsize v1) -> word (vsize v1) -> A)
           (EQ : vsize v1 = vsize v2) : A :=
    let w2 := unify_word (vsize v1) (vsize v2) (vword v2) EQ in
    f (vword v1) w2.

Definition map_any_opt {A : Type} (sz : nat) (v1 v2 : value) (f : word (vsize v1) -> word (vsize v1) -> A)
  : option A :=
  match value_eq_size v1 v2 with
  | left EQ =>
    Some (map_any v1 v2 f EQ)
  | _ => None
  end.

Definition map_word (f : forall sz : nat, word sz -> word sz) (v : value) : value :=
  mkvalue (vsize v) (f (vsize v) (vword v)).

Definition map_word2 (f : forall sz : nat, word sz -> word sz -> word sz) (v1 v2 : value)
           (EQ : (vsize v1 = vsize v2)) : value :=
    let w2 := unify_word (vsize v1) (vsize v2) (vword v2) EQ in
    mkvalue (vsize v1) (f (vsize v1) (vword v1) w2).

Definition map_word2_opt (f : forall sz : nat, word sz -> word sz -> word sz) (v1 v2 : value)
  : option value :=
  match value_eq_size v1 v2 with
  | left EQ => Some (map_word2 f v1 v2 EQ)
  | _ => None
  end.

Definition eq_to_opt (v1 v2 : value) (f : vsize v1 = vsize v2 -> value)
  : option value :=
  match value_eq_size v1 v2 with
  | left EQ => Some (f EQ)
  | _ => None
  end.

Lemma eqvalue {sz : nat} (x y : word sz) : x = y <-> mkvalue sz x = mkvalue sz y.
Proof.
  split; intros.
  subst. reflexivity. inversion H. apply existT_wordToZ in H1.
  apply wordToZ_inj. assumption.
Qed.

Lemma eqvaluef {sz : nat} (x y : word sz) : x = y -> mkvalue sz x = mkvalue sz y.
Proof. apply eqvalue. Qed.

Lemma nevalue {sz : nat} (x y : word sz) : x <> y <-> mkvalue sz x <> mkvalue sz y.
Proof. split; intros; intuition. apply H. apply eqvalue. assumption.
       apply H. rewrite H0. trivial.
Qed.

Lemma nevaluef {sz : nat} (x y : word sz) : x <> y -> mkvalue sz x <> mkvalue sz y.
Proof. apply nevalue. Qed.

(*Definition rewrite_word_size (initsz finalsz : nat) (w : word initsz)
  : option (word finalsz) :=
  match Nat.eqb initsz finalsz return option (word finalsz) with
  | true => Some _
  | false => None
  end.*)

Definition valueeq (sz : nat) (x y : word sz) :
  {mkvalue sz x = mkvalue sz y} + {mkvalue sz x <> mkvalue sz y} :=
  match weq x y with
  | left eq => left (eqvaluef x y eq)
  | right ne => right (nevaluef x y ne)
  end.

Definition valueeqb (x y : value) : bool :=
  match value_eq_size x y with
  | left EQ =>
    weqb (vword x) (unify_word (vsize x) (vsize y) (vword y) EQ)
  | right _ => false
  end.

Definition value_projZ_eqb (v1 v2 : value) : bool := Z.eqb (valueToZ v1) (valueToZ v2).

Theorem value_projZ_eqb_true :
  forall v1 v2,
  v1 = v2 -> value_projZ_eqb v1 v2 = true.
Proof. intros. subst. unfold value_projZ_eqb. apply Z.eqb_eq. trivial. Qed.

Theorem valueeqb_true_iff :
  forall v1 v2,
  valueeqb v1 v2 = true <-> v1 = v2.
Proof.
  split; intros.
  unfold valueeqb in H. destruct (value_eq_size v1 v2) eqn:?.
  - destruct v1, v2. simpl in H.
Abort.

Definition value_int_eqb (v : value) (i : int) : bool :=
  Z.eqb (valueToZ v) (Int.unsigned i).

(** Arithmetic operations over [value], interpreting them as signed or unsigned
depending on the operation.

The arithmetic operations over [word] are over [N] by default, however, can also
be called over [Z] explicitly, which is where the bits are interpreted in a
signed manner. *)

Definition vplus v1 v2 := map_word2 wplus v1 v2.
Definition vplus_opt v1 v2 := map_word2_opt wplus v1 v2.
Definition vminus v1 v2 := map_word2 wminus v1 v2.
Definition vmul v1 v2 := map_word2 wmult v1 v2.
Definition vdiv v1 v2 := map_word2 wdiv v1 v2.
Definition vmod v1 v2 := map_word2 wmod v1 v2.

Definition vmuls v1 v2 := map_word2 wmultZ v1 v2.
Definition vdivs v1 v2 := map_word2 wdivZ v1 v2.
Definition vmods v1 v2 := map_word2 wremZ v1 v2.

(** ** Bitwise operations

Bitwise operations over [value], which is independent of whether the number is
signed or unsigned. *)

Definition vnot v := map_word wnot v.
Definition vneg v := map_word wneg v.
Definition vbitneg v := boolToValue (vsize v) (negb (valueToBool v)).
Definition vor v1 v2 := map_word2 wor v1 v2.
Definition vand v1 v2 := map_word2 wand v1 v2.
Definition vxor v1 v2 := map_word2 wxor v1 v2.

(** ** Comparison operators

Comparison operators that return a bool, there should probably be an equivalent
which returns another number, however I might just add that as an explicit
conversion. *)

Definition veqb v1 v2 := map_any v1 v2 (@weqb (vsize v1)).
Definition vneb v1 v2 EQ := negb (veqb v1 v2 EQ).

Definition veq v1 v2 EQ := boolToValue (vsize v1) (veqb v1 v2 EQ).
Definition vne v1 v2 EQ := boolToValue (vsize v1) (vneb v1 v2 EQ).

Definition vltb v1 v2 := map_any v1 v2 wltb.
Definition vleb v1 v2 EQ := negb (map_any v2 v1 wltb (eq_sym EQ)).
Definition vgtb v1 v2 EQ := map_any v2 v1 wltb (eq_sym EQ).
Definition vgeb v1 v2 EQ := negb (map_any v1 v2 wltb EQ).

Definition vltsb v1 v2 := map_any v1 v2 wsltb.
Definition vlesb v1 v2 EQ := negb (map_any v2 v1 wsltb (eq_sym EQ)).
Definition vgtsb v1 v2 EQ := map_any v2 v1 wsltb (eq_sym EQ).
Definition vgesb v1 v2 EQ := negb (map_any v1 v2 wsltb EQ).

Definition vlt v1 v2 EQ := boolToValue (vsize v1) (vltb v1 v2 EQ).
Definition vle v1 v2 EQ := boolToValue (vsize v1) (vleb v1 v2 EQ).
Definition vgt v1 v2 EQ := boolToValue (vsize v1) (vgtb v1 v2 EQ).
Definition vge v1 v2 EQ := boolToValue (vsize v1) (vgeb v1 v2 EQ).

Definition vlts v1 v2 EQ := boolToValue (vsize v1) (vltsb v1 v2 EQ).
Definition vles v1 v2 EQ := boolToValue (vsize v1) (vlesb v1 v2 EQ).
Definition vgts v1 v2 EQ := boolToValue (vsize v1) (vgtsb v1 v2 EQ).
Definition vges v1 v2 EQ := boolToValue (vsize v1) (vgesb v1 v2 EQ).

(** ** Shift operators

Shift operators on values. *)

Definition shift_map (sz : nat) (f : word sz -> nat -> word sz) (w1 w2 : word sz) :=
  f w1 (wordToNat w2).

Definition vshl v1 v2 := map_word2 (fun sz => shift_map sz (@wlshift sz)) v1 v2.
Definition vshr v1 v2 := map_word2 (fun sz => shift_map sz (@wrshift sz)) v1 v2.

Module HexNotationValue.
  Export HexNotation.
  Import WordScope.

  Notation "sz ''h' a" := (NToValue sz (hex a)) (at level 50).

End HexNotationValue.

Inductive val_value_lessdef: val -> value -> Prop :=
| val_value_lessdef_int:
    forall i v',
    vsize v' = 32 ->
    i = valueToInt v' ->
    val_value_lessdef (Vint i) v'
| val_value_lessdef_ptr:
    forall b off v',
    vsize v' = 32 ->
    off = valueToPtr v' ->
    (Z.modulo (uvalueToZ v') 4) = 0%Z ->
    val_value_lessdef (Vptr b off) v'
| lessdef_undef: forall v, val_value_lessdef Vundef v.

Inductive opt_val_value_lessdef: option val -> value -> Prop :=
| opt_lessdef_some:
    forall v v', val_value_lessdef v v' -> opt_val_value_lessdef (Some v) v'
| opt_lessdef_none: forall v, opt_val_value_lessdef None v.

Lemma valueToZ_ZToValue :
  forall n z,
  (- Z.of_nat (2 ^ n) <= z < Z.of_nat (2 ^ n))%Z ->
  valueToZ (ZToValue (S n) z) = z.
Proof.
  unfold valueToZ, ZToValue. simpl.
  auto using wordToZ_ZToWord.
Qed.

Lemma uvalueToZ_ZToValue :
  forall n z,
  (0 <= z < 2 ^ Z.of_nat n)%Z ->
  uvalueToZ (ZToValue n z) = z.
Proof.
  unfold uvalueToZ, ZToValue. simpl.
  auto using uwordToZ_ZToWord.
Qed.

Lemma uvalueToZ_ZToValue_full :
  forall sz : nat,
  (0 < sz)%nat ->
  forall z : Z, uvalueToZ (ZToValue sz z) = (z mod 2 ^ Z.of_nat sz)%Z.
Proof. unfold uvalueToZ, ZToValue. simpl. auto using uwordToZ_ZToWord_full. Qed.

Lemma ZToValue_uvalueToZ :
  forall v,
  ZToValue (vsize v) (uvalueToZ v) = v.
Proof.
  intros.
  unfold ZToValue, uvalueToZ.
  rewrite ZToWord_uwordToZ. destruct v; auto.
Qed.

Lemma valueToPos_posToValueAuto :
  forall p, valueToPos (posToValueAuto p) = p.
Proof.
  intros. unfold valueToPos, posToValueAuto.
  rewrite uvalueToZ_ZToValue. auto. rewrite positive_nat_Z.
  split. apply Zle_0_pos.

  assert (p < 2 ^ (Pos.size p))%positive by apply Pos.size_gt.
  inversion H. rewrite <- Z.compare_lt_iff. rewrite <- H1.
  simpl. rewrite <- Pos2Z.inj_pow_pos. trivial.
Qed.

Lemma valueToPos_posToValue :
  forall p, valueToPos (posToValueAuto p) = p.
Proof.
  intros. unfold valueToPos, posToValueAuto.
  rewrite uvalueToZ_ZToValue. auto. rewrite positive_nat_Z.
  split. apply Zle_0_pos.

  assert (p < 2 ^ (Pos.size p))%positive by apply Pos.size_gt.
  inversion H. rewrite <- Z.compare_lt_iff. rewrite <- H1.
  simpl. rewrite <- Pos2Z.inj_pow_pos. trivial.
Qed.

Lemma valueToInt_intToValue :
  forall v,
  valueToInt (intToValue v) = v.
Proof.
  intros.
  unfold valueToInt, intToValue. rewrite uvalueToZ_ZToValue. auto using Int.repr_unsigned.
  split. apply Int.unsigned_range_2.
  assert ((Int.unsigned v <= Int.max_unsigned)%Z) by apply Int.unsigned_range_2.
  apply Z.lt_le_pred in H. apply H.
Qed.

Lemma valueToPtr_ptrToValue :
  forall v,
  valueToPtr (ptrToValue v) = v.
Proof.
  intros.
  unfold valueToPtr, ptrToValue. rewrite uvalueToZ_ZToValue. auto using Ptrofs.repr_unsigned.
  split. apply Ptrofs.unsigned_range_2.
  assert ((Ptrofs.unsigned v <= Ptrofs.max_unsigned)%Z) by apply Ptrofs.unsigned_range_2.
  apply Z.lt_le_pred in H. apply H.
Qed.

Lemma intToValue_valueToInt :
  forall v,
  vsize v = 32 ->
  intToValue (valueToInt v) = v.
Proof.
  intros. unfold valueToInt, intToValue. rewrite Int.unsigned_repr_eq.
  unfold ZToValue, uvalueToZ. unfold Int.modulus. unfold Int.wordsize. unfold Wordsize_32.wordsize.
  pose proof (uwordToZ_bound (vword v)).
  rewrite Z.mod_small. rewrite <- H. rewrite ZToWord_uwordToZ. destruct v; auto.
  rewrite <- H. rewrite two_power_nat_equiv. apply H0.
Qed.

Lemma ptrToValue_valueToPtr :
  forall v,
  vsize v = 32 ->
  ptrToValue (valueToPtr v) = v.
Proof.
  intros. unfold valueToPtr, ptrToValue. rewrite Ptrofs.unsigned_repr_eq.
  unfold ZToValue, uvalueToZ. unfold Ptrofs.modulus. unfold Ptrofs.wordsize. unfold Wordsize_Ptrofs.wordsize.
  pose proof (uwordToZ_bound (vword v)).
  rewrite Z.mod_small. rewrite <- H. rewrite ZToWord_uwordToZ. destruct v; auto.
  rewrite <- H. rewrite two_power_nat_equiv. apply H0.
Qed.

Lemma valToValue_lessdef :
  forall v v',
    valToValue v = Some v' <->
    val_value_lessdef v v'.
Proof.
  split.
  - intros.
    destruct v; try discriminate; constructor; inversion H; unfold valToValue.
    + unfold intToValue. simpl. auto.
    + symmetry. apply valueToInt_intToValue.
    + destruct ((uvalueToZ (ptrToValue i) mod 4 =? 0)%Z) eqn:?; try discriminate. inversion H1.
      unfold ptrToValue. simpl. auto.
    + destruct ((uvalueToZ (ptrToValue i) mod 4 =? 0)%Z) eqn:?; try discriminate; inversion H1.
      symmetry. apply valueToPtr_ptrToValue.
    + destruct ((uvalueToZ (ptrToValue i) mod 4 =? 0)%Z) eqn:?; try discriminate; inversion H1.
      apply Z.eqb_eq. apply Heqb0.
  - intros. inversion H; subst.
    + simpl. inversion H. subst. rewrite intToValue_valueToInt; auto.
    + simpl. destruct (uvalueToZ (ptrToValue (valueToPtr v')) mod 4 =? 0)%Z eqn:?.
      rewrite ptrToValue_valueToPtr. trivial.
      assumption.
      apply Z.eqb_eq in H2. rewrite ptrToValue_valueToPtr in Heqb0.
      rewrite H2 in Heqb0. discriminate.
      assumption.
    + simpl. inversion H. Abort.


Lemma boolToValue_ValueToBool :
  forall b,
  valueToBool (boolToValue 32 b) = b.
Proof. destruct b; auto. Qed.

Local Open Scope Z.

Ltac word_op_value H :=
  intros; unfold uvalueToZ, ZToValue; simpl; rewrite unify_word_unfold;
  rewrite <- H; rewrite uwordToZ_ZToWord_full; auto; omega.

Lemma zadd_vplus :
  forall sz z1 z2,
  (sz > 0)%nat ->
  uvalueToZ (vplus (ZToValue sz z1) (ZToValue sz z2) eq_refl) = (z1 + z2) mod 2 ^ Z.of_nat sz.
Proof. word_op_value ZToWord_plus. Qed.

Lemma zadd_vplus2 :
  forall z1 z2,
  vplus (ZToValue 32 z1) (ZToValue 32 z2) eq_refl = ZToValue 32 (z1 + z2).
Proof.
  intros. unfold vplus, ZToValue, map_word2. rewrite unify_word_unfold. simpl.
  rewrite ZToWord_plus; auto.
Qed.

Lemma wordsize_32 :
  Int.wordsize = 32%nat.
Proof. auto. Qed.

Lemma intadd_vplus :
  forall i1 i2,
  valueToInt (vplus (intToValue i1) (intToValue i2) eq_refl) = Int.add i1 i2.
Proof.
  intros. unfold Int.add, valueToInt, intToValue. rewrite zadd_vplus.
  rewrite <- Int.unsigned_repr_eq.
  rewrite Int.repr_unsigned. auto. rewrite wordsize_32. omega.
Qed.

Lemma zsub_vminus :
  forall sz z1 z2,
  (sz > 0)%nat ->
  uvalueToZ (vminus (ZToValue sz z1) (ZToValue sz z2) eq_refl) = (z1 - z2) mod 2 ^ Z.of_nat sz.
Proof. word_op_value ZToWord_minus. Qed.

Lemma zmul_vmul :
  forall sz z1 z2,
  (sz > 0)%nat ->
  uvalueToZ (vmul (ZToValue sz z1) (ZToValue sz z2) eq_refl) = (z1 * z2) mod 2 ^ Z.of_nat sz.
Proof. word_op_value ZToWord_mult. Qed.

Local Open Scope N.
Lemma zdiv_vdiv :
  forall n1 n2,
  n1 < 2 ^ 32 ->
  n2 < 2 ^ 32 ->
  n1 / n2 < 2 ^ 32 ->
  valueToN (vdiv (NToValue 32 n1) (NToValue 32 n2) eq_refl) = n1 / n2.
Proof.
  intros; unfold valueToN, NToValue; simpl; rewrite unify_word_unfold. unfold wdiv.
  unfold wordBin. repeat (rewrite wordToN_NToWord_2); auto.
Qed.

(*Lemma ZToValue_valueToNat :
  forall x sz,
  sz > 0 ->
  (x < 2^(Z.of_nat sz))%Z ->
  valueToNat (ZToValue sz x) = Z.to_nat x.
Proof.
  destruct x; intros; unfold ZToValue, valueToNat; simpl.
  - rewrite wzero'_def. apply wordToNat_wzero.
  - rewrite posToWord_nat. rewrite wordToNat_natToWord_2. trivial.
    unfold Z.of_nat in *. destruct sz eqn:?. omega. simpl in H0.
    rewrite <- Pos2Z.inj_pow_pos in H0. Search (Z.pos _ < Z.pos _)%Z.
    Search Pos.to_nat (_ < _). (* Pos2Nat.inj_lt *)
    Search "inj" positive nat.
*)
