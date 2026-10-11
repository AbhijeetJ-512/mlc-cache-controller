// A tri-state driver: the flow must reject it (SR-02).
module st_tristate (
  input  logic en,
  input  logic a,
  output logic y
);
  assign y = en ? a : 1'bz;
endmodule
