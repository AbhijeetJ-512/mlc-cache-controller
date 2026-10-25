#!/usr/bin/env python3
"""sva_mutants.py - injected-bug campaign for the cache hierarchy's verification with the bound checkers.

    sva_mutants.py [--jobs N] [--only M13,N05] [--selftest]      -> results/sva/mutants.txt

Mutants M01..M23 are the 23 of scripts/mutate_top.py (a campaign that, with Icarus, used only the system test); N01.. are new ones aimed at the
interface contracts and protocol rules that a data-integrity test cannot see. Each mutant is one edit of the RTL, applied to a copy, built with
Verilator 5.052 together with the checkers, and run through EVERY testbench that contains the edited file (unit, boundary and system tests).
The checkers do not change behaviour, so one run answers two questions:
  KILLED by tests               a testbench reported FAIL / ERROR / FATAL / AXI PROTO, failed to finish, or exited non-zero
  KILLED by an assertion only   no testbench failed, but a checker assertion fired
  SURVIVED                      neither (an expectation is recorded for each survivor)
Every mutant records the assertion it was meant to trip; the campaign reports a MISMATCH when none of them fired. The campaign fails if an edit
is not found exactly once, a mutant is INVALID (does not build), a mutant without a recorded reason for surviving survives, or an assertion in
verif/mlc_checkers.sv never fires in any run (never shown able to fail).
"""
import argparse
import importlib.util
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sva_lib as L  # noqa: E402

ROOT = L.ROOT
spec = importlib.util.spec_from_file_location("mutate_top", os.path.join(ROOT, "scripts", "mutate_top.py"))
mt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mt)

L1, L2, AD, AR, EN, PL = ("rtl/l1/l1_cache_ctrl.sv", "rtl/l2/l2_cache_ctrl.sv", "rtl/adapter/l2_l3_width_adapter.sv", "rtl/arbiter/l1_l2_arbiter.sv",
                          "rtl/mem_if/axi4_fill_engine.sv", "rtl/replace/plru_tree.sv")
# the assertions the first 23 are expected to trip (those a data test already kills are listed too: an assertion that also sees them is a second witness)
EXPECT_OLD = {"M01": [], "M02": [], "M03": [], "M04": [], "M05": [], "M06": [], "M07": [], "M08": ["a_wb_other_line", "a_wb_address"], "M09": [], "M10": [],
              "M11": [], "M12": [], "M13": ["a_evict_waits"], "M14": [], "M15": [], "M16": ["a_half_select"], "M17": ["a_write_strobes"],
              "M18": ["a_resp_owner", "a_resp_ready_own"], "M19": ["a_tie_rule"], "M20": ["a_wstrb_full"], "M21": ["a_aw_aligned", "sb_write_beat_order"],
              "M22": ["a_ar_params"], "M23": ["a_wlast_def"]}
