// mlc_checkers.sv - bound assertions and cover points for mlc_cache_controller (attached by verif/mlc_binds.sv).
//
// Added by the portfolio work (2026-10-21); the RTL is not modified by this file. Each checker is bound into one RTL module type, so it runs
// in every testbench that instantiates that module (unit, boundary and system tests alike) without touching the testbenches.
//
// Every assertion is labelled a_* and every cover c_*. The rules come from docs/04_interfaces.md (the "binding contracts": hit timing PF-01,
// blocking misses FR-05, posted writes D-021, the fill request held for the whole fill, write-back payload, arbitration D-033, AXI4 fill
// engine), from the FSM tables in docs/03_microarchitecture.md, or are stated as "design rule" where the RTL header says so. Ready/valid
// rules are written with their converse where one exists. Procedural scoreboards are labelled sb_*.
// Needs the source-built 5.052 simulator (sequence delays); the repository's own flow (Icarus) cannot run concurrent assertions.

// ------------------------------------------------------------------------------------------------------------------------------------
// L1 controller (bound into l1_cache_ctrl; serves both the instruction and the data side)
// ------------------------------------------------------------------------------------------------------------------------------------
module mlc_l1_chk (
  input logic        clk,
  input logic        rst_n,
  input logic        req_valid, req_ready, req_we,
  input logic        resp_valid, resp_ready,
  input logic [31:0] resp_rdata,
  input logic        dn_req_valid, dn_req_ready, dn_req_we,
  input logic [31:0] req_addr, dn_req_addr, dn_req_wdata,
  input logic [3:0]  dn_req_wstrb,
  input logic        dn_resp_valid, dn_resp_ready,
  input logic [1:0]  state,
  input logic        is_hit, wr_fwd_pending, miss_is_write, conflict
);
  localparam logic [1:0] S_IDLE = 2'd0, S_ALLOC_FILL = 2'd1, S_UPDATE_TAG = 2'd2;
  // a checker is armed once it has seen reset asserted; rst_q additionally skips the first cycle after reset is released
  logic armed = 1'b0;
  logic rst_q = 1'b1;
  always @(posedge clk) begin
    rst_q <= rst_n;
    if (!rst_n) armed <= 1'b1;
  end

  logic acc;   // a request is accepted this cycle
  assign acc = state == S_IDLE && req_valid && req_ready;

  // PF-01: a hit completes in the cycle it is accepted, and only then; a response never exists for a request that was not accepted
  a_hit_same_cycle:   assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) acc && is_hit |-> resp_valid);
  a_no_phantom:       assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) resp_valid && state == S_IDLE |-> acc && is_hit);
  // a hit is accepted only when the CPU can take the response in that same cycle (interface contract section 1)
  a_hit_needs_ready:  assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) acc && is_hit |-> resp_ready);
  // FR-05: no request is accepted for the whole miss; a pending forwarded store also blocks acceptance
  a_miss_blocks:      assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state != S_IDLE |-> !req_ready);
  a_skid_blocks:      assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) wr_fwd_pending |-> !req_ready);
  // the miss sequence
  a_miss_starts:      assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) acc && !is_hit |=> state == S_ALLOC_FILL);
  a_fill_waits:       assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_ALLOC_FILL && !dn_resp_valid |=> state == S_ALLOC_FILL);
  a_fill_done:        assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_ALLOC_FILL && dn_resp_valid |=> state == S_UPDATE_TAG);
  a_update_resp:      assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_UPDATE_TAG |-> resp_valid);
  a_update_holds:     assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_UPDATE_TAG && !resp_ready |=> state == S_UPDATE_TAG && resp_valid && $stable(resp_rdata));
  a_update_exits:     assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_UPDATE_TAG && resp_ready |=> state == S_IDLE);
  // inter-level contract: the fill request is a read held for the whole fill, with a stable address; the response channel is open only then
  a_fill_request:     assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_ALLOC_FILL |-> dn_req_valid && !dn_req_we);
  a_fill_addr_stable: assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_ALLOC_FILL && !dn_resp_valid |=> $stable(dn_req_addr));
  a_resp_ready_def:   assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) dn_resp_ready == (state == S_ALLOC_FILL));
  // write-through (D-015): a store hit is forwarded in its accept cycle, with its own address, data and strobes; if L2 cannot take it, the skid register holds it
  a_wt_forward:       assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) acc && is_hit && req_we |-> dn_req_valid && dn_req_we && dn_req_addr == req_addr);
  a_skid_request:     assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) wr_fwd_pending |-> dn_req_valid && dn_req_we);
  a_skid_holds:       assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) wr_fwd_pending && !dn_req_ready |=> wr_fwd_pending && $stable(dn_req_addr) && $stable(dn_req_wdata) && $stable(dn_req_wstrb));
  a_quiet_idle:       assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_IDLE && !wr_fwd_pending && !(acc && is_hit && req_we) |-> !dn_req_valid);
  a_reset_idle:       assert property (@(posedge clk) !rst_n && !rst_q |-> state == S_IDLE && !wr_fwd_pending);

  // one response per accepted request (no loss, no duplicate): outstanding requests never exceed one and never go negative
  int outstanding = 0;
  always @(posedge clk) begin
    if (!armed || !rst_n) outstanding <= 0;
    else begin
      sb_response_has_request: assert (!(resp_valid && resp_ready) || outstanding + (acc ? 1 : 0) >= 1) else $error("a response was taken with no request outstanding");
      sb_accept_when_free:     assert (!acc || outstanding == 0) else $error("a request was accepted while another was still outstanding");
      outstanding <= outstanding + (acc ? 1 : 0) - ((resp_valid && resp_ready) ? 1 : 0);
    end
  end

  c_read_hit:       cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) acc && is_hit && !req_we);
  c_write_hit:      cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) acc && is_hit && req_we);
  c_read_miss:      cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) acc && !is_hit && !req_we);
  c_write_miss:     cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) acc && !is_hit && req_we);
  c_conflict_miss:  cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) acc && !is_hit && conflict);
  c_fill_wait:      cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_ALLOC_FILL && !dn_resp_valid [*3]);
  c_resp_stall:     cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_UPDATE_TAG && !resp_ready ##1 state == S_UPDATE_TAG && resp_ready);
  c_hit_held_off:   cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_IDLE && req_valid && is_hit && !resp_ready);
  c_skid_used:      cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) wr_fwd_pending);
  c_skid_stall2:    cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) wr_fwd_pending && !dn_req_ready [*2]);
  c_write_miss_fwd: cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_UPDATE_TAG && miss_is_write && wr_fwd_pending);
  c_hit_b2b:        cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) acc && is_hit ##1 acc && is_hit);
  c_partial_strb:   cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) dn_req_valid && dn_req_we && dn_req_wstrb != 4'hF && dn_req_wstrb != 4'h0);
