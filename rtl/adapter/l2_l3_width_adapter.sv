// L2 <-> L3 line-size adapter (FR-18..FR-21, D-009). Pure wiring: no state, no clock.
//
// L3's line is twice L2's, so one L3 line holds two L2 lines ("halves"). Address bit
// [log2(L2_LINE_B)] says which half a request touches (bit 5 at the defaults).
//   Fill (read):  L2 asks for one half; L3 answers with the whole 64 B line; the adapter hands L2
//                 only the addressed half.
//   Write-back:   L2's evicted line goes to L3 as ONE posted half-line write (L3 is elaborated
//                 with WR_BYTES = L2_LINE_B, so its write slot is exactly one half); the address
//                 bit selects the slot, the strobes are all ones.
// The half select is read from L2's live request address. That is safe because L2 holds its fill
// request, address included, until the fill response has arrived (04_interfaces.md section 2).
module l2_l3_width_adapter #(
  parameter int L2_LINE_B = mlc_pkg::L2_LINE_B,
  parameter int L3_LINE_B = mlc_pkg::L3_LINE_B
) (
  // L2 side: the adapter is the responder to L2's downstream port.
  input  logic                          l2_req_valid,
  output logic                          l2_req_ready,
  input  logic [mlc_pkg::ADDR_W-1:0]     l2_req_addr,
  input  logic                          l2_req_we,
  input  logic [L2_LINE_B*8-1:0]         l2_req_line,
  output logic                          l2_resp_valid,
  input  logic                          l2_resp_ready,
  output logic [L2_LINE_B*8-1:0]         l2_resp_line,

  // L3 side: the adapter is the requester to L3's upstream port.
  output logic                          l3_req_valid,
  input  logic                          l3_req_ready,
  output logic [mlc_pkg::ADDR_W-1:0]     l3_req_addr,
  output logic                          l3_req_we,
  output logic [L2_LINE_B*8-1:0]         l3_req_wdata,
  output logic [L2_LINE_B-1:0]           l3_req_wstrb,
  input  logic                          l3_resp_valid,
  output logic                          l3_resp_ready,
  input  logic [L3_LINE_B*8-1:0]         l3_resp_line
);

  localparam int L2_LINE_W = L2_LINE_B * 8;
  localparam int HALF_BIT  = $clog2(L2_LINE_B);

  // NR-06: the adapter is written for exactly a 2:1 ratio.
  initial begin
    if (L3_LINE_B != 2 * L2_LINE_B)
      $fatal(1, "l2_l3_width_adapter: L3_LINE_B (%0d) must be exactly 2 * L2_LINE_B (%0d) (NR-06)",
             L3_LINE_B, 2 * L2_LINE_B);
  end

  logic half;
  assign half = l2_req_addr[HALF_BIT];

  assign l3_req_valid  = l2_req_valid;
  assign l2_req_ready  = l3_req_ready;
  assign l3_req_addr   = l2_req_addr;
  assign l3_req_we     = l2_req_we;
  assign l3_req_wdata  = l2_req_line;
  assign l3_req_wstrb  = '1;

  assign l2_resp_valid = l3_resp_valid;
  assign l3_resp_ready = l2_resp_ready;
  assign l2_resp_line  = half ? l3_resp_line[L2_LINE_W +: L2_LINE_W]
                              : l3_resp_line[0 +: L2_LINE_W];

endmodule