NEW = [
    ("N01", L1, "(state == S_IDLE && req_valid && req_ready && is_hit);", "(state == S_IDLE && req_valid && is_hit);", "L1: a hit raises resp_valid in a cycle in which it was not accepted (phantom response)", ["a_no_phantom"], None),
    ("N02", L1, "(!req_valid || !is_hit || resp_ready);", "(!req_valid || !is_hit || 1'b1);", "L1: a hit is accepted although the CPU cannot take the response", ["a_hit_needs_ready"], None),
    ("N03", L1, "  assign req_ready = rst_n && (state == S_IDLE) && !wr_fwd_pending &&", "  assign req_ready = rst_n && (state == S_IDLE) &&", "L1: a request is accepted while a forwarded store is still pending in the skid register", ["a_skid_blocks"], None),
    ("N04", L1, "  assign dn_resp_ready = (state == S_ALLOC_FILL);", "  assign dn_resp_ready = 1'b1;", "L1: the downstream response channel is always open", ["a_resp_ready_def"], None),
    ("N05", L1, "          if (resp_ready) state <= S_IDLE;", "          state <= S_IDLE;", "L1: the miss response is dropped without waiting for resp_ready", ["a_update_holds", "a_update_exits"], None),
    ("N06", L1, "        if (dn_req_ready) wr_fwd_pending <= 1'b0;", "        wr_fwd_pending <= 1'b0;", "L1: the pending forwarded store is dropped whether or not L2 accepted it", ["a_skid_holds"], None),
    ("N07", L1, "      dn_req_valid = 1'b1; dn_req_addr = miss_addr; dn_req_we = 1'b0;", "      dn_req_valid = 1'b1; dn_req_addr = miss_addr; dn_req_we = 1'b1;", "L1: the fill request is issued as a write", ["a_fill_request"], None),
    ("N08", L2, "  assign resp_valid = (state == S_UPDATE_TAG && !miss_is_write) || (hit_accept && !req_we);", "  assign resp_valid = (state == S_UPDATE_TAG) || (hit_accept && !req_we);", "L2/L3: a write-allocate miss is answered (writes are posted, D-021)", ["a_write_alloc_no_resp"], None),
    ("N09", L2, "(!req_valid || !is_hit || req_we || resp_ready);", "(!req_valid || !is_hit || req_we || 1'b1);", "L2/L3: a read hit is accepted although the requester cannot take the response", ["a_read_hit_ready"], None),
    ("N10", L2, "          if (valid_array[miss_index][victim_way] && dirty_array[miss_index][victim_way])", "          if (dirty_array[miss_index][victim_way])", "L2/L3: a victim's dirty bit is trusted without checking that the line is valid", ["a_check_clean"],
     "survives: dirty_array is not reset, so an invalid way can only carry a stale dirty bit after a power-up with random state; with zero-initialised state (the testbenches' state) the edit is equivalent"),
    ("N11", L2, "      dn_req_addr  = miss_addr;\n      dn_req_we    = 1'b0;", "      dn_req_addr  = miss_addr | 32'h4;\n      dn_req_we    = 1'b0;", "L2/L3: the fill address is not line-aligned (D-025)", ["a_l2_fill_request"], None),
    ("N12", L2, "  assign plru_access_valid = hit_accept || commit_fill;", "  assign plru_access_valid = hit_accept;", "L2/L3: the replacement tree is not updated by a fill", ["a_plru_event"], "survives: replacement quality is not data-visible; the checker sees it"),
    ("N13", L2, "  assign dn_resp_ready = (state == S_ALLOC_FILL);", "  assign dn_resp_ready = 1'b1;", "L2/L3: the downstream response channel is always open", ["a_l2_resp_ready_def"], None),
    ("N14", L2, "          if (miss_is_write || resp_ready) state <= S_IDLE;", "          state <= S_IDLE;", "L2/L3: a read-miss response is dropped without waiting for resp_ready", ["a_update_wait", "a_update_exit"], None),
    ("N15", AR, "  assign l2_req_valid = sel_valid && !busy;", "  assign l2_req_valid = sel_valid;", "arbiter: a request is shown to L2 while a read that missed is still outstanding", ["a_blocked_busy"], None),
    ("N16", AR, "      if (accept) last <= sel;", "      last <= sel;", "arbiter: the round-robin state follows the selection even when nothing was accepted", ["a_last_def", "a_last_keep"], None),
    ("N17", AR, "  assign up0_req_ready = !sel && !busy && l2_req_ready;", "  assign up0_req_ready = !busy && l2_req_ready;", "arbiter: requester 0 is told ready even when requester 1 is the one shown to L2", ["a_one_ready", "a_unselected_wait"], None),
    ("N18", AR, "      last  <= 1'b1;     // so that, after reset, a tie goes to requester 0 (the instruction side)", "      last  <= 1'b0;", "arbiter: after reset a tie goes to the data side", ["a_reset_state"], "survives: which requester wins the first tie is not data-visible"),
    ("N19", AR, "      end else if (busy && l2_resp_valid && l2_resp_ready) begin\n        busy  <= 1'b0;", "      end else if (busy && l2_resp_valid) begin\n        busy  <= 1'b0;", "arbiter: the outstanding read is forgotten when the response is offered, not when it is taken", ["a_busy_hold", "a_busy_clear"], None),
    ("N20", PL, "      ns[node] = ~dir;", "      ns[node] = dir;", "PLRU: the tree is updated towards the way that was just used", ["a_not_just_used"], "survives: replacement quality is not data-visible; the checker sees it"),
    ("N21", PL, "      if (access_valid) state[access_set] <= next_state(state[access_set], access_way);", "      if (access_valid) state[access_set] <= state[access_set];", "PLRU: an access never changes the tree", ["a_not_just_used"], "survives: replacement quality is not data-visible; the checker sees it"),
    ("N22", AD, "  assign l2_req_ready  = l3_req_ready;", "  assign l2_req_ready  = 1'b1;", "adapter: L2 is told its request was accepted whatever L3 says", ["a_ready_through"], None),
    ("N23", AD, "  assign l3_resp_ready = l2_resp_ready;", "  assign l3_resp_ready = 1'b1;", "adapter: L3's response is taken whether or not L2 can accept it", ["a_resp_through"], None),
    ("N24", EN, "          if (arready) state <= S_R;", "          state <= S_R;", "AXI engine: the AR channel is abandoned without ARREADY", ["a_ar_hold"], None),
    ("N25", EN, "          if (awvalid && awready) aw_done_q <= 1'b1;", "          aw_done_q <= 1'b1;", "AXI engine: the AW channel is considered done without AWREADY", ["a_aw_hold"], None),
    ("N26", EN, "  assign awlen   = AXLEN;", "  assign awlen   = AXLEN - 8'd1;", "AXI engine: write bursts are one beat short", ["a_aw_params"], None),
    ("N27", EN, "            if (rlast != last_beat) mem_err <= 1'b1;", "", "AXI engine: an RLAST in the wrong place is not flagged", ["a_err_rlast"], None),
    ("N28", EN, "  assign wdata   = line_q[beat_q*AXI_DATA_W +: AXI_DATA_W];", "  assign wdata   = line_q[(BEATS-1-beat_q)*AXI_DATA_W +: AXI_DATA_W];", "AXI engine: write beats go out in reverse order", ["sb_write_beat_order"], None),
    ("N29", EN, "            if (bresp[1]) mem_err <= 1'b1;\n            state <= S_IDLE;", "            if (bresp[0]) mem_err <= 1'b1;\n            state <= S_IDLE;", "AXI engine: a SLVERR write response is not flagged", ["a_err_bresp"], None),
    ("N30", EN, "  assign bready  = (state == S_B);", "  assign bready  = 1'b1;", "AXI engine: BREADY is always high", ["a_bready_def"], None),
    ("N31", EN, "  assign rready  = (state == S_R);", "  assign rready  = 1'b1;", "AXI engine: RREADY is always high", ["a_rready_def"], None),
]

