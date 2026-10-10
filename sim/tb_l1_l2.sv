`timescale 1ns/1ps

// Boundary-contract test: the real L1 data cache wired straight to the real L2 controller (and a
// behavioural L3 stub below it). This is NOT a test of the integrated hierarchy - that stays with
// the Tier-2 UVM environment (D-013). It exists because both D-021 bugs lived on this one
// boundary and were invisible to every single-module test: the L1 forwards writes as posted, and
// an L2 that answered them like reads either deadlocked L1 or left a stale response that a later,
// unrelated L1 fill picked up as its own data.
module tb_l1_l2;

  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n;       // resets L1 and the stub
  logic rst_n_l2;    // resets L2 alone, so L1 can keep a line that L2 has forgotten
  int errors = 0;

  // CPU side of L1
  logic                              req_valid = 1'b0, req_we = 1'b0, resp_ready = 1'b1;
  logic [mlc_pkg::ADDR_W-1:0]        req_addr = '0;
  logic [mlc_pkg::DATA_W-1:0]        req_wdata = '0;
  logic [mlc_pkg::BYTES_PER_WORD-1:0] req_wstrb = '0;
  wire                               req_ready, resp_valid;
  wire  [mlc_pkg::DATA_W-1:0]        resp_rdata;

  // L1 downstream == L2 upstream
  wire                               l1_dn_req_valid, l1_dn_req_ready, l1_dn_req_we, l1_dn_resp_valid, l1_dn_resp_ready;
  wire  [mlc_pkg::ADDR_W-1:0]        l1_dn_req_addr;
  wire  [mlc_pkg::DATA_W-1:0]        l1_dn_req_wdata;
  wire  [mlc_pkg::BYTES_PER_WORD-1:0] l1_dn_req_wstrb;
  wire  [mlc_pkg::L2_LINE_B*8-1:0]   l2_resp_line;

  // L2 downstream == stub
  wire                               l2_dn_req_valid, l2_dn_req_ready, l2_dn_req_we, l2_dn_resp_valid, l2_dn_resp_ready;
  wire  [mlc_pkg::ADDR_W-1:0]        l2_dn_req_addr;
  wire  [mlc_pkg::DATA_W-1:0]        l2_dn_req_wdata;
  wire  [mlc_pkg::BYTES_PER_WORD-1:0] l2_dn_req_wstrb;
  wire  [mlc_pkg::L2_LINE_B*8-1:0]   l2_dn_req_line, l2_dn_resp_line;

  l1_dcache_ctrl l1 (
    .clk, .rst_n, .req_valid, .req_ready, .req_addr, .req_we, .req_wdata, .req_wstrb,
    .resp_valid, .resp_ready, .resp_rdata,
    .dn_req_valid(l1_dn_req_valid), .dn_req_ready(l1_dn_req_ready), .dn_req_addr(l1_dn_req_addr),
    .dn_req_we(l1_dn_req_we), .dn_req_wdata(l1_dn_req_wdata), .dn_req_wstrb(l1_dn_req_wstrb),
    .dn_resp_valid(l1_dn_resp_valid), .dn_resp_ready(l1_dn_resp_ready), .dn_resp_line(l2_resp_line)
  );

  l2_cache_ctrl l2 (
    .clk, .rst_n(rst_n_l2),
    .req_valid(l1_dn_req_valid), .req_ready(l1_dn_req_ready), .req_addr(l1_dn_req_addr),
    .req_we(l1_dn_req_we), .req_wdata(l1_dn_req_wdata), .req_wstrb(l1_dn_req_wstrb),
    .resp_valid(l1_dn_resp_valid), .resp_ready(l1_dn_resp_ready), .resp_line(l2_resp_line),
    .dn_req_valid(l2_dn_req_valid), .dn_req_ready(l2_dn_req_ready), .dn_req_addr(l2_dn_req_addr),
    .dn_req_we(l2_dn_req_we), .dn_req_wdata(l2_dn_req_wdata), .dn_req_wstrb(l2_dn_req_wstrb),
    .dn_req_line(l2_dn_req_line), .dn_resp_valid(l2_dn_resp_valid), .dn_resp_ready(l2_dn_resp_ready),
    .dn_resp_line(l2_dn_resp_line)
  );

  l3_stub mem (
    .clk, .rst_n, .hold_not_ready(1'b0),
    .req_valid(l2_dn_req_valid), .req_ready(l2_dn_req_ready), .req_addr(l2_dn_req_addr),
    .req_we(l2_dn_req_we), .req_wdata(l2_dn_req_wdata), .req_wstrb(l2_dn_req_wstrb), .req_line(l2_dn_req_line),
    .resp_valid(l2_dn_resp_valid), .resp_ready(l2_dn_resp_ready), .resp_line(l2_dn_resp_line)
  );

  task automatic check(input logic cond, input string msg);
    if (cond) $display("PASS: %s", msg);
    else begin
      $display("FAIL: %s", msg);
      errors++;
    end
  endtask

  // l3_stub's memory image: word w of the line at a holds (line_base + w).
  function automatic logic [31:0] image_word(input logic [31:0] a);
    image_word = (a & ~(mlc_pkg::L2_LINE_B - 1)) + ((a % mlc_pkg::L2_LINE_B) / 4);
  endfunction

  // Wait for L1 to accept the next request again, or give up: a hang here is the D-021 deadlock.
  task automatic wait_ready_or_fail(input string what);
    int n;
    n = 0;
    while (req_ready !== 1'b1 && n < 200) begin
      @(posedge clk);
      n++;
    end
    check(req_ready === 1'b1, {what, ": L1 accepts the next request again (no deadlock)"});
  endtask

  task automatic cpu_read(input logic [31:0] addr, output logic [31:0] data);
    @(posedge clk);
    req_valid <= 1'b1; req_we <= 1'b0; req_addr <= addr; resp_ready <= 1'b1;
    wait (req_ready);
    @(posedge clk);
    req_valid <= 1'b0;
    wait (resp_valid);
    data = resp_rdata;
    @(posedge clk);
  endtask

  task automatic cpu_write(input logic [31:0] addr, input logic [31:0] data);
    @(posedge clk);
    req_valid <= 1'b1; req_we <= 1'b1; req_addr <= addr; req_wdata <= data; req_wstrb <= 4'hF; resp_ready <= 1'b1;
    wait (req_ready);
    @(posedge clk);
    req_valid <= 1'b0;
  endtask

  localparam logic [31:0] X = 32'h0000_1000;   // L1 set 0
  localparam logic [31:0] Y = 32'h0000_0040;   // L1 set 2
  localparam logic [31:0] Z = 32'h0000_2000;   // L1 set 0 again: evicts X from L1

  logic [31:0] got;

  initial begin
    rst_n = 1'b0; rst_n_l2 = 1'b0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1; rst_n_l2 = 1'b1;
    @(posedge clk);

    // ---- read path: L1 miss, L2 miss, stub; then an L1 hit ----
    cpu_read(X, got);
    check(got === image_word(X), "cold read through L1 and L2 returns the stub's word");
    cpu_read(X, got);
    check(got === image_word(X), "the same word again is an L1 hit");

    // ---- D-021 case 1: a forwarded write that HITS in L2 must not deadlock L1 ----
    cpu_write(X, 32'hA5A5_0001);
    wait_ready_or_fail("write forwarded to an L2 hit");
    cpu_read(X, got);
    check(got === 32'hA5A5_0001, "the written word reads back from L1");

    // ---- D-021 case 2: a forwarded write that MISSES in L2 must not poison a later fill ----
    // Reset L2 alone: L1 still holds X, L2 has forgotten it, so the next write to X is an L2 write miss.
    rst_n_l2 = 1'b0;
    repeat (3) @(posedge clk);
    rst_n_l2 = 1'b1;
    @(posedge clk);
    cpu_write(X, 32'hB6B6_0002);
    wait_ready_or_fail("write forwarded to an L2 miss");
    // An unrelated L1 miss now takes a fill from L2. It must get Y's data, not the write-allocate's.
    cpu_read(Y, got);
    check(got === image_word(Y), "an unrelated fill after a forwarded L2 write-miss returns its own data");

    // ---- the write-allocated word is really in L2: evict X from L1, re-read it ----
    cpu_read(Z, got);
    check(got === image_word(Z), "a conflicting line evicts X from L1");
    cpu_read(X, got);
    check(got === 32'hB6B6_0002, "X refilled from L2 carries the word the L2 write-allocate merged");

    // ---- D-021 case 3: two forwarded writes in a row, both missing in L2, must not stall L1 ----
    // Kept separate from case 2 so each scenario keeps its own timing: here there is no fill in
    // between. If L2 waited for a response nobody will give (L1 only raises dn_resp_ready during
    // its own fills) it would sit in S_UPDATE_TAG and refuse the second forward, and L1 - stalled on
    // that forward - could never start a fill to release it.
    rst_n_l2 = 1'b0;                 // L1 holds X and Y; L2 forgets both
    repeat (3) @(posedge clk);
    rst_n_l2 = 1'b1;
    @(posedge clk);
    cpu_write(X, 32'hC7C7_0003);
    cpu_write(Y, 32'hD8D8_0004);
    wait_ready_or_fail("two back-to-back writes forwarded to L2 misses");
    cpu_read(Z, got);                // evicts X from L1
    cpu_read(32'h0000_1040, got);    // evicts Y from L1 (same L1 set as Y, 0x40)
    cpu_read(X, got);
    check(got === 32'hC7C7_0003, "the first write-allocated word is in L2");
    cpu_read(Y, got);
    check(got === 32'hD8D8_0004, "the second write-allocated word is in L2");

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
