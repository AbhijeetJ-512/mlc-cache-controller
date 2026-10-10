`timescale 1ns/1ps

// Tier-1 test of the L3 controller (l3_cache_ctrl) driving axi4_fill_engine against axi_mem_model.
// The testbench plays the part of the L2/adapter side: it issues reads and posted half-line writes
// to L3's upstream port. AXI burst shape is checked by the memory model against literals.
module tb_l3;

  localparam int LINE_B = 64;
  localparam int LINE_W = LINE_B * 8;
  localparam int HALF_B = 32;
  localparam int HALF_W = HALF_B * 8;
  localparam int WAYS   = 8;

  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n;

  // L3 upstream port (driven by this testbench)
  logic                  req_valid = 1'b0, req_we = 1'b0, resp_ready = 1'b0;
  logic [31:0]           req_addr = '0;
  logic [HALF_W-1:0]     req_wdata = '0;
  logic [HALF_B-1:0]     req_wstrb = '0;
  wire                   req_ready, resp_valid;
  wire  [LINE_W-1:0]     resp_line;

  // L3 downstream port <-> fill engine
  wire                   dn_req_valid, dn_req_ready, dn_req_we, dn_resp_valid, dn_resp_ready;
  wire  [31:0]           dn_req_addr;
  wire  [31:0]           dn_req_wdata;
  wire  [3:0]            dn_req_wstrb;
  wire  [LINE_W-1:0]     dn_req_line, dn_resp_line;

  // AXI4
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

  int errors = 0;

  l3_cache_ctrl dut (.*);

  axi4_fill_engine eng (
    .clk(clk), .rst_n(rst_n),
    .req_valid(dn_req_valid), .req_ready(dn_req_ready), .req_addr(dn_req_addr),
    .req_we(dn_req_we), .req_line(dn_req_line),
    .resp_valid(dn_resp_valid), .resp_ready(dn_resp_ready), .resp_line(dn_resp_line),
    .awaddr, .awlen, .awsize, .awburst, .awvalid, .awready,
    .wdata, .wstrb, .wlast, .wvalid, .wready,
    .bresp, .bvalid, .bready,
    .araddr, .arlen, .arsize, .arburst, .arvalid, .arready,
    .rdata, .rresp, .rlast, .rvalid, .rready,
    .mem_err
  );

  axi_mem_model #(.DATA_W(32), .EXP_LEN(15), .EXP_SIZE(2), .EXP_ALIGN_B(64)) axi (.*);

  task automatic check(input logic cond, input string msg);
    if (cond) $display("PASS: %s", msg);
    else begin
      $display("FAIL: %s", msg);
      errors++;
    end
  endtask

  // The line the memory model holds before anything is written (see axi_mem_model).
  function automatic logic [LINE_W-1:0] image_line(input logic [31:0] a);
    logic [31:0] base;
    base = a & ~(LINE_B - 1);
    for (int k = 0; k < LINE_B / 4; k++)
      image_line[k*32 +: 32] = 32'hC0DE_0000 + (base / 4) + k;
  endfunction

  function automatic logic [HALF_W-1:0] half_pat(input logic [7:0] seed);
    for (int k = 0; k < HALF_B; k++)
      half_pat[k*8 +: 8] = seed + k[7:0];
  endfunction

  // base with one half replaced
  function automatic logic [LINE_W-1:0] with_half(input logic [LINE_W-1:0] base, input int half,
                                                  input logic [HALF_W-1:0] data);
    with_half = base;
    with_half[half*HALF_W +: HALF_W] = data;
  endfunction

  // Whole line sitting in the model's memory at line address a (a must be 64 B aligned).
  function automatic logic [LINE_W-1:0] mem_line(input logic [31:0] a);
    for (int k = 0; k < LINE_B / 4; k++)
      mem_line[k*32 +: 32] = axi.mem[(a / 4) + k];
  endfunction

  // Latched-vs-live guard, as in tb_l2: once a request is accepted, drive junk on the request fields.
  localparam logic [31:0] POISON_ADDR = 32'hDEAD_BEEC;
  task automatic poison_req();
    req_addr  <= POISON_ADDR;
    req_we    <= 1'bx;
    req_wdata <= 'x;
    req_wstrb <= 'x;
  endtask

  task automatic reset_pulse();
    rst_n <= 1'b0;
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    @(posedge clk);
  endtask

  task automatic cpu_read(input logic [31:0] addr, output logic [LINE_W-1:0] rline);
    @(posedge clk);
    req_valid <= 1'b1; req_we <= 1'b0; req_addr <= addr; resp_ready <= 1'b1;
    wait (req_ready);
    @(posedge clk);
    req_valid <= 1'b0;
    poison_req();
    wait (resp_valid);
    rline = resp_line;
    @(posedge clk);
  endtask

  // Posted half-line write that must hit: done when accepted, and the controller stays idle.
  task automatic write_half_hit(input logic [31:0] addr, input logic [HALF_W-1:0] data, input logic [HALF_B-1:0] strb);
    @(posedge clk);
    req_valid <= 1'b1; req_we <= 1'b1; req_addr <= addr; req_wdata <= data; req_wstrb <= strb; resp_ready <= 1'b0;
    wait (req_ready);
    @(posedge clk);
    req_valid <= 1'b0;
    poison_req();
    #1;
    check(dut.core.state === dut.core.S_IDLE, $sformatf("write to 0x%08h is a hit: accepted with no miss sequence", addr));
  endtask

  // Posted half-line write that misses: waits for the whole write-allocate (fill, merge, commit).
  task automatic write_half_alloc(input logic [31:0] addr, input logic [HALF_W-1:0] data, input logic [HALF_B-1:0] strb);
    @(posedge clk);
    req_valid <= 1'b1; req_we <= 1'b1; req_addr <= addr; req_wdata <= data; req_wstrb <= strb; resp_ready <= 1'b0;
    wait (req_ready);
    @(posedge clk);
    req_valid <= 1'b0;
    poison_req();
    wait (dut.core.state === dut.core.S_TAG_CHECK);
    wait (dut.core.state === dut.core.S_IDLE);
  endtask

  // No write ever raises resp_valid (D-021), anywhere in the run.
  int write_resp_count = 0;
  logic acc_we;
  always @(posedge clk) begin
    if (rst_n && resp_valid === 1'b1) begin
      if (req_valid && req_ready) begin
        if (req_we !== 1'b0) write_resp_count++;
      end else if (acc_we !== 1'b0) begin
        write_resp_count++;
      end
    end
    if (req_valid && req_ready) acc_we <= req_we;
  end

  logic [LINE_W-1:0] got, exp_line;
  logic [HALF_W-1:0] wpat;
  int ar0, aw0, wb0;

  initial begin
    rst_n = 1'b0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    check(req_ready === 1'b1, "req_ready is high after reset");

    // ---- cold read miss: one AR burst, whole 64 B line back ----
    cpu_read(32'h0001_0000, got);
    check(got === image_line(32'h0001_0000), "cold read returns the 64 B line from memory");
    check(axi.ar_count == 1 && axi.aw_count == 0, "a cold read costs exactly one AR burst and no AW burst");
    check(axi.proto_errors == 0, "the fill burst is LEN 15, SIZE 2, INCR and 64 B aligned");

    // ---- hit: no memory traffic ----
    ar0 = axi.ar_count;
    cpu_read(32'h0001_0000, got);
    check(got === image_line(32'h0001_0000) && axi.ar_count == ar0, "a repeated read is a hit: no new AR burst");

    // ---- an unaligned request address still reaches AXI line-aligned (FR-24) ----
    cpu_read(32'h0002_0034, got);
    check(got === image_line(32'h0002_0000), "a read at an unaligned address returns its whole line");
    check(axi.proto_errors == 0, "the fill address sent to AXI is line-aligned");

    // ---- half-line writes: a hit replaces only the addressed half ----
    ar0 = axi.ar_count; aw0 = axi.aw_count;
    write_half_hit(32'h0001_0020, half_pat(8'hA0), {HALF_B{1'b1}});          // bit 5 set = upper half
    cpu_read(32'h0001_0000, got);
    exp_line = with_half(image_line(32'h0001_0000), 1, half_pat(8'hA0));
    check(got === exp_line, "an upper-half write hit replaces only the upper 32 B");
    check(axi.ar_count == ar0 && axi.aw_count == aw0, "a half-line write hit causes no AXI traffic");

    // A strobe whose two 16-bit halves differ and which is not a palindrome, so a strobe that is
    // bit-reversed or whose upper bytes borrow the lower half's bits (final review) both show.
    write_half_hit(32'h0001_0000, half_pat(8'hC0), 32'hA5C3_0FF0);
    cpu_read(32'h0001_0000, got);
    wpat = half_pat(8'hC0);
    for (int k = 0; k < HALF_B; k++)
      if (32'hA5C3_0FF0 >> k & 1) exp_line[k*8 +: 8] = wpat[k*8 +: 8];
    check(got[HALF_W-1:0] === exp_line[HALF_W-1:0], "a lower-half write honours the byte strobes");
    check(got[HALF_W +: HALF_W] === half_pat(8'hA0), "the lower-half write leaves the upper half alone");

    // ---- half-line write miss: write-allocate fetches the line, then merges ----
    ar0 = axi.ar_count; aw0 = axi.aw_count;
    write_half_alloc(32'h0003_0000, half_pat(8'h10), {HALF_B{1'b1}});          // lower half of an absent line
    check(axi.ar_count == ar0 + 1 && axi.aw_count == aw0, "a write miss fetches the line (one AR) and writes nothing back");
    cpu_read(32'h0003_0000, got);
    check(got === with_half(image_line(32'h0003_0000), 0, half_pat(8'h10)), "the write-allocate merged into the fetched line");

    // ---- ... and the upper half: the merge must land in the half the address names ----
    ar0 = axi.ar_count; aw0 = axi.aw_count;
    write_half_alloc(32'h0003_0120, half_pat(8'h30), {HALF_B{1'b1}});          // upper half (bit 5 set) of an absent line
    check(axi.ar_count == ar0 + 1 && axi.aw_count == aw0, "an upper-half write miss also fetches the line and writes nothing back");
    cpu_read(32'h0003_0100, got);
    check(got === with_half(image_line(32'h0003_0100), 1, half_pat(8'h30)), "the write-allocate merged into the upper half only");

    // ---- dirty eviction from an 8-way set: exact write-back, ordered before the fill ----
    // Set 1 (index bits [14:6] = 1). Tags stride 0x8000. Eight write-allocates fill the set from
    // reset-state PLRU; the first line filled is the first one the tree points at again.
    for (int t = 0; t < WAYS; t++)
      write_half_alloc(32'h0000_0040 + t * 32'h8000, half_pat(8'h20 + t[7:0]), {HALF_B{1'b1}});
    ar0 = axi.ar_count; aw0 = axi.aw_count; wb0 = axi.wbeat_count;
    cpu_read(32'h0000_0040 + WAYS * 32'h8000, got);                            // 9th distinct tag: evicts
    check(got === image_line(32'h0004_0040), "the 9th tag installs and returns its line");
    check(axi.aw_count == aw0 + 1 && axi.wbeat_count == wb0 + 16, "the dirty eviction is one AW burst of 16 W beats");
    check(axi.ar_count == ar0 + 1, "the eviction is followed by exactly one AR burst for the new line");
    exp_line = with_half(image_line(32'h0000_0040), 0, half_pat(8'h20));
    check(mem_line(32'h0000_0040) === exp_line, "memory holds the evicted line: written half merged, other half original");
    begin
      int n;
      n = axi.ev_is_write.size();
      check(axi.ev_is_write[n-2] === 1'b1 && axi.ev_addr[n-2] === 32'h0000_0040,
            "the write-back (AW) is to the evicted line's address");
      check(axi.ev_is_write[n-1] === 1'b0 && axi.ev_addr[n-1] === 32'h0004_0040,
            "the fill (AR) comes after the write-back, for the new line's address");
    end

    // ---- every way of an 8-way set hits, not just way 0 ----
    // Set 5 filled by eight write-allocates, then a write hit on the upper half of way 6 and a read
    // of every line. A hit whose way number lost its top bit (6 would act as 2) corrupts way 2's
    // line instead (final review).
    for (int t = 0; t < WAYS; t++)
      write_half_alloc(32'h0000_0140 + t * 32'h8000, half_pat(8'h60 + t[7:0]), {HALF_B{1'b1}});
    write_half_hit(32'h0000_0160 + 6 * 32'h8000, half_pat(8'hE6), {HALF_B{1'b1}});
    ar0 = axi.ar_count;
    for (int t = 0; t < WAYS; t++) begin
      cpu_read(32'h0000_0140 + t * 32'h8000, got);
      exp_line = with_half(image_line(32'h0000_0140 + t * 32'h8000), 0, half_pat(8'h60 + t[7:0]));
      if (t == 6) exp_line = with_half(exp_line, 1, half_pat(8'hE6));
      check(got === exp_line, $sformatf("a hit on way %0d of set 5 returns that way's own line", t));
    end
    check(axi.ar_count == ar0, "all eight reads were hits: no AXI read");

    // ---- clean eviction: reads only, so no write-back ----
    for (int t = 0; t < WAYS; t++)
      cpu_read(32'h0000_0080 + t * 32'h8000, got);
    aw0 = axi.aw_count;
    cpu_read(32'h0000_0080 + WAYS * 32'h8000, got);
    check(axi.aw_count == aw0, "evicting a clean line produces no AW burst");

    // ---- backpressure on the AXI channels ----
    stall_ar <= 1'b1; r_gap <= 4'd3;
    @(posedge clk);
    fork
      cpu_read(32'h0005_0000, got);
      begin repeat (8) @(posedge clk); stall_ar <= 1'b0; end
    join
    r_gap <= 4'd0;
    check(got === image_line(32'h0005_0000), "a fill is correct with ARREADY stalled and gaps between R beats");
    // force a dirty eviction while AWREADY and WREADY are stalled
    for (int t = 0; t < WAYS; t++)
      write_half_alloc(32'h0000_00C0 + t * 32'h8000, half_pat(8'h40 + t[7:0]), {HALF_B{1'b1}});
    stall_aw <= 1'b1; stall_w <= 1'b1;
    fork
      cpu_read(32'h0000_00C0 + WAYS * 32'h8000, got);
      begin repeat (8) @(posedge clk); stall_aw <= 1'b0; repeat (8) @(posedge clk); stall_w <= 1'b0; end
    join
    check(got === image_line(32'h0004_00C0), "an eviction is correct with AWREADY and WREADY stalled");
    exp_line = with_half(image_line(32'h0000_00C0), 0, half_pat(8'h40));
    check(mem_line(32'h0000_00C0) === exp_line, "the write-back data is intact after the stalls");
    check(axi.proto_errors == 0, "no AXI protocol violation under backpressure");

    // ---- an AXI error is latched and reported, and data still flows ----
    check(mem_err === 1'b0, "mem_err is low before any error");
    force_rresp <= 2'b10;
    cpu_read(32'h0006_0000, got);
    force_rresp <= 2'b00;
    check(mem_err === 1'b1, "SLVERR on a fill sets mem_err");
    check(got === image_line(32'h0006_0000), "the fill data is still returned after an AXI error");

    // ---- reset in the middle of a fill burst clears the cache ----
    reset_pulse();
    check(mem_err === 1'b0, "reset clears mem_err");
    cpu_read(32'h0001_0000, got);
    ar0 = axi.ar_count;
    r_gap <= 4'd2;
    @(posedge clk);
    req_valid <= 1'b1; req_we <= 1'b0; req_addr <= 32'h0007_0000; resp_ready <= 1'b1;
    wait (req_ready);
    @(posedge clk);
    req_valid <= 1'b0;
    poison_req();
    wait (eng.state === eng.S_R);
    repeat (3) @(posedge clk);
    rst_n <= 1'b0;
    repeat (2) @(posedge clk);
    rst_n <= 1'b1;
    r_gap <= 4'd0;
    @(posedge clk); #1;
    check(dut.core.state === dut.core.S_IDLE && eng.state === eng.S_IDLE && req_ready === 1'b1,
          "reset mid-fill returns L3 and the engine to idle");
    ar0 = axi.ar_count;
    cpu_read(32'h0001_0000, got);
    check(axi.ar_count == ar0 + 1, "reset invalidated the cache: a previously resident line misses again");
    check(got === image_line(32'h0001_0000) , "and the refetched line is correct");

    check(write_resp_count == 0, "no write (hit or write-allocate) raised resp_valid anywhere in the run (D-021)");
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
    #5000000;
    $display("FAIL: simulation watchdog timeout");
    errors++;
    $fatal(1);
  end

endmodule