# P01.. : one mutant for each assertion that none of the first 54 made fire. Each is meant to break exactly the law its assertion states.
# Edits are written against the text of the RTL files as they are; the selftest checks that each is found exactly once.
PNEW = [
    # ---- L1 controller
    ("P01", L1, "  assign resp_valid = (state == S_UPDATE_TAG) || (state == S_IDLE && req_valid && req_ready && is_hit);",
     "  assign resp_valid = (state == S_UPDATE_TAG) || (state == S_IDLE && req_valid && req_ready && is_hit && !req_we);",
     "L1: a store hit is accepted but not answered", ["a_hit_same_cycle"], None),
    ("P02", L1, "  assign req_ready = rst_n && (state == S_IDLE) && !wr_fwd_pending &&",
     "  assign req_ready = rst_n && (state == S_IDLE || state == S_UPDATE_TAG) && !wr_fwd_pending &&",
     "L1: a request is accepted while the miss response is being delivered", ["a_miss_blocks"], None),
    ("P03", L1, "              miss_wstrb    <= req_wstrb;\n              state <= S_ALLOC_FILL;",
     "              miss_wstrb    <= req_wstrb;\n              state <= req_we ? S_IDLE : S_ALLOC_FILL;",
     "L1: a store miss does not start a fill", ["a_miss_starts"], None),
    ("P04", L1, "        S_ALLOC_FILL: begin\n          if (dn_resp_valid) begin",
     "        S_ALLOC_FILL: begin\n          if (dn_resp_valid || dn_req_ready) begin",
     "L1: the fill state is left when L2 accepts the request, not when it answers", ["a_fill_waits"], None),
    ("P05", L1, "            state <= S_UPDATE_TAG;\n          end\n        end\n\n        S_UPDATE_TAG: begin",
     "            state <= miss_is_write ? S_IDLE : S_UPDATE_TAG;\n          end\n        end\n\n        S_UPDATE_TAG: begin",
     "L1: a store miss skips the response state after the fill", ["a_fill_done"], None),
    ("P06", L1, "  assign resp_valid = (state == S_UPDATE_TAG) ||", "  assign resp_valid = (state == S_UPDATE_TAG && !miss_is_write) ||",
     "L1: a store miss is not answered in the response state", ["a_update_resp"], None),
    ("P07", L1, "          if (resp_ready) state <= S_IDLE;", "          if (resp_ready && !wr_fwd_pending) state <= S_IDLE;",
     "L1: the response state is held until a pending forwarded store has gone", ["a_update_exits"], None),
    ("P08", L1, "    if (wr_fwd_pending) begin\n      dn_req_valid = 1'b1; dn_req_addr = wr_fwd_addr; dn_req_we = 1'b1;",
     "    if (wr_fwd_pending && state != S_UPDATE_TAG) begin\n      dn_req_valid = 1'b1; dn_req_addr = wr_fwd_addr; dn_req_we = 1'b1;",
     "L1: a pending forwarded store is not shown to L2 in the response state", ["a_skid_request"], None),
    ("P09", L1, "      dn_req_valid = 1'b0; dn_req_addr = '0; dn_req_we = 1'b0;\n      dn_req_wdata = '0; dn_req_wstrb = '0;\n    end\n  end",
     "      dn_req_valid = (state == S_IDLE) && req_valid && !is_hit && !req_we; dn_req_addr = req_addr; dn_req_we = 1'b0;\n      dn_req_wdata = '0; dn_req_wstrb = '0;\n    end\n  end",
     "L1: a read miss sends its fill request from the idle state", ["a_quiet_idle"], None),
    ("P10", L1, "      state          <= S_IDLE;\n      wr_fwd_pending <= 1'b0;", "      state          <= S_UPDATE_TAG;\n      wr_fwd_pending <= 1'b0;",
     "L1: reset leaves the FSM in the response state", ["a_reset_idle"], None),
    # ---- L2 / L3 controller
    ("P11", L2, "      way_hit[w] = valid_array[req_index][w] && (tag_array[req_index][w] == req_tag);",
     "      way_hit[w] = (valid_array[req_index][w] && (tag_array[req_index][w] == req_tag)) || (w == 1 && valid_array[req_index][0] && (tag_array[req_index][0] == req_tag));",
     "L2/L3: a hit in way 0 is also reported as a hit in way 1", ["a_one_hit"], None),
    ("P12", L2, "  assign resp_valid = (state == S_UPDATE_TAG && !miss_is_write) || (hit_accept && !req_we);",
     "  assign resp_valid = (state == S_UPDATE_TAG && !miss_is_write) || hit_accept;",
     "L2/L3: a write hit is answered (writes are posted, D-021)", ["a_write_posted", "a_resp_only_reads"], None),
    ("P13", L2, "  assign resp_valid = (state == S_UPDATE_TAG && !miss_is_write) || (hit_accept && !req_we);",
     "  assign resp_valid = (state == S_UPDATE_TAG && !miss_is_write);",
     "L2/L3: a read hit is accepted but not answered", ["a_read_hit_resp"], None),
    ("P14", L2, "  assign req_ready = rst_n && (state == S_IDLE) && (!req_valid || !is_hit || req_we || resp_ready);",
     "  assign req_ready = rst_n && (state == S_IDLE || state == S_UPDATE_TAG) && (!req_valid || !is_hit || req_we || resp_ready);",
     "L2/L3: a request is accepted while the miss response is being delivered", ["a_l2_miss_blocks"], None),
    ("P15", L2, "            miss_wstrb    <= req_wstrb;\n            state <= S_TAG_CHECK;", "            miss_wstrb    <= req_wstrb;\n            state <= S_ALLOC_FILL;",
     "L2/L3: a miss skips the tag check (no victim is chosen)", ["a_l2_miss_starts"], None),
    ("P16", L2, "            state <= S_EVICT_WRITEBACK;\n          else", "            state <= S_ALLOC_FILL;\n          else",
     "L2/L3: a dirty victim is overwritten without a write-back", ["a_check_dirty"], None),
    ("P17", L2, "          if (dn_req_ready) state <= S_ALLOC_FILL;", "          if (dn_req_ready) state <= S_TAG_CHECK;",
     "L2/L3: after the write-back is accepted the FSM goes back to the tag check", ["a_evict_done"], None),
    ("P18", L2, "          if (dn_resp_valid) state <= S_UPDATE_TAG;", "          state <= S_UPDATE_TAG;",
     "L2/L3: the fill state is left without waiting for the response", ["a_l2_fill_waits"], None),
    ("P19", L2, "          if (dn_resp_valid) state <= S_UPDATE_TAG;", "          if (dn_resp_valid) state <= miss_is_write ? S_IDLE : S_UPDATE_TAG;",
     "L2/L3: a write-allocate fill skips the update state", ["a_l2_fill_done"], None),
    ("P20", L2, "          if (miss_is_write || resp_ready) state <= S_IDLE;", "          if (resp_ready) state <= S_IDLE;",
     "L2/L3: a posted write waits for resp_ready before leaving the update state", ["a_update_exit"], None),
    ("P21", L2, "  assign resp_valid = (state == S_UPDATE_TAG && !miss_is_write) || (hit_accept && !req_we);",
     "  assign resp_valid = (state == S_UPDATE_TAG && !miss_is_write && !miss_tag[0]) || (hit_accept && !req_we);",
     "L2/L3: a read miss on a line with an odd tag is never answered", ["a_l2_update_resp"], None),
    ("P22", L2, "      dn_req_addr  = miss_addr;\n      dn_req_we    = 1'b0;",
     "      dn_req_addr  = dn_resp_valid ? (miss_addr ^ 32'h8000_0000) : miss_addr;\n      dn_req_we    = 1'b0;",
     "L2/L3: the fill address changes in the cycle the response arrives", ["a_fill_addr_hold"], None),
    ("P23", L2, "      dn_req_valid = 1'b0; dn_req_addr = '0; dn_req_we = 1'b0;\n      dn_req_line = '0;",
     "      dn_req_valid = (state == S_TAG_CHECK); dn_req_addr = '0; dn_req_we = 1'b0;\n      dn_req_line = '0;",
     "L2/L3: a downstream request is raised during the tag check", ["a_quiet_other"], None),
    ("P24", L2, "      state <= S_IDLE;\n      for (int s = 0; s < SETS; s++)", "      state <= S_TAG_CHECK;\n      for (int s = 0; s < SETS; s++)",
     "L2/L3: reset leaves the FSM in the tag check", ["a_l2_reset_idle"], None),
    # ---- arbiter
    ("P25", AR, "  assign l2_req_valid = sel_valid && !busy;", "  assign l2_req_valid = !busy;",
     "arbiter: L2 is shown a request whenever no read is outstanding, with or without a requester", ["a_valid_source"], None),
    ("P26", AR, "  assign l2_req_addr  = sel ? up1_req_addr  : up0_req_addr;", "  assign l2_req_addr  = up1_req_addr;",
     "arbiter: L2 always sees requester 1's address", ["a_payload_0"], None),
    ("P27", AR, "  assign l2_req_addr  = sel ? up1_req_addr  : up0_req_addr;", "  assign l2_req_addr  = up0_req_addr;",
     "arbiter: L2 always sees requester 0's address", ["a_payload_1"], None),
    ("P28", AR, "  assign up1_req_ready =  sel && !busy && l2_req_ready;", "  assign up1_req_ready =  sel && l2_req_ready;",
     "arbiter: requester 1 is told ready while a read is outstanding", ["a_ready_matches"], None),
    ("P29", AR, "        owner <= sel;", "        owner <= last;",
     "arbiter: the owner of an outstanding read is recorded as the previous requester", ["a_busy_set"], None),
    ("P30", AR, "      end else if (busy && l2_resp_valid && l2_resp_ready) begin\n        busy  <= 1'b0;",
     "      end else if (busy && l2_resp_valid && l2_resp_ready) begin\n        busy  <= owner;",
     "arbiter: a response to requester 1 does not release the arbiter", ["a_busy_clear"], None),
    ("P31", AR, "      if (accept && !l2_req_we && !l2_resp_valid) begin", "      if (accept && !l2_resp_valid) begin",
     "arbiter: an accepted write is treated as an outstanding read", ["a_write_not_kept"], None),
    ("P32", AR, "      if (accept && !l2_req_we && !l2_resp_valid) begin", "      if (accept && !l2_req_we) begin",
     "arbiter: a read hit is treated as an outstanding read", ["a_hit_not_kept"], None),
    ("P33", AR, "  assign up0_resp_valid = l2_resp_valid && !resp_to;", "  assign up0_resp_valid = l2_resp_valid;",
     "arbiter: requester 0 is shown every response", ["a_resp_one"], None),
    ("P34", AR, "  assign up1_resp_valid = l2_resp_valid &&  resp_to;", "  assign up1_resp_valid = resp_to;",
     "arbiter: requester 1 is shown a response whenever it is the target", ["a_resp_none"], None),
    ("P35", AR, "  assign resp_to = busy ? owner : sel;", "  assign resp_to = busy ? owner : last;",
     "arbiter: a read hit is answered to the previously accepted requester", ["a_resp_accepted"], None),
    ("P36", AR, "      if (accept) last <= sel;", "      if (accept) last <= ~sel;",
     "arbiter: the round-robin state records the requester that was not accepted", ["a_last_def"], None),
    # ---- replacement tree
    ("P37", PL, "      for (int i = 0; i < SETS; i++) state[i] <= '0;", "      for (int i = 0; i < SETS; i++) state[i] <= '1;",
     "PLRU: reset sets the tree towards the last way", ["a_reset_victim"], None),
    # ---- AXI engine
    ("P38", EN, "          if (wvalid && wready) begin\n            if (last_beat) w_done_q <= 1'b1;", "          if (wvalid) begin\n            if (last_beat) w_done_q <= 1'b1;",
     "AXI engine: the write beat counter advances without WREADY", ["a_w_hold"], None),
    ("P39", EN, "  assign awaddr  = addr_q;", "  assign awaddr  = addr_q | 32'h4;",
     "AXI engine: the write address is not line-aligned", ["a_aw_aligned"], None),
    ("P40", EN, "  assign awaddr  = addr_q;", "  assign awaddr  = {addr_q[mlc_pkg::ADDR_W-1:12], 12'hFE4};",
     "AXI engine: write bursts are addressed at the end of the 4 KiB window", ["a_aw_4k"], None),
    ("P41", EN, "  assign req_ready  = rst_n && (state == S_IDLE);", "  assign req_ready  = rst_n && (state == S_IDLE || state == S_RESP);",
     "AXI engine: a request is accepted while the previous response is still offered", ["a_ready_def"], None),
    ("P42", EN, "  assign rready  = (state == S_R);", "  assign rready  = (state == S_R) && rvalid;",
     "AXI engine: RREADY waits for RVALID (legal AXI, but not the engine's own rule)", ["a_r_follows_ar", "a_rready_def"], None),
    ("P43", EN, ("  assign arvalid = (state == S_AR);", "        S_AR: begin\n          if (arready) state <= S_R;"),
     ("  assign arvalid = (state == S_AR) && w_done_q;", "        S_AR: begin\n          w_done_q <= 1'b1;\n          if (arready && w_done_q) state <= S_R;"),
     "AXI engine: ARVALID is raised one cycle after the request is accepted", ["a_read_request"], None),
    ("P44", EN, "  assign wvalid  = (state == S_WR) && !w_done_q;", "  assign wvalid  = (state == S_WR) && !w_done_q && aw_done_q;",
     "AXI engine: write data waits for the AW handshake (the deadlock D-032 designed out)", ["a_write_request"], None),
    ("P45", EN, "            if (last_beat) state <= S_RESP;\n            else           beat_q <= beat_q + 1'b1;",
     "            if (beat_q >= BEATS - 2) state <= S_RESP;\n            else           beat_q <= beat_q + 1'b1;",
     "AXI engine: the read response is raised one beat early", ["a_resp_after_last"], None),
    ("P46", EN, "          if (resp_ready) state <= S_IDLE;", "          state <= S_IDLE;",
     "AXI engine: the read response is dropped without waiting for resp_ready", ["a_resp_hold"], None),
    ("P47", EN, "            if (bresp[1]) mem_err <= 1'b1;\n            state <= S_IDLE;", "            if (bresp[1]) mem_err <= 1'b1;\n            state <= S_RESP;",
     "AXI engine: a write ends in the read-response state", ["a_write_ends_b"], None),
    ("P48", EN, "            if (rresp[1]) mem_err <= 1'b1;", "            if (rresp[0]) mem_err <= 1'b1;",
     "AXI engine: a SLVERR read response is not flagged", ["a_err_resp"], None),
    ("P49", EN, "            aw_done_q <= 1'b0;\n            w_done_q  <= 1'b0;", "            aw_done_q <= 1'b0;\n            w_done_q  <= 1'b0;\n            mem_err   <= 1'b0;",
     "AXI engine: the error flag is cleared by the next request", ["a_err_sticky"], None),
    ("P50", EN, "            line_q[beat_q*AXI_DATA_W +: AXI_DATA_W] <= rdata;", "            line_q[(BEATS-1-beat_q)*AXI_DATA_W +: AXI_DATA_W] <= rdata;",
     "AXI engine: the read beats are assembled in reverse order", ["a_line_assembled"], None),
    # ---- width adapter
    ("P51", AD, "  assign l3_req_we     = l2_req_we;", "  assign l3_req_we     = 1'b0;",
     "adapter: write-backs are sent to L3 as reads", ["a_req_through"], None),
    ("P52", AD, "  assign l3_req_wdata  = l2_req_line;", "  assign l3_req_wdata  = l2_req_line & ~{{(L2_LINE_W-1){1'b0}}, 1'b1};",
     "adapter: bit 0 of a write-back line is cleared", ["a_write_payload"], None),
]


