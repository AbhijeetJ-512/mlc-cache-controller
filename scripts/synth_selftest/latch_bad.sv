// A transparent latch (the if has no else): the flow must reject it (SR-02).
module st_latch (
  input  logic en,
  input  logic d,
  output logic q
);
  always @* if (en) q = d;
endmodule