endmodule

// ------------------------------------------------------------------------------------------------------------------------------------
// L2 / L3 controller (bound into l2_cache_ctrl; the L3 controller instantiates it)
// ------------------------------------------------------------------------------------------------------------------------------------
module mlc_l2_chk #(
  parameter int LINE_B   = 32,
  parameter int WAYS     = 4,
  parameter int OFFSET_W = 5,
  parameter int INDEX_W  = 8,
  parameter int TAG_W    = 19
) (
  input logic                  clk,
  input logic                  rst_n,
  input logic                  req_valid, req_ready, req_we,
  input logic                  resp_valid, resp_ready,
  input logic [LINE_B*8-1:0]   resp_line, dn_req_line,
  input logic                  dn_req_valid, dn_req_ready, dn_req_we,
  input logic [31:0]           dn_req_addr,
  input logic                  dn_resp_valid, dn_resp_ready,
  input logic [2:0]            state,
  input logic                  is_hit, miss_is_write,
  input logic [WAYS-1:0]       way_hit,
  input logic                  victim_valid, victim_dirty, victim_valid_now, victim_dirty_now, set_full, plru_access_valid,
  input logic [INDEX_W-1:0]    miss_index,
  input logic [TAG_W-1:0]      miss_tag, victim_tag_latched
);
  localparam logic [2:0] S_IDLE = 3'd0, S_TAG_CHECK = 3'd1, S_EVICT = 3'd2, S_ALLOC = 3'd3, S_UPDATE = 3'd4;
  logic armed = 1'b0;
  logic rst_q = 1'b1;
  always @(posedge clk) begin
    rst_q <= rst_n;
    if (!rst_n) armed <= 1'b1;
  end
  logic acc, hit_acc;
  assign acc     = state == S_IDLE && req_valid && req_ready;
  assign hit_acc = acc && is_hit;

  // at most one way can match an address
  a_one_hit:        assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) $onehot0(way_hit));
  // posted writes (D-021, binding): a write is never answered, a read hit is answered in its accept cycle and only if the requester can take it
  a_write_posted:   assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) acc && req_we |-> !resp_valid);
  a_write_alloc_no_resp: assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_UPDATE && miss_is_write |-> !resp_valid);
  a_resp_only_reads: assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) resp_valid && state == S_IDLE |-> hit_acc && !req_we);
  a_read_hit_resp:  assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) hit_acc && !req_we |-> resp_valid);
  a_read_hit_ready: assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) hit_acc && !req_we |-> resp_ready);
  // D-004: misses block
  a_l2_miss_blocks:    assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state != S_IDLE |-> !req_ready);
  // the miss sequence (docs/03_microarchitecture.md): tag check, write back a dirty victim, fill, update
  a_l2_miss_starts:    assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) acc && !is_hit |=> state == S_TAG_CHECK);
  a_check_dirty:    assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_TAG_CHECK &&  victim_valid_now && victim_dirty_now |=> state == S_EVICT);
  a_check_clean:    assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_TAG_CHECK && !(victim_valid_now && victim_dirty_now) |=> state == S_ALLOC);
  a_evict_waits:    assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_EVICT && !dn_req_ready |=> state == S_EVICT);
  a_evict_done:     assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_EVICT &&  dn_req_ready |=> state == S_ALLOC);
  a_l2_fill_waits:     assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_ALLOC && !dn_resp_valid |=> state == S_ALLOC);
  a_l2_fill_done:      assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_ALLOC &&  dn_resp_valid |=> state == S_UPDATE);
  a_update_wait:    assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_UPDATE && !miss_is_write && !resp_ready |=> state == S_UPDATE && resp_valid && $stable(resp_line));
  a_update_exit:    assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_UPDATE && (miss_is_write || resp_ready) |=> state == S_IDLE);
  a_l2_update_resp:    assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_UPDATE && !miss_is_write |-> resp_valid);
  // write-back: only for a valid dirty victim, to the victim's own line (never the line being fetched), line-aligned, payload held until accepted
  a_wb_request:     assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_EVICT |-> dn_req_valid && dn_req_we && victim_valid && victim_dirty);
  a_wb_other_line:  assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_EVICT |-> victim_tag_latched != miss_tag);
  a_wb_address:     assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_EVICT |-> dn_req_addr == {victim_tag_latched, miss_index, {OFFSET_W{1'b0}}});
  a_wb_holds:       assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_EVICT && !dn_req_ready |=> $stable(dn_req_addr) && $stable(dn_req_line));
  // fill: a read of the missing line, line-aligned (D-025), held for the whole fill with a stable address; the response channel is open only then
  a_l2_fill_request:   assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_ALLOC |-> dn_req_valid && !dn_req_we && dn_req_addr == {miss_tag, miss_index, {OFFSET_W{1'b0}}});
  a_fill_addr_hold: assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_ALLOC && !dn_resp_valid |=> $stable(dn_req_addr));
  a_l2_resp_ready_def: assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) dn_resp_ready == (state == S_ALLOC));
  a_quiet_other:    assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) (state == S_IDLE || state == S_TAG_CHECK || state == S_UPDATE) |-> !dn_req_valid);
  // replacement state is updated on a hit or a completed fill, and at no other time
  a_plru_event:     assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) plru_access_valid == (hit_acc || (state == S_ALLOC && dn_resp_valid)));
  a_l2_reset_idle:     assert property (@(posedge clk) !rst_n && !rst_q |-> state == S_IDLE);

  c_read_hit:       cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) hit_acc && !req_we);
  c_write_hit:      cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) hit_acc && req_we);
  c_read_miss:      cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) acc && !is_hit && !req_we);
  c_write_miss:     cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) acc && !is_hit && req_we);
  c_wb_read_miss:   cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_EVICT && !miss_is_write);
  c_wb_write_miss:  cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_EVICT && miss_is_write);
  c_clean_victim:   cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_TAG_CHECK && victim_valid_now && !victim_dirty_now);
  c_invalid_victim: cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_TAG_CHECK && !victim_valid_now);
  c_plru_victim:    cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_TAG_CHECK && set_full);
  c_evict_stall:    cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_EVICT && !dn_req_ready ##1 state == S_EVICT && dn_req_ready);
  c_fill_wait:      cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_ALLOC && !dn_resp_valid [*3]);
  c_resp_stall:     cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_UPDATE && !miss_is_write && !resp_ready ##1 state == S_UPDATE && resp_ready);
  c_hit_held_off:   cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_IDLE && req_valid && is_hit && !req_we && !resp_ready);
  c_write_hit_nr:   cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) hit_acc && req_we && !resp_ready);
  c_hit_b2b:        cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) hit_acc ##1 hit_acc);
  generate
    for (genvar w = 0; w < WAYS; w++) begin : g_way
      c_hit_way:    cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) hit_acc && way_hit[w]);
    end
  endgenerate
