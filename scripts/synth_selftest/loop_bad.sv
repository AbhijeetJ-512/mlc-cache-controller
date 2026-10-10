// A combinational loop through two gates: the flow must reject it (SR-06).
module st_loop (
  input  logic a,
  output logic y
);
  logic p, q;
  assign p = ~(q & a);
  assign q = ~(p | a);
  assign y = q;
endmodule
