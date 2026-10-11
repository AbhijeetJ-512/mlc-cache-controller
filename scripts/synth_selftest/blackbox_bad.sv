// A black-box module instantiated in the RTL: the flow must reject it (SR-05, no black boxes).
(* blackbox *) module st_bb_cell (input logic a, output logic y);
endmodule
module st_blackbox (
  input  logic a,
  output logic y
);
  st_bb_cell u (.a(a), .y(y));
endmodule
