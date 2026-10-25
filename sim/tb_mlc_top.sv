`timescale 1ns/1ps

// System-level test of the WHOLE hierarchy (mlc_cache_top: L1-I and L1-D, arbiter, L2, adapter, L3, AXI4 fill engine) against an
// AXI4 memory model and a flat reference memory.
//
// PORTFOLIO ADDITION (2026-10-21). The project's own documents say the integrated top "elaborates cleanly but has not been
// simulated" and leave its behaviour to the UVM tier, which needs an external simulator. This test needs none: it drives both CPU
// ports concurrently with directed conflict sweeps and a constrained-random load/store mix, and compares every load with a flat
// reference memory that has no cache in it. It is NOT the UVM environment (no functional coverage, no assertions); it is a
// data-integrity test of the integration, and what it does not cover is stated in docs/portfolio.
//
// Stimulus (all addresses word aligned, inside the 512 KiB the AXI model holds):
//   data region   [0x00000, 0x60000)  384 KiB, larger than the 256 KiB L3, so lines are evicted at every level
//   fetch region  [0x60000, 0x80000)  read-only; the I port fetches here and the D port may also load from it.
//   There is no coherence between L1-I and L1-D (the project's scope, D-001), so the I port never reads an address the D port writes.
// Reference: an associative array of words, default = the AXI model's initial image (mem32(i) = C0DE0000 + i); a store merges its
// byte lanes into the reference at the moment it is issued (the D port is a single in-order requester).
module tb_mlc_top;

  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n;
  int   errors = 0;

  // CPU ports
  logic        i_req_valid = 1'b0, i_resp_ready = 1'b1;
  logic [31:0] i_req_addr  = '0;
  wire         i_req_ready, i_resp_valid;
  wire  [31:0] i_resp_rdata;
  logic        d_req_valid = 1'b0, d_req_we = 1'b0, d_resp_ready = 1'b1;
  logic [31:0] d_req_addr  = '0, d_req_wdata = '0;
  logic [3:0]  d_req_wstrb = '0;
  wire         d_req_ready, d_resp_valid;
  wire  [31:0] d_resp_rdata;

  // AXI4
  wire [31:0] awaddr, araddr, wdata, rdata;
  wire [7:0]  awlen, arlen;
  wire [2:0]  awsize, arsize, awprot, arprot;
  wire [1:0]  awburst, arburst, bresp, rresp;
  wire [3:0]  awcache, arcache, awqos, arqos, awregion, arregion, wstrb;
  wire        awlock, arlock, awvalid, awready, wlast, wvalid, wready, bvalid, bready, arvalid, arready, rlast, rvalid, rready;
  wire        mem_err;
  logic       stall_ar = 1'b0, stall_aw = 1'b0, stall_w = 1'b0;
  logic [3:0] r_gap = 4'd0;
  logic [1:0] force_rresp = 2'b00, force_bresp = 2'b00;

  mlc_cache_top dut (
    .clk, .rst_n,
    .i_req_valid, .i_req_ready, .i_req_addr, .i_resp_valid, .i_resp_ready, .i_resp_rdata,
    .d_req_valid, .d_req_ready, .d_req_addr, .d_req_we, .d_req_wdata, .d_req_wstrb, .d_resp_valid, .d_resp_ready, .d_resp_rdata,
    .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize), .m_axi_awburst(awburst), .m_axi_awlock(awlock),
    .m_axi_awcache(awcache), .m_axi_awprot(awprot), .m_axi_awqos(awqos), .m_axi_awregion(awregion),
    .m_axi_awvalid(awvalid), .m_axi_awready(awready),
    .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
    .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
    .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(arlock),
    .m_axi_arcache(arcache), .m_axi_arprot(arprot), .m_axi_arqos(arqos), .m_axi_arregion(arregion),
    .m_axi_arvalid(arvalid), .m_axi_arready(arready),
    .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready),
    .mem_err
  );

  axi_mem_model #(.DATA_W(32), .EXP_LEN(15), .EXP_SIZE(2), .EXP_ALIGN_B(64)) mem (
    .clk, .rst_n,
    .stall_ar, .stall_aw, .stall_w, .r_gap, .force_rresp, .force_bresp,
    .awaddr, .awlen, .awsize, .awburst, .awvalid, .awready,
    .wdata, .wstrb, .wlast, .wvalid, .wready,
    .bresp, .bvalid, .bready,
    .araddr, .arlen, .arsize, .arburst, .arvalid, .arready,
    .rdata, .rresp, .rlast, .rvalid, .rready
  );

  // ------------------------------------------------------------------ reference memory and bookkeeping
  localparam logic [31:0] D_LIMIT = 32'h0006_0000;
  localparam logic [31:0] I_BASE  = 32'h0006_0000;
  localparam logic [31:0] I_LIMIT = 32'h0008_0000;

  // Icarus 12 has no associative arrays: a plain array over the 512 KiB the AXI model holds.
  localparam int MEM_WORDS = 131072;
  logic [31:0] refm [0:MEM_WORDS-1];
  initial for (int i = 0; i < MEM_WORDS; i++) refm[i] = 32'hC0DE_0000 + i;
  function automatic logic [31:0] ref_word(input logic [31:0] a);
    ref_word = refm[(a >> 2) % MEM_WORDS];
  endfunction
  task automatic ref_store(input logic [31:0] a, input logic [31:0] d, input logic [3:0] s);
    logic [31:0] w;
    w = ref_word(a);
    for (int b = 0; b < 4; b++) if (s[b]) w[b*8 +: 8] = d[b*8 +: 8];
    refm[(a >> 2) % MEM_WORDS] = w;
  endtask

  int d_loads = 0, d_stores = 0, i_fetches = 0, load_mismatches = 0, fetch_mismatches = 0;
  int d_done = 0, i_done = 0;

  // xorshift32: deterministic and simulator independent
  function automatic logic [31:0] xs(input logic [31:0] x);
    x = x ^ (x << 13);
    x = x ^ (x >> 17);
    x = x ^ (x << 5);
    xs = x;
  endfunction
  logic [31:0] rs_d = 32'h1BAD_5EED, rs_i = 32'h0C0F_FEE1;
  task automatic rnd_d(output logic [31:0] r);  rs_d = xs(rs_d); r = rs_d; endtask
  task automatic rnd_i(output logic [31:0] r);  rs_i = xs(rs_i); r = rs_i; endtask

  // ------------------------------------------------------------------ CPU-side tasks (same protocol as the Tier-1 tests)
  task automatic d_read(input logic [31:0] a, output logic [31:0] q);
    @(posedge clk);
    d_req_valid <= 1'b1; d_req_we <= 1'b0; d_req_addr <= a; d_resp_ready <= 1'b1;
    wait (d_req_ready);
    @(posedge clk);
    d_req_valid <= 1'b0;
    wait (d_resp_valid);
    q = d_resp_rdata;
    @(posedge clk);
  endtask

  task automatic d_write(input logic [31:0] a, input logic [31:0] d, input logic [3:0] s);
    @(posedge clk);
    d_req_valid <= 1'b1; d_req_we <= 1'b1; d_req_addr <= a; d_req_wdata <= d; d_req_wstrb <= s; d_resp_ready <= 1'b1;
    wait (d_req_ready);
    @(posedge clk);
    d_req_valid <= 1'b0; d_req_we <= 1'b0;
    wait (d_resp_valid);
    @(posedge clk);
  endtask

  task automatic i_read(input logic [31:0] a, output logic [31:0] q);
    @(posedge clk);
    i_req_valid <= 1'b1; i_req_addr <= a; i_resp_ready <= 1'b1;
    wait (i_req_ready);
    @(posedge clk);
    i_req_valid <= 1'b0;
    wait (i_resp_valid);
    q = i_resp_rdata;
    @(posedge clk);
  endtask

  task automatic do_load(input logic [31:0] a);
    logic [31:0] q;
    d_read(a, q);
    d_loads++;
    if (q !== ref_word(a)) begin
      load_mismatches++;
      if (load_mismatches <= 10) begin
        $display("FAIL: load 0x%08h returned 0x%08h, reference 0x%08h", a, q, ref_word(a));
        errors++;
      end
    end
  endtask

  task automatic do_store(input logic [31:0] a, input logic [31:0] d, input logic [3:0] s);
    d_write(a, d, s);
    ref_store(a, d, s);
    d_stores++;
  endtask

  // ------------------------------------------------------------------ D-port stimulus
  function automatic logic [31:0] pick_d_addr(input logic [31:0] r1, input logic [31:0] r2);
    logic [31:0] a;
    case (r1[2:0])
      3'd0, 3'd1, 3'd2: a = (r2[7:0] % 64) * 32 + (r2[10:8] % 8) * 4;                           // hot set, mostly L1 hits
      3'd3: a = (r2[7:0] % 32) * 32'h1000 + (r2[15:8] % 8) * 4;                                  // L1 conflicts (4 KiB stride)
      3'd4: a = (r2[7:0] % 48) * 32'h2000 + (r2[15:8] % 8) * 4;                                  // L2 conflicts (8 KiB stride)
      3'd5: a = (r2[7:0] % 12) * 32'h8000 + (r2[10:8] % 2) * 32 + (r2[15:12] % 8) * 4;          // L3 conflicts (32 KiB stride)
      default: a = (r2 % (D_LIMIT / 4)) * 4;                                                       // uniform over the data region
    endcase
    pick_d_addr = a % D_LIMIT;
  endfunction

  function automatic logic [3:0] pick_strobe(input logic [31:0] r);
    case (r[3:0])
      4'd0, 4'd1, 4'd2, 4'd3, 4'd4, 4'd5, 4'd6, 4'd7, 4'd8: pick_strobe = 4'hF;
      4'd9:  pick_strobe = 4'h3;
      4'd10: pick_strobe = 4'hC;
      4'd11: pick_strobe = 4'h1;
      4'd12: pick_strobe = 4'h2;
      4'd13: pick_strobe = 4'h4;
      4'd14: pick_strobe = 4'h8;
      default: pick_strobe = 4'h6;
    endcase
  endfunction

  localparam int N_RANDOM  = 12000;
  localparam int N_FETCH   = 4000;

  initial begin : d_driver
    logic [31:0] r1, r2, r3, a;
    wait (rst_n === 1'b1);
    repeat (5) @(posedge clk);

    // 1. read sweep: first touch of 2000 lines, every miss goes to memory
    for (int i = 0; i < 2000; i++) do_load(i * 32);

    // 2. L1 / L2 / L3 conflict sweeps: write k lines that map to one set, then read them all back (twice)
    for (int stride_sel = 0; stride_sel < 3; stride_sel++) begin
      logic [31:0] stride;
      int n;
      stride = (stride_sel == 0) ? 32'h0000_1000 : (stride_sel == 1) ? 32'h0000_2000 : 32'h0000_8000;
      n      = (stride_sel == 2) ? 11 : 14;      // more than the ways of L2 (4) and of L3 (8); the L1 is direct mapped
      for (int round = 0; round < 2; round++) begin
        for (int k = 0; k < n; k++) begin
          a = 32'h0000_0040 + k * stride;
          do_store(a, 32'hA5A5_0000 + (stride_sel << 12) + (round << 8) + k, 4'hF);
        end
        for (int k = 0; k < n; k++) do_load(32'h0000_0040 + k * stride);
      end
    end

    // 3. constrained random load/store mix
    for (int i = 0; i < N_RANDOM; i++) begin
      rnd_d(r1); rnd_d(r2); rnd_d(r3);
      a = pick_d_addr(r1, r2);
      if (r1[11:8] < 4'd7) do_load(a);
      else if (r1[11:8] < 4'd8) do_load(I_BASE + ((r2 % ((I_LIMIT - I_BASE) / 4)) * 4));       // read-only data in the fetch region
      else do_store(a, r3, pick_strobe(r1 >> 12));
    end

    // 4. read back a spread of the whole data region
    for (int i = 0; i < 3000; i++) do_load((i * 32'd131) % (D_LIMIT / 4) * 4);
    d_done = 1;
  end

  // ------------------------------------------------------------------ I-port stimulus
  initial begin : i_driver
    logic [31:0] r, a, q;
    int run;
    wait (rst_n === 1'b1);
    repeat (7) @(posedge clk);
    a = I_BASE;
    run = 0;
    for (int i = 0; i < N_FETCH; i++) begin
      rnd_i(r);
      if (run == 0) begin
        a = I_BASE + ((r % ((I_LIMIT - I_BASE) / 4)) * 4);   // jump
        run = 1 + (r[27:24] % 12);
      end else begin
        a = a + 4;
        if (a >= I_LIMIT) a = I_BASE;
        run--;
      end
      i_read(a, q);
      i_fetches++;
      if (q !== ref_word(a)) begin
        fetch_mismatches++;
        if (fetch_mismatches <= 10) begin
          $display("FAIL: fetch 0x%08h returned 0x%08h, expected 0x%08h", a, q, ref_word(a));
          errors++;
        end
      end
      if (r[31:29] == 3'd0) repeat (1 + r[19:17]) @(posedge clk);      // idle gaps
    end
    i_done = 1;
  end

  // ------------------------------------------------------------------ run control
  initial begin
    rst_n = 1'b0;
    repeat (8) @(posedge clk);
    rst_n = 1'b1;
    fork
      begin wait (d_done && i_done); end
      begin
        #20_000_000;
        $display("FAIL: watchdog - the run did not finish (d_loads=%0d d_stores=%0d i_fetches=%0d)", d_loads, d_stores, i_fetches);
        errors++;
      end
    join_any
    repeat (50) @(posedge clk);
    $display("PASS: %0d D loads, all equal to the flat reference memory (%0d mismatches)", d_loads, load_mismatches);
    if (load_mismatches != 0) $display("FAIL: %0d D loads differed from the reference", load_mismatches);
    $display("PASS: %0d instruction fetches (L1-I), all equal to the reference (%0d mismatches)", i_fetches, fetch_mismatches);
    if (fetch_mismatches != 0) $display("FAIL: %0d fetches differed from the reference", fetch_mismatches);
    $display("INFO: %0d D stores issued", d_stores);
    $display("INFO: AXI traffic: %0d read bursts (%0d beats), %0d write bursts (%0d beats)", mem.ar_count, mem.rbeat_count, mem.aw_count, mem.wbeat_count);
    if (mem.proto_errors == 0) $display("PASS: the AXI4 memory model saw no protocol error from the master");
    else begin $display("FAIL: %0d AXI protocol errors", mem.proto_errors); errors++; end
    if (mem_err === 1'b0) $display("PASS: mem_err stayed low"); else begin $display("FAIL: mem_err is set"); errors++; end
    if (mem.aw_count > 0) $display("PASS: dirty lines were evicted all the way to memory (%0d write bursts)", mem.aw_count);
    else begin $display("FAIL: no write burst reached memory, the write-back path was not exercised"); errors++; end
    if (errors == 0) $display("tb_mlc_top: ALL CHECKS PASSED"); else $display("tb_mlc_top: %0d FAILURES", errors);
    $finish;
  end

endmodule
