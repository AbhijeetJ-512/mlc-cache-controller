`timescale 1ns/1ps

module tb_l1_icache;

  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n;

  logic              req_valid, req_ready, resp_valid, resp_ready;
  logic [mlc_pkg::ADDR_W-1:0] req_addr;
  logic [mlc_pkg::DATA_W-1:0] resp_rdata;

  logic                      dn_req_valid, dn_req_ready, dn_req_we, dn_resp_valid, dn_resp_ready;
  logic [mlc_pkg::ADDR_W-1:0]         dn_req_addr;
  logic [mlc_pkg::DATA_W-1:0]         dn_req_wdata;
  logic [mlc_pkg::BYTES_PER_WORD-1:0] dn_req_wstrb;
  logic [mlc_pkg::L1_LINE_W-1:0]      dn_resp_line;
  logic                      hold_not_ready = 1'b0;

  int errors = 0;

  l1_icache_ctrl dut (.*);

  l1_downstream_stub #(.FILL_LATENCY(3)) l2_stub (
    .clk(clk), .rst_n(rst_n), .hold_not_ready(hold_not_ready),
    .req_valid(dn_req_valid), .req_ready(dn_req_ready),
    .req_addr(dn_req_addr), .req_we(dn_req_we),
    .req_wdata(dn_req_wdata), .req_wstrb(dn_req_wstrb),
    .resp_valid(dn_resp_valid), .resp_ready(dn_resp_ready),
    .resp_line(dn_resp_line)
  );

  function automatic logic [mlc_pkg::DATA_W-1:0] expected_word(input logic [mlc_pkg::ADDR_W-1:0] addr);
    logic [mlc_pkg::ADDR_W-1:0] line_base;
    int word_idx;
    line_base = addr & ~(mlc_pkg::L1_LINE_B - 1);
    word_idx  = (addr - line_base) >> $clog2(mlc_pkg::BYTES_PER_WORD);
    expected_word = line_base + word_idx;
  endfunction

  task automatic cpu_read(input logic [mlc_pkg::ADDR_W-1:0] addr, output logic [mlc_pkg::DATA_W-1:0] rdata);
    @(posedge clk);
    req_valid  <= 1'b1; req_addr <= addr; resp_ready <= 1'b1;
    wait (req_ready);
    @(posedge clk);
    req_valid <= 1'b0;
    wait (resp_valid);
    #1;                       // let resp_rdata settle: on a gate-level netlist it trails resp_valid by a few delta cycles (D-039)
    rdata = resp_rdata;
    @(posedge clk);
  endtask

  task automatic check(input logic cond, input string msg);
    if (cond) $display("PASS: %s", msg);
    else begin
      $display("FAIL: %s", msg);
      errors++;
    end
  endtask

  // Simulation watchdog: bounds any stall regression (every wait() below is otherwise unbounded)
  // to a FAIL line and a nonzero exit instead of a silent hang. The full passing run finishes at
  // 335 ns (sim/logs/tb_l1_icache.log); this 1500 ns limit is ~4.5x that - raise it if new
  // scenarios push the legitimate runtime anywhere near it.
  initial begin
    #1500;
    $display("FAIL: simulation watchdog timeout - a scenario is stuck");
    errors++;
    $fatal(1);
  end

  initial begin
    req_valid = 0; req_addr = 0; resp_ready = 0;
    rst_n = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    check(req_ready === 1'b1, "req_ready is high after reset");

    begin
      logic [mlc_pkg::DATA_W-1:0] rd;
      cpu_read(32'h0000_0000, rd);
      check(rd === expected_word(32'h0000_0000), "cold-miss instruction fetch returns fetched data");
      cpu_read(32'h0000_0000, rd);
      check(rd === expected_word(32'h0000_0000), "repeated instruction fetch hits");
    end

    begin
      logic [mlc_pkg::DATA_W-1:0] rd0, rd1;
      // 0x20 and 0x40 land in distinct sets (index 1 and 2) - see the address-planning note in
      // Task 2 Step 8 for why addresses that are multiples of 0x1000 must not be used here.
      cpu_read(32'h0000_0020, rd0);
      cpu_read(32'h0000_0040, rd1);
      check(rd0 === expected_word(32'h0000_0020) && rd1 === expected_word(32'h0000_0040),
            "back-to-back instruction-fetch misses to different sets both resolve correctly");
    end

    if (errors == 0) begin
      $display("** ALL TESTS PASSED **");
      $finish;
    end else begin
      $display("** %0d TEST(S) FAILED **", errors);
      $fatal(1);
    end
  end
endmodule
