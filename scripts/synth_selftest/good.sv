// A clean registered counter: the flow must accept it.
module st_good (
  input  logic       clk,
  input  logic       rst_n,
  output logic [7:0] count
);
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) count <= 8'd0;
    else        count <= count + 8'd1;
endmodule
