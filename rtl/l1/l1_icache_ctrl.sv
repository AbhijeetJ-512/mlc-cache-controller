// FR-10: this module's own port list has no write-related ports at all -
// a write attempt from outside is a compile-time impossibility, not a
// runtime case this module has to detect and reject.
module l1_icache_ctrl (
  input  logic                      clk,
  input  logic                      rst_n,
  input  logic                      req_valid,
  output logic                      req_ready,
  input  logic [mlc_pkg::ADDR_W-1:0]         req_addr,
  output logic                      resp_valid,
  input  logic                      resp_ready,
  output logic [mlc_pkg::DATA_W-1:0]         resp_rdata,
  output logic                      dn_req_valid,
  input  logic                      dn_req_ready,
  output logic [mlc_pkg::ADDR_W-1:0]         dn_req_addr,
  output logic                      dn_req_we,
  output logic [mlc_pkg::DATA_W-1:0]         dn_req_wdata,
  output logic [mlc_pkg::BYTES_PER_WORD-1:0] dn_req_wstrb,
  input  logic                      dn_resp_valid,
  output logic                      dn_resp_ready,
  input  logic [mlc_pkg::L1_LINE_W-1:0]      dn_resp_line
);
  l1_cache_ctrl u_core (
    .clk          (clk),
    .rst_n        (rst_n),
    .req_valid    (req_valid),
    .req_ready    (req_ready),
    .req_addr     (req_addr),
    .req_we       (1'b0),
    .req_wdata    ('0),
    .req_wstrb    ('0),
    .resp_valid   (resp_valid),
    .resp_ready   (resp_ready),
    .resp_rdata   (resp_rdata),
    .dn_req_valid (dn_req_valid),
    .dn_req_ready (dn_req_ready),
    .dn_req_addr  (dn_req_addr),
    .dn_req_we    (dn_req_we),
    .dn_req_wdata (dn_req_wdata),
    .dn_req_wstrb (dn_req_wstrb),
    .dn_resp_valid(dn_resp_valid),
    .dn_resp_ready(dn_resp_ready),
    .dn_resp_line (dn_resp_line)
  );
endmodule
