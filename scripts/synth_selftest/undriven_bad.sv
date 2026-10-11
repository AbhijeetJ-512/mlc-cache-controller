// An output nothing drives: the flow must reject it (SR-03). `synth` turns an undriven net into x, so the check has to run first.
module st_undriven (
  input  logic a,
  output logic y,
  output logic z
);
  assign y = a;
endmodule
