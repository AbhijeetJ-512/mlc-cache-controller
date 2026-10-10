// L1 <-> L2 arbiter (D-033): lets the two L1 controllers (L1-I on port 0, L1-D on port 1) share
// L2's single upstream port. L2 does not know how many requesters it has (02_architecture.md §1);
// everything that depends on there being two lives here, so mlc_cache_top stays pure wiring.
//
// What it relies on (04_interfaces.md §2, all properties of L1 and L2 that the Tier-1 tests pin):
//   - L2 is blocking: after it accepts a read that misses it holds req_ready low until it has
//     returned that read's response, and it never answers a write (posted, D-021).
//   - A read that hits is answered in the cycle it is accepted, and is accepted only when the
//     requester's resp_ready is high in that cycle.
//   - An L1 raises resp_ready only while it waits for its own fill, and holds its fill request
//     (req_valid) until the response arrives.
//
// Request path: one requester is selected and its request shown to L2. Idle: the only requester
// asking, or, if both ask, the one that did not win last (round-robin, so neither side can starve
// the other). A requester that is not selected sees req_ready low.
// Response path: a read that hit is answered in its accept cycle and belongs to the requester
// being accepted. A read that missed is answered later, so the arbiter remembers who asked
// (owner) from the cycle it was accepted until the response is taken, and routes the response,
// and the matching resp_ready, to that requester. While a read is outstanding L2 sees no request.
// The response line is not routed: the top fans it out to both L1 controllers, and only the
// requester that gets resp_valid uses it.
module l1_l2_arbiter (
  input  logic                              clk,
  input  logic                              rst_n,

  // Requester 0 (L1-I) and requester 1 (L1-D): their downstream ports.
  input  logic                              up0_req_valid,
  output logic                              up0_req_ready,
  input  logic [mlc_pkg::ADDR_W-1:0]         up0_req_addr,
  input  logic                              up0_req_we,
  input  logic [mlc_pkg::DATA_W-1:0]         up0_req_wdata,
  input  logic [mlc_pkg::BYTES_PER_WORD-1:0] up0_req_wstrb,
  output logic                              up0_resp_valid,
  input  logic                              up0_resp_ready,

  input  logic                              up1_req_valid,
  output logic                              up1_req_ready,
  input  logic [mlc_pkg::ADDR_W-1:0]         up1_req_addr,
  input  logic                              up1_req_we,
  input  logic [mlc_pkg::DATA_W-1:0]         up1_req_wdata,
  input  logic [mlc_pkg::BYTES_PER_WORD-1:0] up1_req_wstrb,
  output logic                              up1_resp_valid,
  input  logic                              up1_resp_ready,

  // L2's upstream port.
  output logic                              l2_req_valid,
  input  logic                              l2_req_ready,
  output logic [mlc_pkg::ADDR_W-1:0]         l2_req_addr,
  output logic                              l2_req_we,
  output logic [mlc_pkg::DATA_W-1:0]         l2_req_wdata,
  output logic [mlc_pkg::BYTES_PER_WORD-1:0] l2_req_wstrb,
  input  logic                              l2_resp_valid,
  output logic                              l2_resp_ready
);

  logic busy;    // a read that missed has been accepted and its response has not been taken yet
  logic owner;   // which requester that read came from
  logic last;    // which requester was accepted most recently (round-robin state)

  // Which requester's request L2 is shown (only meaningful while no read is outstanding).
  logic sel;
  always_comb begin
    if (up0_req_valid && up1_req_valid) sel = ~last;
    else                                sel = up1_req_valid;
  end

  logic sel_valid;
  assign sel_valid = sel ? up1_req_valid : up0_req_valid;

  // L2 sees nothing while a read is outstanding, so a requester's still-raised fill request
  // cannot be taken as a second request.
  assign l2_req_valid = sel_valid && !busy;
  assign l2_req_addr  = sel ? up1_req_addr  : up0_req_addr;
  assign l2_req_we    = sel ? up1_req_we    : up0_req_we;
  assign l2_req_wdata = sel ? up1_req_wdata : up0_req_wdata;
  assign l2_req_wstrb = sel ? up1_req_wstrb : up0_req_wstrb;

  assign up0_req_ready = !sel && !busy && l2_req_ready;
  assign up1_req_ready =  sel && !busy && l2_req_ready;

  // The response belongs to the owner of an outstanding read, otherwise to the requester being
  // accepted in this very cycle (a read hit).
  logic resp_to;
  assign resp_to = busy ? owner : sel;

  assign up0_resp_valid = l2_resp_valid && !resp_to;
  assign up1_resp_valid = l2_resp_valid &&  resp_to;
  assign l2_resp_ready  = resp_to ? up1_resp_ready : up0_resp_ready;

  logic accept;
  assign accept = l2_req_valid && l2_req_ready;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      busy  <= 1'b0;
      owner <= 1'b0;
      last  <= 1'b1;     // so that, after reset, a tie goes to requester 0 (the instruction side)
    end else begin
      if (accept) last <= sel;
      if (accept && !l2_req_we && !l2_resp_valid) begin
        busy  <= 1'b1;   // a read that was not answered on the spot is a miss
        owner <= sel;
      end else if (busy && l2_resp_valid && l2_resp_ready) begin
        busy  <= 1'b0;
      end
    end
  end

endmodule