endmodule

// ------------------------------------------------------------------------------------------------------------------------------------
// L1 to L2 arbiter (bound into l1_l2_arbiter): D-033
// ------------------------------------------------------------------------------------------------------------------------------------
module mlc_arb_chk (
  input logic        clk,
  input logic        rst_n,
  input logic        up0_req_valid, up0_req_ready, up0_resp_valid, up0_resp_ready, up0_req_we,
  input logic        up1_req_valid, up1_req_ready, up1_resp_valid, up1_resp_ready, up1_req_we,
  input logic [31:0] up0_req_addr, up1_req_addr, l2_req_addr,
  input logic        l2_req_valid, l2_req_ready, l2_req_we, l2_resp_valid, l2_resp_ready,
  input logic        busy, owner, last, sel
);
  logic armed = 1'b0;
  logic rst_q = 1'b1;
  always @(posedge clk) begin
    rst_q <= rst_n;
    if (!rst_n) armed <= 1'b1;
  end
  logic accept;
  assign accept = l2_req_valid && l2_req_ready;

  // L2 is shown one request at a time, and it is the selected requester's
  a_one_ready:      assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) !(up0_req_ready && up1_req_ready));
  a_valid_source:   assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) l2_req_valid |-> (sel ? up1_req_valid : up0_req_valid));
  a_payload_0:      assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) l2_req_valid && !sel |-> l2_req_addr == up0_req_addr && l2_req_we == up0_req_we);
  a_payload_1:      assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) l2_req_valid &&  sel |-> l2_req_addr == up1_req_addr && l2_req_we == up1_req_we);
  a_ready_matches:  assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) (up0_req_ready || up1_req_ready) |-> l2_req_ready && !busy);
  a_unselected_wait: assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) (sel ? up0_req_ready : up1_req_ready) == 1'b0);
  // nothing is shown to L2 while a read that missed is outstanding
  a_blocked_busy:   assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) busy |-> !l2_req_valid);
  a_busy_set:       assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) accept && !l2_req_we && !l2_resp_valid |=> busy && owner == $past(sel));
  a_busy_hold:      assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) busy && !(l2_resp_valid && l2_resp_ready) |=> busy && $stable(owner));
  a_busy_clear:     assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) busy && l2_resp_valid && l2_resp_ready |=> !busy);
  a_write_not_kept: assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) accept && l2_req_we |=> !busy);
  a_hit_not_kept:   assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) accept && !l2_req_we && l2_resp_valid && l2_resp_ready |=> !busy);
  // a response goes to exactly one requester: the one that asked (a read that missed), or the one being accepted (a read that hit)
  a_resp_one:       assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) l2_resp_valid |-> (up0_resp_valid != up1_resp_valid));
  a_resp_none:      assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) !l2_resp_valid |-> !up0_resp_valid && !up1_resp_valid);
  a_resp_owner:     assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) busy && l2_resp_valid |-> (owner ? up1_resp_valid : up0_resp_valid));
  a_resp_ready_own: assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) busy && l2_resp_valid |-> l2_resp_ready == (owner ? up1_resp_ready : up0_resp_ready));
  a_resp_accepted:  assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) !busy && l2_resp_valid |-> (sel ? up1_resp_valid : up0_resp_valid));
  // round robin: on a tie the requester that was not accepted last wins; after reset the instruction side (requester 0) does
  a_tie_rule:       assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) up0_req_valid && up1_req_valid |-> sel == !last);
  a_last_def:       assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) accept |=> last == $past(sel));
  a_last_keep:      assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) !accept |=> $stable(last));
  a_reset_state:    assert property (@(posedge clk) !rst_n && !rst_q |-> !busy && last);

  c_tie_first:      cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) up0_req_valid && up1_req_valid && accept && !sel);
  c_tie_second:     cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) up0_req_valid && up1_req_valid && accept && sel);
  c_alternate:      cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) (up0_req_valid && up1_req_valid && accept && !sel) ##[1:$] (up0_req_valid && up1_req_valid && accept && sel));
  c_busy_other_waits: cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) busy && (owner ? up0_req_valid : up1_req_valid));
  c_miss_to_0:      cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) busy && !owner && l2_resp_valid && l2_resp_ready);
  c_miss_to_1:      cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) busy && owner && l2_resp_valid && l2_resp_ready);
  c_hit_resp_0:     cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) !busy && l2_resp_valid && !sel && up0_resp_ready);
  c_hit_resp_1:     cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) !busy && l2_resp_valid &&  sel && up1_resp_ready);
  c_write_0:        cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) accept && l2_req_we && !sel);
  c_write_1:        cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) accept && l2_req_we &&  sel);
  c_resp_stalled:   cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) busy && l2_resp_valid && !l2_resp_ready);
  c_l2_busy_ready:  cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) l2_req_valid && !l2_req_ready);
