(* -*- mode: tuareg -*-
 * CoqUp: Verified high-level synthesis.
 * Copyright (C) 2019-2020 Yann Herklotz <yann@yannherklotz.com>
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

open Verilog
open Value
open Datatypes

open Camlcoq
open AST

open Printf

let concat = String.concat ""

let indent i = String.make (2 * i) ' '

let fold_map f s = List.map f s |> concat

let pstr pp = fprintf pp "%s"

let pprint_binop l r =
  let unsigned op = sprintf "{%s %s %s}" l op r in
  let signed op = sprintf "{$signed(%s) %s $signed(%s)}" l op r in
  function
  | Vadd -> unsigned "+"
  | Vsub -> unsigned "-"
  | Vmul -> unsigned "*"
  | Vdiv -> signed "/"
  | Vdivu -> unsigned "/"
  | Vmod -> signed "%"
  | Vmodu -> unsigned "%"
  | Vlt -> signed "<"
  | Vltu -> unsigned "<"
  | Vgt -> signed ">"
  | Vgtu -> unsigned ">"
  | Vle -> signed "<="
  | Vleu -> unsigned "<="
  | Vge -> signed ">="
  | Vgeu -> unsigned ">="
  | Veq -> unsigned "=="
  | Vne -> unsigned "!="
  | Vand -> unsigned "&"
  | Vor -> unsigned "|"
  | Vxor -> unsigned "^"
  | Vshl -> unsigned "<<"
  | Vshr -> signed ">>>"
  | Vshru -> unsigned ">>"

let unop = function
  | Vneg -> " ~ "
  | Vnot -> " ! "

let register a = sprintf "reg_%d" (P.to_int a)

let literal l = sprintf "%d'd%d" (Nat.to_int l.vsize) (Z.to_int (uvalueToZ l))

let rec pprint_expr = function
  | Vlit l -> literal l
  | Vvar s -> register s
  | Vvari (s, i) -> concat [register s; "["; pprint_expr i; "]"]
  | Vinputvar s -> register s
  | Vunop (u, e) -> concat ["("; unop u; pprint_expr e; ")"]
  | Vbinop (op, a, b) -> concat ["("; pprint_binop (pprint_expr a) (pprint_expr b) op; ")"]
  | Vternary (c, t, f) -> concat ["("; pprint_expr c; " ? "; pprint_expr t; " : "; pprint_expr f; ")"]

let rec pprint_stmnt i =
  let pprint_case (e, s) = concat [ indent (i + 1); pprint_expr e; ": begin\n"; pprint_stmnt (i + 2) s;
                                    indent (i + 1); "end\n"
                                  ]
  in function
  | Vskip -> concat [indent i; ";\n"]
  | Vseq (s1, s2) -> concat [ pprint_stmnt i s1; pprint_stmnt i s2]
  | Vcond (e, st, sf) -> concat [ indent i; "if ("; pprint_expr e; ") begin\n";
                                  pprint_stmnt (i + 1) st; indent i; "end else begin\n";
                                  pprint_stmnt (i + 1) sf;
                                  indent i; "end\n"
                                ]
  | Vcase (e, es, d) -> concat [ indent i; "case ("; pprint_expr e; ")\n";
                              fold_map pprint_case es; indent (i+1); "default:;\n";
                              indent i; "endcase\n"
                            ]
  | Vblock (a, b) -> concat [indent i; pprint_expr a; " = "; pprint_expr b; ";\n"]
  | Vnonblock (a, b) -> concat [indent i; pprint_expr a; " <= "; pprint_expr b; ";\n"]

let rec pprint_edge = function
  | Vposedge r -> concat ["posedge "; register r]
  | Vnegedge r -> concat ["negedge "; register r]
  | Valledge -> "*"
  | Voredge (e1, e2) -> concat [pprint_edge e1; " or "; pprint_edge e2]

let pprint_edge_top i = function
  | Vposedge r -> concat ["@(posedge "; register r; ")"]
  | Vnegedge r -> concat ["@(negedge "; register r; ")"]
  | Valledge -> "@*"
  | Voredge (e1, e2) -> concat ["@("; pprint_edge e1; " or "; pprint_edge e2; ")"]

let declare t =
  function (r, sz) ->
    concat [ t; " ["; sprintf "%d" (Nat.to_int sz - 1); ":0] ";
             register r; ";\n" ]

let declarearr t =
  function (r, sz, ln) ->
    concat [ t; " ["; sprintf "%d" (Nat.to_int sz - 1); ":0] ";
             register r;
             " ["; sprintf "%d" (Nat.to_int ln - 1); ":0];\n" ]

let print_io = function
  | Some Vinput -> "input"
  | Some Voutput -> "output reg"
  | Some Vinout -> "inout"
  | None -> "reg"

let decl i = function
  | Vdecl (io, r, sz) -> concat [indent i; declare (print_io io) (r, sz)]
  | Vdeclarr (io, r, sz, ln) -> concat [indent i; declarearr (print_io io) (r, sz, ln)]

(* TODO Fix always blocks, as they currently always print the same. *)
let pprint_module_item i = function
  | Vdeclaration d -> decl i d
  | Valways (e, s) ->
    concat [indent i; "always "; pprint_edge_top i e; "\n"; pprint_stmnt (i+1) s]
  | Valways_ff (e, s) ->
    concat [indent i; "always "; pprint_edge_top i e; "\n"; pprint_stmnt (i+1) s]
  | Valways_comb (e, s) ->
    concat [indent i; "always "; pprint_edge_top i e; "\n"; pprint_stmnt (i+1) s]
  | Vinitial s ->
    concat [indent i; "initial\n"; indent (i+1); "begin\n"; pprint_stmnt (i+2) s;
           indent (i+1); "end\n"]

let rec intersperse c = function
  | [] -> []
  | [x] -> [x]
  | x :: xs -> x :: c :: intersperse c xs

let make_io i io r = concat [indent i; io; " "; register r; ";\n"]

let compose f g x = g x |> f

let testbench = "module testbench;
   reg start, reset, clk;
   wire finish;
   wire [31:0] return_val;

   main m(start, reset, clk, finish, return_val);

   initial begin
      clk = 0;
      start = 0;
      reset = 0;
      @(posedge clk) reset = 1;
      @(posedge clk) reset = 0;
   end

   always #5 clk = ~clk;

   always @(posedge clk) begin
      if (finish == 1) begin
         $display(\"finished: %d\", return_val);
         $finish;
      end
   end
endmodule
"

let pprint_module i n m =
  let inputs = m.mod_start :: m.mod_reset :: m.mod_clk :: m.mod_args in
  let outputs = [m.mod_finish; m.mod_return] in
  concat [ indent i; "module "; (extern_atom n);
           "("; concat (intersperse ", " (List.map register (inputs @ outputs))); ");\n";
           fold_map (pprint_module_item (i+1)) m.mod_body;
           indent i; "endmodule\n\n"
         ]

let print_result pp lst =
  let rec print_result_in pp = function
    | [] -> fprintf pp "]\n"
    | (r, v) :: ls ->
      fprintf pp "%s -> %s; " (register r) (literal v);
      print_result_in pp ls in
  fprintf pp "[ ";
  print_result_in pp lst

let print_value pp v = fprintf pp "%s" (literal v)

let print_globdef pp (id, gd) =
  match gd with
  | Gfun(Internal f) -> pstr pp (pprint_module 0 id f)
  | _ -> ()

let print_program pp prog =
  List.iter (print_globdef pp) prog.prog_defs;
  pstr pp testbench
