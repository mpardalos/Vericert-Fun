From compcert Require Import AST.

Definition find_named_func {F V} (ge : Genv.t F V) name :=
  match Genv.find_symbol ge name with
  | Some blk => Genv.find_funct_ptr ge blk
  | None => None
  end.
