// Two continuous assignments to one net: the flow must reject it (SR-03).
module st_multidriver (
  input  logic a,
  input  logic b,
  output logic y
);
  assign y = a;
  assign y = b;
endmodule
