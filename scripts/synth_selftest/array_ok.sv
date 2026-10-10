// A small register array that is reset and written in one clocked process, read by index. Yosys prints "Replacing memory ...
// with list of registers" for arrays like this one, as it does for the cache arrays that are reset or written next to
// reset registers; the flow must accept it.
module st_array (
  input  logic       clk,
  input  logic       rst_n,
  input  logic [1:0] wr_idx,
  input  logic [1:0] rd_idx,
  input  logic       we,
  input  logic [7:0] wdata,
  output logic [7:0] rdata
);
  logic [7:0] mem [0:3];
  always_ff @(posedge clk or negedge rst_n)
    if (!rst_n) begin
      for (int i = 0; i < 4; i++) mem[i] <= 8'd0;
    end else if (we) begin
      mem[wr_idx] <= wdata;
    end
  assign rdata = mem[rd_idx];
endmodule
