// A Sky130 library cell instantiated in the RTL: the flow must reject it (SR-05, no vendor primitives in the RTL).
module st_rtlcell (
  input  logic a,
  output logic y
);
  sky130_fd_sc_hd__inv_1 u (.A(a), .Y(y));
endmodule
