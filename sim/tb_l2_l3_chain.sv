`timescale 1ns/1ps

// Boundary-contract test for the L2 -> adapter -> L3 -> AXI4 fill engine -> AXI memory chain, all
// real modules. Like tb_l1_l2 this is NOT a test of the integrated hierarchy (the Tier-2 UVM
// environment owns that, D-013): it checks the one boundary Phase 3 creates, where an L2 line
// meets L3's twice-as-wide line through the adapter, and where an L2 write-back becomes a posted
// half-line write into L3.
module tb_l2_l3_chain;

  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n_l2;     // L2 alone
  logic rst_n_back;   // everything below the adapter: L3, the engine and the AXI model
  int errors = 0;

  // CPU side of L2
  logic                  req_valid = 1'b0, req_we = 1'b0, resp_ready = 1'b1;
  logic [31:0]           req_addr = '0, req_wdata = '0;
  logic [3:0]            req_wstrb = '0;
  wire                   req_ready, resp_valid;
  wire  [255:0]          resp_line;

  // L2 downstream <-> adapter <-> L3 upstream
  wire                   l2_dn_req_valid, l2_dn_req_ready, l2_dn_req_we, l2_dn_resp_valid, l2_dn_resp_ready;
  wire  [31:0]           l2_dn_req_addr, l2_dn_req_wdata;
  wire  [3:0]            l2_dn_req_wstrb;
  wire  [255:0]          l2_dn_req_line, l2_dn_resp_line;
  wire                   l3_req_valid, l3_req_ready, l3_req_we, l3_resp_valid, l3_resp_ready;
  wire  [31:0]           l3_req_addr;
  wire  [255:0]          l3_req_wdata;
  wire  [31:0]           l3_req_wstrb;
  wire  [511:0]          l3_resp_line;

  // L3 downstream <-> engine <-> AXI
  wire                   dn_req_valid, dn_req_ready, dn_req_we, dn_resp_valid, dn_resp_ready;
  wire  [31:0]           dn_req_addr, dn_req_wdata;
  wire  [3:0]            dn_req_wstrb;
  wire  [511:0]          dn_req_line, dn_resp_line;
  wire [31:0] awaddr, araddr;
  wire [7:0]  awlen, arlen;
  wire [2:0]  awsize, arsize;
  wire [1:0]  awburst, arburst, bresp, rresp;
  wire        awvalid, awready, wlast, wvalid, wready, bvalid, bready, arvalid, arready, rlast, rvalid, rready;
  wire [31:0] wdata, rdata;
  wire [3:0]  wstrb;
  wire        mem_err;

  logic       stall_ar = 1'b0, stall_aw = 1'b0, stall_w = 1'b0;
  logic [3:0] r_gap = 4'd0;
  logic [1:0] force_rresp = 2'b00, force_bresp = 2'b00;

  l2_cache_ctrl l2 (
    .clk, .rst_n(rst_n_l2),
    .req_valid, .req_ready, .req_addr, .req_we, .req_wdata, .req_wstrb,
    .resp_valid, .resp_ready, .resp_line,
    .dn_req_valid(l2_dn_req_valid), .dn_req_ready(l2_dn_req_ready), .dn_req_addr(l2_dn_req_addr),
    .dn_req_we(l2_dn_req_we), .dn_req_wdata(l2_dn_req_wdata), .dn_req_wstrb(l2_dn_req_wstrb),
    .dn_req_line(l2_dn_req_line), .dn_resp_valid(l2_dn_resp_valid), .dn_resp_ready(l2_dn_resp_ready),
    .dn_resp_line(l2_dn_resp_line)
  );

  l2_l3_width_adapter ad (
    .l2_req_valid(l2_dn_req_valid), .l2_req_ready(l2_dn_req_ready), .l2_req_addr(l2_dn_req_addr),
    .l2_req_we(l2_dn_req_we), .l2_req_line(l2_dn_req_line),
    .l2_resp_valid(l2_dn_resp_valid), .l2_resp_ready(l2_dn_resp_ready), .l2_resp_line(l2_dn_resp_line),
    .l3_req_valid, .l3_req_ready, .l3_req_addr, .l3_req_we, .l3_req_wdata, .l3_req_wstrb,
    .l3_resp_valid, .l3_resp_ready, .l3_resp_line
  );

  l3_cache_ctrl l3 (
    .clk, .rst_n(rst_n_back),
    .req_valid(l3_req_valid), .req_ready(l3_req_ready), .req_addr(l3_req_addr), .req_we(l3_req_we),
    .req_wdata(l3_req_wdata), .req_wstrb(l3_req_wstrb),
    .resp_valid(l3_resp_valid), .resp_ready(l3_resp_ready), .resp_line(l3_resp_line),
    .dn_req_valid, .dn_req_ready, .dn_req_addr, .dn_req_we, .dn_req_wdata, .dn_req_wstrb, .dn_req_line,
    .dn_resp_valid, .dn_resp_ready, .dn_resp_line
  );

  axi4_fill_engine eng (
    .clk, .rst_n(rst_n_back),
    .req_valid(dn_req_valid), .req_ready(dn_req_ready), .req_addr(dn_req_addr), .req_we(dn_req_we),
    .req_line(dn_req_line), .resp_valid(dn_resp_valid), .resp_ready(dn_resp_ready), .resp_line(dn_resp_line),
    .awaddr, .awlen, .awsize, .awburst, .awvalid, .awready,
    .wdata, .wstrb, .wlast, .wvalid, .wready,
    .bresp, .bvalid, .bready,
    .araddr, .arlen, .arsize, .arburst, .arvalid, .arready,
    .rdata, .rresp, .rlast, .rvalid, .rready,
    .mem_err
  );

  axi_mem_model #(.DATA_W(32), .EXP_LEN(15), .EXP_SIZE(2), .EXP_ALIGN_B(64)) axi (
    .clk, .rst_n(rst_n_back), .*
  );

  task automatic check(input logic cond, input string msg);
    if (cond) $display("PASS: %s", msg);
    else begin
      $display("FAIL: %s", msg);
      errors++;
    end
  endtask

  // The 32 B line the AXI model holds at a, before anything is written back.
  function automatic logic [255:0] image32(input logic [31:0] a);
    logic [31:0] base;
    base = a & ~31;
    for (int k = 0; k < 8; k++)
      image32[k*32 +: 32] = 32'hC0DE_0000 + (base / 4) + k;
  endfunction

  task automatic cpu_read(input logic [31:0] addr, output logic [255:0] rline);
    @(posedge clk);
    req_valid <= 1'b1; req_we <= 1'b0; req_addr <= addr; resp_ready <= 1'b1;
    wait (req_ready);
    @(posedge clk);
    req_valid <= 1'b0;
    wait (resp_valid);
    #1;    // a response line that is only valid in the cycle of its handshake must still be valid a moment later
    rline = resp_line;
    @(posedge clk);
  endtask

  // Posted word write that must hit in L2.
  task automatic cpu_write_hit(input logic [31:0] addr, input logic [31:0] data);
    @(posedge clk);
    req_valid <= 1'b1; req_we <= 1'b1; req_addr <= addr; req_wdata <= data; req_wstrb <= 4'hF; resp_ready <= 1'b0;
    wait (req_ready);
    @(posedge clk);
    req_valid <= 1'b0;
    #1;
    check(l2.state === l2.S_IDLE, $sformatf("write to 0x%08h is an L2 hit", addr));
  endtask

  logic [255:0] got, exp_line;
  int ar0, aw0, fc0;

  // Reads L2 sends to L3 (fills). A read that is meant to be served by L3 must show up here.
  int l2_fill_count = 0;
  always @(posedge clk) if (l2_dn_req_valid && l2_dn_req_ready && !l2_dn_req_we) l2_fill_count++;

  initial begin
    rst_n_l2 = 1'b0; rst_n_back = 1'b0;
    repeat (3) @(posedge clk);
    rst_n_l2 = 1'b1; rst_n_back = 1'b1;
    @(posedge clk);

    // ---- cold read: L2 miss, L3 miss, one AXI read; L2 gets only the half it asked for ----
    cpu_read(32'h0000_0040, got);                                 // L3 line 0x40, lower half
    check(got === image32(32'h0000_0040), "a cold read returns the addressed 32 B half");
    check(axi.ar_count == 1 && axi.aw_count == 0, "a cold read costs one AXI read and no write");
    check(axi.proto_errors == 0, "the AXI burst is LEN 15, SIZE 2, INCR, 64 B aligned");

    // ---- the other half of the same L3 line: an L2 miss that L3 serves without memory traffic ----
    ar0 = axi.ar_count;
    cpu_read(32'h0000_0060, got);                                 // upper half
    check(got === image32(32'h0000_0060), "the other half of the L3 line comes back through the adapter");
    check(axi.ar_count == ar0, "an L3 hit causes no AXI traffic");

    // ---- an L2 write-back reaches L3 as one half-line write and reads back ----
    cpu_write_hit(32'h0000_0044, 32'hDEAD_BEEF);                  // dirties word 1 of L2 line 0x40
    for (int t = 1; t <= 4; t++)                                  // four more tags in L2 set 2: its 4 ways cycle, line 0x40 is evicted
      cpu_read(32'h0000_0040 + t * 32'h2000, got);
    ar0 = axi.ar_count; aw0 = axi.aw_count; fc0 = l2_fill_count;
    cpu_read(32'h0000_0040, got);                                 // L2 miss, L3 hit on the half the write-back updated
    check(l2_fill_count == fc0 + 1, "the re-read is an L2 miss, so it really goes to L3");
    exp_line = image32(32'h0000_0040);
    exp_line[32 +: 32] = 32'hDEAD_BEEF;
    check(got === exp_line, "the L2 write-back updated the right half of L3's line");
    check(axi.ar_count == ar0 && axi.aw_count == aw0, "that re-read is served by L3 alone");

    // ---- an L2 write-back arriving at an L3 that has forgotten the line (write-allocate, posted) ----
    cpu_write_hit(32'h0000_0044, 32'hCAFE_F00D);                  // L2 hit again (just refilled), dirty
    rst_n_back = 1'b0;                                            // L3, the engine and the AXI model forget everything
    repeat (3) @(posedge clk);
    rst_n_back = 1'b1;
    @(posedge clk);
    for (int t = 5; t <= 8; t++)                                  // four tags not used before: fills cycle through all 4 ways,
      cpu_read(32'h0000_0040 + t * 32'h2000, got);                // so line 0x40 is evicted from L2 and its write-back misses in L3
    ar0 = axi.ar_count; fc0 = l2_fill_count;
    cpu_read(32'h0000_0040, got);                                 // fetched back through L3
    check(l2_fill_count == fc0 + 1, "the re-read is an L2 miss, so it really goes to L3");
    exp_line = image32(32'h0000_0040);
    exp_line[32 +: 32] = 32'hCAFE_F00D;
    check(got === exp_line, "a write-back that misses in L3 is write-allocated and reads back correctly");
    check(axi.ar_count == ar0, "the re-read is served by the line the write-back allocated: no AXI read");

    // ---- the upper half: a write-back must land in the half its address names ----
    cpu_read(32'h0000_0060, got);                                 // L2 line 0x60 = upper half of L3 line 0x40
    cpu_write_hit(32'h0000_0064, 32'hBEEF_0001);                  // dirties word 1 of the upper half
    for (int t = 9; t <= 12; t++)                                 // four fresh tags in L2 set 3 evict line 0x60
      cpu_read(32'h0000_0060 + t * 32'h2000, got);
    fc0 = l2_fill_count;
    cpu_read(32'h0000_0060, got);
    check(l2_fill_count == fc0 + 1, "the upper-half re-read is an L2 miss, so it really goes to L3");
    exp_line = image32(32'h0000_0060);
    exp_line[32 +: 32] = 32'hBEEF_0001;
    check(got === exp_line, "an upper-half L2 write-back updates the upper half of L3's line");
    // L2 still holds line 0x40 here, so a plain re-read would never reach L3: push it out first
    // (four fresh tags in L2 set 2), then require that the re-read does go to L3 (final review).
    for (int t = 13; t <= 16; t++)
      cpu_read(32'h0000_0040 + t * 32'h2000, got);
    ar0 = l2_fill_count;
    cpu_read(32'h0000_0040, got);
    check(l2_fill_count == ar0 + 1, "the lower-half re-read is an L2 miss served by L3");
    exp_line = image32(32'h0000_0040);
    exp_line[32 +: 32] = 32'hCAFE_F00D;
    check(got === exp_line, "and leaves the lower half of that L3 line as it was");
    check(axi.proto_errors == 0, "no AXI protocol violation anywhere in the run");

    if (errors == 0) begin
      $display("** ALL TESTS PASSED **");
      $finish;
    end else begin
      $display("** %0d TEST(S) FAILED **", errors);
      $fatal(1);
    end
  end

  initial begin
    #3000000;
    $display("FAIL: simulation watchdog timeout");
    errors++;
    $fatal(1);
  end

endmodule
