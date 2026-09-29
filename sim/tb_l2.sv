`timescale 1ns/1ps

module tb_l2;

  localparam int WAYS  = mlc_pkg::L2_WAYS;
  localparam int LINE_W = mlc_pkg::L2_LINE_B * 8;

  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n;

  logic                                  req_valid, req_ready, req_we, resp_valid, resp_ready;
  logic [mlc_pkg::ADDR_W-1:0]             req_addr;
  logic [mlc_pkg::DATA_W-1:0]             req_wdata;
  logic [mlc_pkg::BYTES_PER_WORD-1:0]     req_wstrb;
  logic [LINE_W-1:0]                      resp_line;

  logic                                  dn_req_valid, dn_req_ready, dn_req_we, dn_resp_valid, dn_resp_ready;
  logic [mlc_pkg::ADDR_W-1:0]             dn_req_addr;
  logic [mlc_pkg::DATA_W-1:0]             dn_req_wdata;
  logic [mlc_pkg::BYTES_PER_WORD-1:0]     dn_req_wstrb;
  logic [LINE_W-1:0]                      dn_req_line;
  logic [LINE_W-1:0]                      dn_resp_line;
  logic                                  hold_not_ready = 1'b0;

  int errors = 0;

  l2_cache_ctrl dut (.*);

  l3_stub #(.FILL_LATENCY(3)) l3 (
    .clk(clk), .rst_n(rst_n), .hold_not_ready(hold_not_ready),
    .req_valid(dn_req_valid), .req_ready(dn_req_ready),
    .req_addr(dn_req_addr), .req_we(dn_req_we),
    .req_wdata(dn_req_wdata), .req_wstrb(dn_req_wstrb), .req_line(dn_req_line),
    .resp_valid(dn_resp_valid), .resp_ready(dn_resp_ready), .resp_line(dn_resp_line)
  );

  // Forward-log monitor (Review Focus / Phase 1 lesson): records every downstream write
  // handshake so eviction write-backs are verified at the receiving end, not just by re-reading
  // this module's own array afterward.
  //
  // D-020: a queue of a struct type (packed or unpacked) is rejected by Icarus 12 ("Queue of type
  // ... is not yet supported" / "Unpacked structs not supported"), so the log is kept as two
  // parallel queues pushed/popped together instead of one queue of a {addr,line} struct - same
  // monitor semantics, compilable on this toolchain.
  logic [mlc_pkg::ADDR_W-1:0] fwd_addr_log[$];
  logic [LINE_W-1:0]          fwd_line_log[$];

  always @(posedge clk) begin
    if (dn_req_valid && dn_req_ready && dn_req_we) begin
      fwd_addr_log.push_back(dn_req_addr);
      fwd_line_log.push_back(dn_req_line);
    end
  end

  task automatic check_fwd_one(input logic [mlc_pkg::ADDR_W-1:0] exp_addr,
                                input logic [LINE_W-1:0] exp_line, input string msg);
    logic [mlc_pkg::ADDR_W-1:0] a;
    logic [LINE_W-1:0]          l;
    if (fwd_addr_log.size() != 1) begin
      $display("FAIL: %s (expected exactly 1 write-back, got %0d)", msg, fwd_addr_log.size());
      errors++;
    end else begin
      a = fwd_addr_log.pop_front();
      l = fwd_line_log.pop_front();
      check(a === exp_addr && l === exp_line, msg);
    end
  endtask

  task automatic check_fwd_empty(input string msg);
    check(fwd_addr_log.size() == 0, msg);
  endtask

  function automatic logic [LINE_W-1:0] expected_line(input logic [mlc_pkg::ADDR_W-1:0] addr);
    logic [mlc_pkg::ADDR_W-1:0] line_base;
    expected_line = '0;
    line_base = addr & ~(mlc_pkg::L2_LINE_B - 1);
    for (int w = 0; w < mlc_pkg::L2_LINE_B / mlc_pkg::BYTES_PER_WORD; w++) begin
      expected_line[w*mlc_pkg::DATA_W +: mlc_pkg::DATA_W] = line_base + w;
    end
  endfunction

  task automatic cpu_read(input logic [mlc_pkg::ADDR_W-1:0] addr, output logic [LINE_W-1:0] rline);
    @(posedge clk);
    req_valid <= 1'b1; req_we <= 1'b0; req_addr <= addr;
    resp_ready <= 1'b1;
    wait (req_ready);
    @(posedge clk);
    req_valid <= 1'b0;
    wait (resp_valid);
    rline = resp_line;
    @(posedge clk);
  endtask

  task automatic check(input logic cond, input string msg);
    if (cond) $display("PASS: %s", msg);
    else begin
      $display("FAIL: %s", msg);
      errors++;
    end
  endtask

  initial begin
    req_valid = 0; req_we = 0; req_addr = 0; req_wdata = 0; req_wstrb = 0; resp_ready = 0;
    rst_n = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    check(req_ready === 1'b1, "req_ready is high after reset, before any request");

    begin
      logic [LINE_W-1:0] rline;
      cpu_read(32'h0000_0000, rline);
      check(rline === expected_line(32'h0000_0000), "cold-miss read returns the fetched line");
      check_fwd_empty("a clean cold-miss fill produces no write-back");
    end

    begin
      logic [LINE_W-1:0] rline;
      cpu_read(32'h0000_0000, rline);
      check(rline === expected_line(32'h0000_0000), "repeated hit on address 0 returns the same line");
    end

    begin
      logic [LINE_W-1:0] rline;
      @(posedge clk);
      req_valid <= 1'b1; req_we <= 1'b1; req_addr <= 32'h0000_0000;
      req_wdata <= 32'hDEAD_BEEF; req_wstrb <= 4'b1111; resp_ready <= 1'b1;
      wait (req_ready);
      @(posedge clk);
      req_valid <= 1'b0;
      wait (resp_valid);
      @(posedge clk);
      check_fwd_empty("a write hit never forwards downstream (FR-15, write-back semantics)");
      cpu_read(32'h0000_0000, rline);
      check(rline[0 +: mlc_pkg::DATA_W] === 32'hDEAD_BEEF,
            "write hit then read-back returns the written word (word 0 of the line)");
    end

    if (errors == 0) begin
      $display("** ALL TESTS PASSED **");
      $finish;
    end else begin
      $display("** %0d TEST(S) FAILED **", errors);
      $fatal(1);
    end
  end

  initial begin
    #200000;
    $display("FAIL: simulation watchdog timeout");
    errors++;
    $fatal(1);
  end

endmodule
