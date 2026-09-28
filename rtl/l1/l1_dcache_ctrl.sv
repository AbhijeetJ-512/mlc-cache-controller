import mlc_pkg::*;

module l1_dcache_ctrl (
  input  logic                      clk,
  input  logic                      rst_n,
  input  logic                      req_valid,
  output logic                      req_ready,
  input  logic [ADDR_W-1:0]         req_addr,
  input  logic                      req_we,
  input  logic [DATA_W-1:0]         req_wdata,
  input  logic [BYTES_PER_WORD-1:0] req_wstrb,
  output logic                      resp_valid,
  input  logic                      resp_ready,
  output logic [DATA_W-1:0]         resp_rdata,
  output logic                      dn_req_valid,
  input  logic                      dn_req_ready,
  output logic [ADDR_W-1:0]         dn_req_addr,
  output logic                      dn_req_we,
  output logic [DATA_W-1:0]         dn_req_wdata,
  output logic [BYTES_PER_WORD-1:0] dn_req_wstrb,
  input  logic                      dn_resp_valid,
  output logic                      dn_resp_ready,
  input  logic [L1_LINE_W-1:0]      dn_resp_line
);
  l1_cache_ctrl u_core (.*);
endmodule