endmodule

// ------------------------------------------------------------------------------------------------------------------------------------
// Tree pseudo-LRU (bound into plru_tree)
// ------------------------------------------------------------------------------------------------------------------------------------
module mlc_plru_chk #(
  parameter int WAYS = 4,
  parameter int SETS = 256
) (
  input logic                      clk,
  input logic                      rst_n,
  input logic [$clog2(SETS)-1:0]   set_index, access_set,
  input logic [$clog2(WAYS)-1:0]   victim_way, access_way,
  input logic                      access_valid
);
  logic armed = 1'b0;
  logic rst_q = 1'b1;
  always @(posedge clk) begin
    rst_q <= rst_n;
    if (!rst_n) armed <= 1'b1;
  end
  // the way that was just used is never the next victim of its set (the defining property of the tree)
  a_not_just_used: assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) access_valid |=> set_index != $past(access_set) || victim_way != $past(access_way));
  a_victim_range:  assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) int'(victim_way) < WAYS);
  // a set that has not been touched since reset has the same victim as every other untouched set (all tree bits clear: way 0)
  a_reset_victim:  assert property (@(posedge clk) !rst_n && !rst_q |-> victim_way == '0);

  c_access:        cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) access_valid);
  c_same_set_b2b:  cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) access_valid ##1 access_valid && access_set == $past(access_set));
  generate
    for (genvar w = 0; w < WAYS; w++) begin : g_way
      c_victim_way:   cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) int'(victim_way) == w);
      c_access_way:   cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) access_valid && int'(access_way) == w);
    end
  endgenerate
