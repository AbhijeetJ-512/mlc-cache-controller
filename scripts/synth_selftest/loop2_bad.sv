// A combinational loop that runs through two levels of hierarchy, so it cannot be seen until the design is flattened: the check
// after generic synthesis must reject it (SR-06).
module st_loop2_leaf (input logic a, input logic b, output logic y);
  assign y = ~(a & b);
endmodule
module st_loop2_mid (input logic a, input logic fb, output logic y);
  st_loop2_leaf u (.a(a), .b(fb), .y(y));
endmodule
module st_loop2 (input logic a, output logic y);
  logic p, q;
  st_loop2_mid m1 (.a(a), .fb(q), .y(p));
  st_loop2_mid m2 (.a(a), .fb(p), .y(q));
  assign y = q;
endmodule
