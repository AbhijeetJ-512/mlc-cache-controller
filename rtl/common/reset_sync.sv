module reset_sync (
  input  logic clk,
  input  logic async_rst_n,
  output logic rst_n
);
  logic meta;

  always_ff @(posedge clk or negedge async_rst_n) begin
    if (!async_rst_n) begin
      meta  <= 1'b0;
      rst_n <= 1'b0;
    end else begin
      meta  <= 1'b1;
      rst_n <= meta;
    end
  end
endmodule