endmodule

// ------------------------------------------------------------------------------------------------------------------------------------
// AXI4 fill engine (bound into axi4_fill_engine): the memory-side master
// ------------------------------------------------------------------------------------------------------------------------------------
module mlc_axi_chk #(
  parameter int LINE_B     = 64,
  parameter int AXI_DATA_W = 32
) (
  input logic                    clk,
  input logic                    rst_n,
  input logic                    req_valid, req_ready, req_we, resp_valid, resp_ready,
  input logic [31:0]             awaddr, araddr,
  input logic [7:0]              awlen, arlen,
  input logic [2:0]              awsize, arsize,
  input logic [1:0]              awburst, arburst,
  input logic                    awvalid, awready, wlast, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rlast, rready,
  input logic [AXI_DATA_W-1:0]   wdata, rdata,
  input logic [AXI_DATA_W/8-1:0] wstrb,
  input logic [1:0]              bresp, rresp,
  input logic                    mem_err,
  input logic [2:0]              state,
  input logic [31:0]             beat_q,
  input logic [LINE_B*8-1:0]     req_line, resp_line
);
  localparam int BEATS = LINE_B * 8 / AXI_DATA_W;
  localparam logic [2:0] S_IDLE = 3'd0, S_AR = 3'd1, S_R = 3'd2, S_RESP = 3'd3, S_WR = 3'd4, S_B = 3'd5;
  logic armed = 1'b0;
  logic rst_q = 1'b1;
  always @(posedge clk) begin
    rst_q <= rst_n;
    if (!rst_n) armed <= 1'b1;
  end

  // AXI4: a channel holds its payload until the slave accepts it
  a_ar_hold:        assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) arvalid && !arready |=> arvalid && $stable(araddr) && $stable(arlen) && $stable(arsize) && $stable(arburst));
  a_aw_hold:        assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) awvalid && !awready |=> awvalid && $stable(awaddr) && $stable(awlen) && $stable(awsize) && $stable(awburst));
  a_w_hold:         assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) wvalid && !wready |=> wvalid && $stable(wdata) && $stable(wstrb) && $stable(wlast));
  // burst description: INCR, full-width beats, one whole line, line-aligned, inside one 4 KB window
  a_ar_params:      assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) arvalid |-> int'(arlen) == BEATS - 1 && int'(arsize) == $clog2(AXI_DATA_W/8) && arburst == 2'b01);
  a_aw_params:      assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) awvalid |-> int'(awlen) == BEATS - 1 && int'(awsize) == $clog2(AXI_DATA_W/8) && awburst == 2'b01);
  a_ar_aligned:     assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) arvalid |-> araddr[$clog2(LINE_B)-1:0] == '0);
  a_aw_aligned:     assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) awvalid |-> awaddr[$clog2(LINE_B)-1:0] == '0);
  a_ar_4k:          assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) arvalid |-> int'(araddr[11:0]) + LINE_B <= 4096);
  a_aw_4k:          assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) awvalid |-> int'(awaddr[11:0]) + LINE_B <= 4096);
  // write data: all strobes set, WLAST on exactly the last beat
  a_wstrb_full:     assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) wvalid |-> wstrb == '1);
  a_wlast_def:      assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) wlast == (wvalid && int'(beat_q) == BEATS - 1));
  // one transaction at a time; the channels follow the FSM
  a_one_txn:        assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) $onehot0({arvalid, awvalid || wvalid, rready, bready}));
  a_ready_def:      assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) req_ready == (state == S_IDLE));
  a_rready_def:     assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) rready == (state == S_R));
  a_bready_def:     assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) bready == (state == S_B));
  a_r_follows_ar:   assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) arvalid && arready |=> rready);
  a_read_request:   assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) req_valid && req_ready && !req_we |=> arvalid);
  a_write_request:  assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) req_valid && req_ready &&  req_we |=> awvalid && wvalid);
  // the line is returned only after the last beat arrived, and a write completes (returns to idle) only after its response
  a_resp_after_last: assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) $rose(resp_valid) |-> $past(rvalid && rready && int'(beat_q) == BEATS - 1));
  a_resp_hold:      assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) resp_valid && !resp_ready |=> resp_valid);
  a_write_ends_b:   assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_B && bvalid |=> state == S_IDLE);
  // error reporting: an error response or an RLAST in the wrong place is flagged and the flag stays
  a_err_resp:       assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) rvalid && rready && rresp[1] |=> mem_err);
  a_err_rlast:      assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) rvalid && rready && (rlast != (int'(beat_q) == BEATS - 1)) |=> mem_err);
  a_err_bresp:      assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_B && bvalid && bresp[1] |=> mem_err);
  a_err_sticky:     assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) mem_err |=> mem_err);

  // the line handed back is the beats that were read, in order; the beats written are the line that was handed in, in order
  logic [LINE_B*8-1:0] sb_rline = '0, sb_wline = '0, sb_wexp = '0;
  int sb_ri = 0, sb_wi = 0;
  always @(posedge clk) begin
    if (!armed || !rst_n) begin
      sb_ri <= 0;
      sb_wi <= 0;
    end else begin
      if (req_valid && req_ready && req_we) begin
        sb_wexp <= req_line;
        sb_wi   <= 0;
      end
      if (arvalid && arready) sb_ri <= 0;
      if (rvalid && rready) begin
        sb_rline[sb_ri * AXI_DATA_W +: AXI_DATA_W] <= rdata;
        sb_ri <= sb_ri + 1;
      end
      if (wvalid && wready) begin
        sb_wline[sb_wi * AXI_DATA_W +: AXI_DATA_W] <= wdata;
        sb_wi <= sb_wi + 1;
        sb_write_beat_order: assert (wdata == sb_wexp[sb_wi * AXI_DATA_W +: AXI_DATA_W]) else $error("write beat %0d does not carry that slice of the line", sb_wi);
      end
    end
  end
  a_line_assembled: assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) $rose(resp_valid) |-> resp_line == sb_rline);
  a_w_beat_count:   assert property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) wvalid && wready && wlast |-> sb_wi == BEATS - 1);

  c_read:           cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) rvalid && rready && rlast);
  c_write:          cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) bvalid && bready);
  c_ar_stall:       cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) arvalid && !arready ##1 arvalid && arready);
  c_aw_stall:       cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) awvalid && !awready ##1 awvalid && awready);
  c_w_stall:        cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) wvalid && !wready ##1 wvalid && wready);
  c_aw_before_w:    cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) awvalid && awready && !(wvalid && wready) ##[1:$] wvalid && wready && wlast);
  c_w_before_aw:    cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) wvalid && wready && !(awvalid && awready) ##[1:$] awvalid && awready);
  c_r_gap:          cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_R && !rvalid ##1 state == S_R && rvalid);
  c_b_delay:        cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_B && !bvalid ##1 state == S_B && bvalid);
  c_resp_stall:     cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) resp_valid && !resp_ready ##1 resp_valid && resp_ready);
  c_slverr_read:    cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) rvalid && rready && rresp[1]);
  c_slverr_write:   cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) state == S_B && bvalid && bresp[1]);
  c_rlast_wrong:    cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) rvalid && rready && (rlast != (int'(beat_q) == BEATS - 1)));
  c_back_to_back:   cover property (@(posedge clk) disable iff (!armed || !rst_q || !rst_n) (resp_valid && resp_ready) ##1 req_valid && req_ready);
endmodule

// ------------------------------------------------------------------------------------------------------------------------------------
// L2 to L3 width adapter (bound into l2_l3_width_adapter; purely combinational, so these are immediate assertions evaluated on every change)
// ------------------------------------------------------------------------------------------------------------------------------------
module mlc_adapter_chk #(
  parameter int L2_LINE_B = 32,
  parameter int L3_LINE_B = 64
) (
  input logic                    l2_req_valid, l2_req_ready, l2_req_we, l2_resp_valid, l2_resp_ready,
  input logic [31:0]             l2_req_addr, l3_req_addr,
  input logic [L2_LINE_B*8-1:0]  l2_req_line, l3_req_wdata, l2_resp_line,
  input logic                    l3_req_valid, l3_req_ready, l3_req_we, l3_resp_valid, l3_resp_ready,
  input logic [L2_LINE_B-1:0]    l3_req_wstrb,
  input logic [L3_LINE_B*8-1:0]  l3_resp_line
);
  localparam int HB = $clog2(L2_LINE_B);
  localparam int W2 = L2_LINE_B * 8;
  always_comb begin
    a_req_through:   assert (l3_req_valid == l2_req_valid && l3_req_we == l2_req_we && l3_req_addr == l2_req_addr) else $error("request not passed through unchanged");
    a_ready_through: assert (l2_req_ready == l3_req_ready) else $error("request ready not passed back");
    a_write_payload: assert (l3_req_wdata == l2_req_line) else $error("write-back payload altered");
    a_write_strobes: assert (l3_req_wstrb == '1) else $error("write-back strobes not all set");      // D-024
    a_resp_through:  assert (l2_resp_valid == l3_resp_valid && l3_resp_ready == l2_resp_ready) else $error("response handshake not passed through");
    a_half_select:   assert (l2_resp_line == (l2_req_addr[HB] ? l3_resp_line[W2 +: W2] : l3_resp_line[0 +: W2])) else $error("wrong half of the L3 line returned");
  end
endmodule