def mutants():
    out = []
    for mid, rel, old, new, desc, expect in mt.MUTANTS:
        known = None
        if expect.startswith("survives"):
            known = expect
        out.append((mid, rel, old, new, desc, EXPECT_OLD.get(mid, []), known))
    return out + NEW + PNEW


def tbs_for(rel):
    """the testbenches whose sources contain the edited file"""
    return [(n, s) for n, s in L.registry() if n not in L.EXCLUDED and rel in s]


def apply(m, work):
    mid, rel, old, new = m[0], m[1], m[2], m[3]
    d = os.path.join(work, mid, "rtl")
    if os.path.exists(d):
        shutil.rmtree(d)
    shutil.copytree(os.path.join(ROOT, "rtl"), d)
    path = os.path.join(d, rel[len("rtl/"):])
    t = open(path).read()
    pairs = zip(old, new) if isinstance(old, tuple) else [(old, new)]   # a mutant may need several edits (each exactly once)
    for o, n in pairs:
        if t.count(o) != 1:
            return d, "edit text found %d times in %s" % (t.count(o), rel)
        t = t.replace(o, n)
    open(path, "w").write(t)
    return d, None


def run_mutant(m, work, reuse=False, timeout=300):
    mid, rel, old, new, desc, expect, known = m
    d, err = apply(m, work)
    if err:
        return dict(id=mid, desc=desc, status="INVALID", why=err, fired={}, expect=expect, known=known)
    tbs = tbs_for(rel)
    res = L.run_matrix(tbs, os.path.join(work, mid, "runs"), jobs=1, rtl_dir=d, reuse=reuse, timeout=timeout)
    if any(not r["built"] for r in res):
        return dict(id=mid, desc=desc, status="INVALID", why="does not build: " + ",".join(r["tag"] for r in res if not r["built"]), fired={}, expect=expect, known=known)
    fired = {}
    for r in res:
        for k, v in r["fired"].items():
            fired[k] = fired.get(k, 0) + v
    failed = [r["tag"] for r in res if r["tests_failed"]]
    aborted = [r["tag"] for r in res if r["aborted_by_checker"]]
    status = "KILLED by tests" if failed else ("KILLED by an assertion only" if fired else "SURVIVED")
    hit = [e for e in expect if e in fired]
    return dict(id=mid, desc=desc, status=status, why=("failed: " + ", ".join(failed)) if failed else "", fired=fired, expect=expect, known=known,
                mismatch=bool(expect and fired and not hit), runs=len(res), aborted=aborted, failed=failed)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--only")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--resume", action="store_true", help="reuse the finished run logs of an earlier, interrupted campaign")
    ap.add_argument("--out", default=os.path.join(ROOT, "results", "sva", "mutants.txt"))
    a = ap.parse_args()
    work = os.path.join(ROOT, "build", "sva_mutants")
    if not a.resume and not a.selftest and os.path.isdir(work):
        shutil.rmtree(work)
    allm = mutants()
    ms = [m for m in allm if not a.only or m[0] in a.only.split(",")]
    chk = os.path.join(ROOT, "verif", "mlc_checkers.sv")
    asserts = set(L.assertion_labels(chk))
    if a.selftest:
        bad = 0
        ids = [m[0] for m in allm]
        if len(set(ids)) != len(ids):
            print("duplicate ids")
            bad = 1
        for m in allm:
            d, err = apply(m, tempfile.mkdtemp())
            if err:
                print("%s: %s" % (m[0], err))
                bad = 1
            for e in m[5]:
                if e not in asserts:
                    print("%s expects an assertion that does not exist: %s" % (m[0], e))
                    bad = 1
            if not tbs_for(m[1]):
                print("%s: no testbench contains %s" % (m[0], m[1]))
                bad = 1
            for n_, srcs in tbs_for(m[1]):   # every RTL source a run will be given must exist in the mutated copy
                for s in srcs:
                    if s.startswith("rtl/") and not os.path.exists(os.path.join(d, s[len("rtl/"):])):
                        print("%s: %s needs %s, which is not in the mutated copy" % (m[0], n_, s))
                        bad = 1
        print("sva_mutants selftest: %s (%d mutants, %d assertions)" % ("FAILED" if bad else "ok", len(allm), len(asserts)))
        return bad
    import concurrent.futures as cf
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        res = list(ex.map(lambda m: run_mutant(m, work, reuse=a.resume), ms))
    killed = [r for r in res if r["status"].startswith("KILLED")]
    only_assert = [r for r in res if r["status"] == "KILLED by an assertion only"]
    surv = [r for r in res if r["status"] == "SURVIVED"]
    invalid = [r for r in res if r["status"] == "INVALID"]
    all_fired = set()
    for r in res:
        all_fired |= {k for k in r["fired"] if k.startswith(("a_", "sb_"))}
    unv_path = os.path.join(ROOT, "verif", "sva_unviolable.txt")
    unviolable = {}
    if os.path.exists(unv_path):
        for ln in open(unv_path):
            ln = ln.strip()
            if ln and not ln.startswith("#"):
                lab, _, why = ln.partition(" ")
                unviolable[lab] = why.strip()
    stale = sorted(x for x in unviolable if x in all_fired)
    never = [x for x in sorted(asserts) if x not in all_fired and x not in unviolable]
    unexplained = [r for r in surv if not r["known"]]
    mism = [r for r in res if r.get("mismatch")]
    lines = ["mutants: %d, caught %d (by tests %d, by an assertion only %d), survived %d, invalid %d" % (
        len(res), len(killed), len(killed) - len(only_assert), len(only_assert), len(surv), len(invalid)),
        "caught ONLY by an assertion (the testbenches missed them): " + (", ".join(r["id"] for r in only_assert) or "none"),
        "survivors (each with its reason): " + (", ".join(r["id"] for r in surv) or "none"),
        "assertions defined: %d; fired in at least one mutant run: %d" % (len(asserts), len(asserts) - len(never) - len(unviolable)),
        "assertions that fired in no run: " + (", ".join(never) or "none"),
        "assertions no RTL edit can violate (reason in verif/sva_unviolable.txt): " + (", ".join(sorted(unviolable)) or "none"),
        "mutants whose expected assertion did not fire (another one did): " + (", ".join(r["id"] for r in mism) or "none"),
        "PROBLEMS: " + ("; ".join(["INVALID " + r["id"] for r in invalid] + ["UNEXPLAINED SURVIVOR " + r["id"] for r in unexplained] + ["STALE unviolable entry " + x for x in stale]) or "none"), ""]
    for r in sorted(res, key=lambda r: r["id"]):
        lines.append("%s  %-28s %-95s assert-fired: %s" % (r["id"], r["status"], r["desc"][:95], ",".join(sorted(k for k in r["fired"] if k.startswith(("a_", "sb_", "rtl:")))) or "-"))
        if r["status"] == "SURVIVED" and r["known"]:
            lines.append("      %s" % r["known"])
        if r["status"] == "INVALID":
            lines.append("      INVALID: %s" % r["why"])
    os.makedirs(os.path.dirname(a.out), exist_ok=True)
    open(a.out, "w").write("\n".join(lines) + "\n")
    open(os.path.join(os.path.dirname(a.out), "mutants_head.txt"), "w").write("\n".join(lines[:8]) + "\n")   # included by the design document
    print("\n".join(lines[:8]))
    return 1 if (invalid or unexplained or never or stale) else 0


if __name__ == "__main__":
    sys.exit(main())
