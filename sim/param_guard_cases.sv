// Parameter sets for `make elab`. Each module instantiates one design unit with no ports connected;
// the file is never simulated for behaviour. `make elab` elaborates every module here under both
// Icarus (which runs the initial-block parameter checks at time 0) and Yosys (which evaluates them
// at elaboration), and requires:
//   good_*  - accepted by both tools
//   bad_*   - rejected by both tools (non-zero exit from the parameter check)
// This is what proves the NR-05 / NR-06 guards actually fire; without it a guard that never
// triggers would look the same as a guard that works.
//
// The compiled binaries are sim/elab_<module>; this file is deliberately not named elab_*, so the
// ignore rule and `make clean` for those binaries can never match it.
//
// A module is only elaborated when `make elab` selects it as the top, so cases for design units
// added in later tasks can sit in this file before those units exist in the Makefile's source list.

// ---- accepted ----
module good_l2;        l2_cache_ctrl dut ();                                                    endmodule
module good_l2_2way;   l2_cache_ctrl #(.WAYS(2), .CAPACITY_B(16384)) dut ();                    endmodule
module good_engine;    axi4_fill_engine dut ();                                                 endmodule
module good_engine64;  axi4_fill_engine #(.AXI_DATA_W(64)) dut ();                              endmodule

// ---- rejected ----
// Each bad case is chosen so that exactly ONE guard can reject it (every other relationship between
// the parameters is left valid). Then deleting that guard turns the case into an accepted one, which
// `make elab` reports; with several guards overlapping, a deleted guard would go unnoticed.
module bad_l2_ways_3;         l2_cache_ctrl #(.WAYS(3), .CAPACITY_B(24576)) dut ();             endmodule // 3 ways, still 256 sets
module bad_l2_ways_1;         l2_cache_ctrl #(.WAYS(1)) dut ();                                 endmodule // below the 2-way minimum
module bad_l2_capacity;       l2_cache_ctrl #(.CAPACITY_B(32832)) dut ();                       endmodule // not a multiple of LINE_B*WAYS, yet 256 sets by integer division
module bad_l2_line_not_pow2;  l2_cache_ctrl #(.LINE_B(48), .CAPACITY_B(49152)) dut ();          endmodule // 48 B lines, still 256 sets
module bad_l2_sets_not_pow2;  l2_cache_ctrl #(.CAPACITY_B(384)) dut ();                         endmodule // 3 sets of 4 x 32 B
module bad_l2_wr_too_wide;    l2_cache_ctrl #(.WR_BYTES(32)) dut ();                            endmodule // one write slot per line
module bad_l2_wr_not_pow2;    l2_cache_ctrl #(.WR_BYTES(6)) dut ();                             endmodule // 6-byte writes
module bad_engine_width;      axi4_fill_engine #(.AXI_DATA_W(48)) dut ();                       endmodule // 512 bits do not divide into 48-bit beats
module bad_engine_beats;      axi4_fill_engine #(.AXI_DATA_W(1)) dut ();                        endmodule // 512 beats, AXI4 INCR allows 256
module bad_engine_line_4k;    axi4_fill_engine #(.LINE_B(8192), .AXI_DATA_W(256)) dut ();       endmodule // 256 beats, but the line crosses a 4 KiB window
