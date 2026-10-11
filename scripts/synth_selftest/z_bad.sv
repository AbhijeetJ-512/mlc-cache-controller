// A constant z on an output: not a tri-state mux, so only Yosys's own warning shows it; the log check must reject it (SR-02).
module st_z (
  input  logic a,
  output logic y,
  output logic z
);
  assign y = a;
  assign z = 1'bz;
endmodule
