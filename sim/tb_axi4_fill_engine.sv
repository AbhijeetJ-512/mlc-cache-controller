`timescale 1ns/1ps

// Tier-1 test of axi4_fill_engine alone, against axi_mem_model. The expected burst shape is
// written here as literals (15 beats of 4 bytes, INCR, 64 B aligned), not derived from the DUT.
module tb_axi4_fill_engine;

  localparam int LINE_B = 64;
  localparam int LINE_W = LINE_B * 8;

  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n;

  logic                          req_valid = 1'b0, req_we = 1'b0, resp_ready = 1'b0;
  wire                           req_ready, resp_valid, mem_err;
  logic [31:0]                   req_addr = '0;
  logic [LINE_W-1:0]             req_line = '0;
  wire  [LINE_W-1:0]             resp_line;

  wire [31:0] awaddr, araddr;
  wire [7:0]  awlen, arlen;
  wire [2:0]  awsize, arsize;
  wire [1:0]  awburst, arburst, bresp, rresp;
  wire        awvalid, awready, wlast, wvalid, wready, bvalid, bready, arvalid, arready, rlast, rvalid, rready;
  wire [31:0] wdata, rdata;
  wire [3:0]  wstrb;

  logic       stall_ar = 1'b0, stall_aw = 1'b0, stall_w = 1'b0;
  logic [3:0] r_gap = 4'd0;
  logic [1:0] force_rresp = 2'b00, force_bresp = 2'b00;

  int errors = 0;

  axi4_fill_engine dut (.*);

  axi_mem_model #(.DATA_W(32), .EXP_LEN(15), .EXP_SIZE(2), .EXP_ALIGN_B(64)) axi (.*);

  task automatic check(input logic cond, input string msg);
    if (cond) $display("PASS: %s", msg);
    else begin
      $display("FAIL: %s", msg);
      errors++;
    end
  endtask

  // What the model's initial image holds for the line starting at byte address a.
  function automatic logic [LINE_W-1:0] image_line(input logic [31:0] a);
    for (int k = 0; k < LINE_B / 4; k++)
      image_line[k*32 +: 32] = 32'hC0DE_0000 + (a / 4) + k;
  endfunction

  function automatic logic [LINE_W-1:0] test_line(input logic [7:0] seed);
    for (int k = 0; k < LINE_B; k++)
      test_line[k*8 +: 8] = seed + k[7:0];
  endfunction

  function automatic logic mem_matches(input logic [31:0] a, input logic [LINE_W-1:0] expect_line);
    mem_matches = 1'b1;
    for (int k = 0; k < LINE_B / 4; k++)
      if (axi.mem[(a / 4) + k] !== expect_line[k*32 +: 32]) mem_matches = 1'b0;
  endfunction

  task automatic reset_pulse();
    rst_n <= 1'b0;
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    @(posedge clk);
  endtask

  // Issue one request and wait for the engine to take it. resp_ready is left to the caller.
  task automatic issue(input logic [31:0] a, input logic we, input logic [LINE_W-1:0] line);
    @(posedge clk);
    req_valid <= 1'b1; req_we <= we; req_addr <= a; req_line <= line;
    wait (req_ready);
    @(posedge clk);
    req_valid <= 1'b0;
    req_addr  <= 32'hFFFF_FFFF; req_line <= 'x; req_we <= 1'bx;
    #1; // let the engine's state update land before the caller samples anything
  endtask

  task automatic do_read(input logic [31:0] a, output logic [LINE_W-1:0] line);
    resp_ready <= 1'b1;
    issue(a, 1'b0, '0);
    wait (resp_valid);
    line = resp_line;
    @(posedge clk);
    wait (req_ready);
  endtask

  task automatic do_write(input logic [31:0] a, input logic [LINE_W-1:0] line);
    resp_ready <= 1'b1;
    issue(a, 1'b1, line);
    wait (req_ready);
  endtask

  logic [LINE_W-1:0] got;
  int ar0, aw0;

  initial begin
    rst_n = 1'b0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    check(req_ready === 1'b1, "idle after reset: req_ready is high");
    check(mem_err === 1'b0, "idle after reset: mem_err is low");

    // ---- read: one AR burst, line assembled in order ----
    do_read(32'h0000_1000, got);
    check(got === image_line(32'h0000_1000), "read returns the 16 beats in address order");
    check(axi.ar_count == 1 && axi.aw_count == 0, "a read issues exactly one AR burst and no AW burst");
    check(axi.rbeat_count == 16, "a read collects exactly 16 R beats");
    check(axi.proto_errors == 0, "read burst shape is LEN 15, SIZE 2, INCR, 64 B aligned");

    // ---- read response is held until resp_ready ----
    resp_ready <= 1'b0;
    issue(32'h0000_1040, 1'b0, '0);
    check(req_ready === 1'b0, "req_ready is low while a read is in flight");
    wait (resp_valid);
    repeat (3) begin
      @(posedge clk);
      check(resp_valid === 1'b1 && resp_line === image_line(32'h0000_1040),
            "read response is held, stable, until resp_ready");
    end
    resp_ready <= 1'b1;
    @(posedge clk);
    wait (req_ready);
    check(req_ready === 1'b1, "req_ready returns after the response is taken");

    // ---- write: one AW burst, posted (no response), memory updated ----
    ar0 = axi.ar_count; aw0 = axi.aw_count;
    resp_ready <= 1'b1;
    issue(32'h0000_2040, 1'b1, test_line(8'h11));
    check(req_ready === 1'b0, "req_ready is low while a write is in flight");
    begin
      bit saw_resp;
      saw_resp = 1'b0;
      while (!req_ready) begin
        @(posedge clk);
        if (resp_valid) saw_resp = 1'b1;
      end
      check(!saw_resp, "a write is posted: resp_valid never rises");
    end
    check(axi.aw_count == aw0 + 1 && axi.ar_count == ar0, "a write issues exactly one AW burst and no AR burst");
    check(axi.wbeat_count == 16, "a write sends exactly 16 W beats");
    check(mem_matches(32'h0000_2040, test_line(8'h11)), "write data reached memory in address order");
    check(axi.proto_errors == 0, "write burst shape, WSTRB and WLAST are correct");

    // ---- write then read back ----
    do_read(32'h0000_2040, got);
    check(got === test_line(8'h11), "a line written and read back round-trips");

    // ---- backpressure: AR, R gaps, AW and W (the write response is delayed further below) ----
    stall_ar <= 1'b1; r_gap <= 4'd3;
    resp_ready <= 1'b1;
    issue(32'h0000_3000, 1'b0, '0);
    repeat (6) @(posedge clk);
    stall_ar <= 1'b0;
    wait (resp_valid);
    check(resp_line === image_line(32'h0000_3000), "read is correct with ARREADY stalled and gaps between R beats");
    @(posedge clk);
    wait (req_ready);
    r_gap <= 4'd0;

    stall_aw <= 1'b1; stall_w <= 1'b1;
    issue(32'h0000_3040, 1'b1, test_line(8'h55));
    repeat (6) @(posedge clk);
    stall_aw <= 1'b0;
    repeat (6) @(posedge clk);
    stall_w <= 1'b0;
    wait (req_ready);
    check(mem_matches(32'h0000_3040, test_line(8'h55)), "write is correct with AWREADY and WREADY stalled");
    check(axi.proto_errors == 0, "no protocol violation under backpressure (VALID and payload held)");

    // ---- error responses latch a sticky mem_err ----
    force_rresp <= 2'b10;
    do_read(32'h0000_4000, got);
    force_rresp <= 2'b00;
    check(got === image_line(32'h0000_4000), "a read with SLVERR still returns its data");
    check(mem_err === 1'b1, "SLVERR on a read sets mem_err");
    do_read(32'h0000_4040, got);
    check(mem_err === 1'b1, "mem_err stays set across later good transactions");
    reset_pulse();
    check(mem_err === 1'b0, "reset clears mem_err");

    force_bresp <= 2'b11;
    do_write(32'h0000_4080, test_line(8'h77));
    force_bresp <= 2'b00;
    check(mem_err === 1'b1, "DECERR on a write response sets mem_err");
    reset_pulse();

    // ---- the write response is waited for, and each error source is seen on its own ----
    // (final review: with BVALID the cycle after the last W beat, an engine that never waits for it,
    // and every error test that forced one code on every beat, passed.)
    axi.b_delay = 4;
    resp_ready <= 1'b1;
    issue(32'h0000_6000, 1'b1, test_line(8'h21));
    wait (axi.wstate == axi.W_RESP);
    repeat (3) begin
      @(posedge clk); #1;
      check(dut.state === dut.S_B && req_ready === 1'b0 && bvalid === 1'b0,
            "a write is not finished while BVALID is still held off");
    end
    wait (req_ready);
    axi.b_delay = 0;
    check(mem_matches(32'h0000_6000, test_line(8'h21)), "the write with a delayed response reached memory");
    check(mem_err === 1'b0, "a delayed but good write response is no error");

    force_bresp <= 2'b10;
    do_write(32'h0000_6040, test_line(8'h31));
    force_bresp <= 2'b00;
    check(mem_err === 1'b1, "SLVERR on a write response sets mem_err");
    do_write(32'h0000_6080, test_line(8'h41));
    check(mem_err === 1'b1, "a good write response after an error does not clear mem_err");
    reset_pulse();

    force_rresp <= 2'b11;
    do_read(32'h0000_60C0, got);
    force_rresp <= 2'b00;
    check(mem_err === 1'b1, "DECERR on a read sets mem_err");
    reset_pulse();

    axi.rresp_err_beat = 7;
    do_read(32'h0000_6100, got);
    axi.rresp_err_beat = -1;
    check(mem_err === 1'b1, "an error on the middle beat of a read, and only that beat, sets mem_err");
    check(got === image_line(32'h0000_6100), "that read still returns all of its data");
    reset_pulse();
    axi.rresp_err_beat = 15;
    do_read(32'h0000_6140, got);
    axi.rresp_err_beat = -1;
    check(mem_err === 1'b1, "an error on the last beat of a read alone sets mem_err");
    reset_pulse();
    axi.rresp_err_beat = 0;
    do_read(32'h0000_6180, got);
    axi.rresp_err_beat = -1;
    check(mem_err === 1'b1, "an error on the first beat of a read alone sets mem_err");
    reset_pulse();

    axi.rlast_mode = 1;
    do_read(32'h0000_61C0, got);
    axi.rlast_mode = 0;
    check(mem_err === 1'b1, "a read whose last beat lacks RLAST sets mem_err");
    check(got === image_line(32'h0000_61C0), "and still returns its data, taken by the beat count");
    reset_pulse();

    axi.rlast_mode = 2;
    resp_ready <= 1'b1;
    issue(32'h0000_6200, 1'b0, '0);
    repeat (40) @(posedge clk);
    axi.rlast_mode = 0;
    check(mem_err === 1'b1, "RLAST on a beat before the last sets mem_err");
    // What the engine does next is not pinned: it counts beats and has no timeout, so a slave that
    // ends a burst early leaves it waiting for beats that never come (see D-027). The reset below
    // is what recovers it.
    reset_pulse();
    check(mem_err === 1'b0, "reset clears the error again");

    // ---- AW and W are independent channels (D-032, AXI4 A3.3.1) ----
    // A slave may hold AWREADY back until it sees WVALID, or take the whole W burst before the AW.
    // A master that waits for AWREADY before raising WVALID hangs against the first, and one that
    // stops when W is done without waiting for AW hangs against the second.
    axi.aw_mode = 1;
    do_write(32'h0000_6300, test_line(8'h51));
    check(mem_matches(32'h0000_6300, test_line(8'h51)), "a write completes against a slave that waits for WVALID before AWREADY");
    axi.aw_mode = 2;
    stall_aw <= 1'b1;
    issue(32'h0000_6340, 1'b1, test_line(8'h61));
    repeat (40) @(posedge clk);
    #1;
    check(axi.wstate === axi.W_AWAIT && dut.state === dut.S_WR && awvalid === 1'b1 && wvalid === 1'b0,
          "all 16 W beats were taken while AW was still held off, and the engine keeps AW up");
    stall_aw <= 1'b0;
    wait (req_ready);
    axi.aw_mode = 0;
    check(mem_matches(32'h0000_6340, test_line(8'h61)), "the write whose W burst came first reached memory at the right address");
    check(axi.proto_errors == 0, "no protocol violation with either write-channel ordering");
    // Same orderings with W stalled and a delayed response: both channels finish in either order.
    axi.aw_mode = 1; axi.b_delay = 3; stall_w <= 1'b1;
    issue(32'h0000_6380, 1'b1, test_line(8'h71));
    repeat (12) @(posedge clk);
    stall_w <= 1'b0;
    wait (req_ready);
    axi.aw_mode = 0; axi.b_delay = 0;
    check(mem_matches(32'h0000_6380, test_line(8'h71)), "a write with W stalled behind an AW-waits-for-WVALID slave completes");

    // ---- reset in the middle of a burst ----
    r_gap <= 4'd2;
    issue(32'h0000_5000, 1'b0, '0);
    wait (dut.state === dut.S_R);
    repeat (3) @(posedge clk);
    rst_n <= 1'b0;
    repeat (2) @(posedge clk);
    rst_n <= 1'b1;
    r_gap <= 4'd0;
    @(posedge clk); #1;
    check(dut.state === dut.S_IDLE && req_ready === 1'b1, "reset mid-read returns the engine to idle");
    do_read(32'h0000_5040, got);
    check(got === image_line(32'h0000_5040), "the engine works normally after a reset mid-burst");

    check(axi.proto_errors == 0, "no protocol violation anywhere in the run");

    if (errors == 0) begin
      $display("** ALL TESTS PASSED **");
      $finish;
    end else begin
      $display("** %0d TEST(S) FAILED **", errors);
      $fatal(1);
    end
  end

  initial begin
    #500000;
    $display("FAIL: simulation watchdog timeout");
    errors++;
    $fatal(1);
  end

endmodule
