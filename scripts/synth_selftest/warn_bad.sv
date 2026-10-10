// Assigns to an undeclared name, which Yosys accepts with a warning: the log check must reject the run (SR-03).
module st_warn (
  input  logic a,
  output logic y
);
  assign y = a;
  assign undeclared_name = a;
endmodule
