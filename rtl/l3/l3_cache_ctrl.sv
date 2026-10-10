// L3 = the shared write-back controller (l2_cache_ctrl) elaborated at L3's parameters (FR-17,
// D-009). This wrapper adds nothing but the L3 defaults and the NR-06 ratio check, so there is
// exactly one copy of the controller logic.
module l3_cache_ctrl #(
  parameter int CAPACITY_B = mlc_pkg::L3_CAPACITY_B,
  parameter int LINE_B     = mlc_pkg::L3_LINE_B,
  parameter int WAYS       = mlc_pkg::L3_WAYS,
  // One upstream write = one L2 line (an L2 write-back), which is exactly half of an L3 line.
  parameter int WR_BYTES   = mlc_pkg::L2_LINE_B
) (
  input  logic                              clk,
  input  logic                              rst_n,

  input  logic                              req_valid,
  output logic                              req_ready,
  input  logic [mlc_pkg::ADDR_W-1:0]         req_addr,
  input  logic                              req_we,
  input  logic [WR_BYTES*8-1:0]              req_wdata,
  input  logic [WR_BYTES-1:0]                req_wstrb,
  output logic                              resp_valid,
  input  logic                              resp_ready,
  output logic [LINE_B*8-1:0]                resp_line,

  output logic                              dn_req_valid,
  input  logic                              dn_req_ready,
  output logic [mlc_pkg::ADDR_W-1:0]         dn_req_addr,
  output logic                              dn_req_we,
  output logic [mlc_pkg::DATA_W-1:0]         dn_req_wdata,
  output logic [mlc_pkg::BYTES_PER_WORD-1:0] dn_req_wstrb,
  output logic [LINE_B*8-1:0]                dn_req_line,
  input  logic                              dn_resp_valid,
  output logic                              dn_resp_ready,
  input  logic [LINE_B*8-1:0]                dn_resp_line
);

  // NR-06: the adapter assumes exactly a 2:1 line-size ratio between L2 and L3.
  initial begin
    if (LINE_B != 2 * mlc_pkg::L2_LINE_B)
      $fatal(1, "l3_cache_ctrl: LINE_B (%0d) must be exactly 2 * L2_LINE_B (%0d) (NR-06)",
             LINE_B, 2 * mlc_pkg::L2_LINE_B);
  end

  l2_cache_ctrl #(
    .CAPACITY_B (CAPACITY_B),
    .LINE_B     (LINE_B),
    .WAYS       (WAYS),
    .WR_BYTES   (WR_BYTES)
  ) core (.*);

endmodule
