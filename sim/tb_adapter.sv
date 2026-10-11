`timescale 1ns/1ps

// Tier-1 test of l2_l3_width_adapter. The adapter is pure wiring plus a half select, so the test
// applies inputs, waits a delta, and compares every output against a value written here.
module tb_adapter;

  localparam int L2_LINE_B = 32;
  localparam int L3_LINE_B = 64;
  localparam int L2_W = L2_LINE_B * 8;
  localparam int L3_W = L3_LINE_B * 8;

  logic                  l2_req_valid = 1'b0, l2_req_we = 1'b0, l2_resp_ready = 1'b0;
  logic [31:0]           l2_req_addr = '0;
  logic [L2_W-1:0]       l2_req_line = '0;
  wire                   l2_req_ready, l2_resp_valid;
  wire  [L2_W-1:0]       l2_resp_line;

  wire                   l3_req_valid, l3_req_we, l3_resp_ready;
  wire  [31:0]           l3_req_addr;
  wire  [L2_W-1:0]       l3_req_wdata;
  wire  [L2_LINE_B-1:0]  l3_req_wstrb;
  logic                  l3_req_ready = 1'b0, l3_resp_valid = 1'b0;
  logic [L3_W-1:0]       l3_resp_line = '0;

  int errors = 0;

  l2_l3_width_adapter dut (.*);

  task automatic check(input logic cond, input string msg);
    if (cond) $display("PASS: %s", msg);
    else begin
      $display("FAIL: %s", msg);
      errors++;
    end
  endtask

  function automatic logic [L2_W-1:0] pat(input logic [7:0] seed);
    for (int k = 0; k < L2_LINE_B; k++)
      pat[k*8 +: 8] = seed + k[7:0];
  endfunction

  logic [31:0] addrs [0:7];

  initial begin
    addrs[0] = 32'h0000_0000;   // half 0
    addrs[1] = 32'h0000_0020;   // half 1
    addrs[2] = 32'h0001_0040;   // half 0, other tag/index bits
    addrs[3] = 32'h0001_0060;   // half 1
    addrs[4] = 32'hFFFF_FFC0;   // half 0, top of the address space
    addrs[5] = 32'hFFFF_FFE0;   // half 1
    addrs[6] = 32'h1234_5FBF;   // 0xBF = 1011_1111: bit 5 set, offset bits all ones: half 1
    addrs[7] = 32'h1234_5F9F;   // 0x9F = 1001_1111: bit 5 clear, offset bits all ones: half 0
    #1;

    // ---- fill direction: L2 gets only the half its address names ----
    l3_resp_line = {pat(8'hB0), pat(8'hA0)};   // upper half = B0.., lower half = A0..
    for (int i = 0; i < 8; i++) begin
      l2_req_addr = addrs[i];
      #1;
      if (addrs[i][5])
        check(l2_resp_line === pat(8'hB0), $sformatf("address 0x%08h (bit 5 set) gets the upper half", addrs[i]));
      else
        check(l2_resp_line === pat(8'hA0), $sformatf("address 0x%08h (bit 5 clear) gets the lower half", addrs[i]));
    end

    // ---- the half follows the line contents, not a fixed slice ----
    l3_resp_line = {pat(8'h31), pat(8'h21)};
    l2_req_addr = 32'h0000_0020; #1;
    check(l2_resp_line === pat(8'h31), "upper half tracks a new L3 line");
    l2_req_addr = 32'h0000_0000; #1;
    check(l2_resp_line === pat(8'h21), "lower half tracks a new L3 line");

    // ---- every bit of each half can be 1 and can be 0 while the other half is the opposite, under either select ----
    // (added after a stuck-at campaign on the synthesised adapter, D-039: pat() gives each bit one value per test, which
    // cannot show a fault inside the 256 two-way multiplexers)
    for (int u = 0; u < 2; u++) begin
      l3_resp_line = u ? {{L2_W{1'b1}}, {L2_W{1'b0}}} : {{L2_W{1'b0}}, {L2_W{1'b1}}};
      l2_req_addr = 32'h0000_0020; #1;
      check(l2_resp_line === (u ? {L2_W{1'b1}} : {L2_W{1'b0}}),
            $sformatf("upper half all %0d, lower half the opposite: the upper half is passed", u));
      l2_req_addr = 32'h0000_0000; #1;
      check(l2_resp_line === (u ? {L2_W{1'b0}} : {L2_W{1'b1}}),
            $sformatf("upper half all %0d, lower half the opposite: the lower half is passed", u));
    end

    // ---- handshakes pass straight through, in every combination ----
    for (int v = 0; v < 16; v++) begin
      l2_req_valid  = v[0];
      l3_req_ready  = v[1];
      l3_resp_valid = v[2];
      l2_resp_ready = v[3];
      #1;
      check(l3_req_valid === v[0] && l2_req_ready === v[1] && l2_resp_valid === v[2] && l3_resp_ready === v[3],
            $sformatf("handshake combination %b passes through unchanged", v[3:0]));
    end

    // ---- write-back direction: one posted half-line write, strobes all ones ----
    for (int i = 0; i < 8; i++) begin
      l2_req_valid = 1'b1; l2_req_we = 1'b1;
      l2_req_addr  = addrs[i];
      l2_req_line  = pat(8'h40 + i[7:0]);
      #1;
      check(l3_req_we === 1'b1 && l3_req_addr === addrs[i] && l3_req_wdata === pat(8'h40 + i[7:0]) &&
            l3_req_wstrb === {L2_LINE_B{1'b1}},
            $sformatf("write-back to 0x%08h: data, address, WE and all-ones strobes pass through", addrs[i]));
    end

    // ---- every bit of the write-back data can be 1 and can be 0 ----
    // (added after the independent review of Phase 7, D-040: pat() above gives bit 6 of every byte only the value 1 here, and
    // the write-back data is wiring, so no cell-level test can see a masked or forced bit)
    for (int u = 0; u < 2; u++) begin
      l2_req_valid = 1'b1; l2_req_we = 1'b1;
      l2_req_addr  = 32'h0000_0000;
      l2_req_line  = u ? {L2_W{1'b1}} : {L2_W{1'b0}};
      #1;
      check(l3_req_wdata === (u ? {L2_W{1'b1}} : {L2_W{1'b0}}),
            $sformatf("write-back data with every bit %0d reaches L3 unchanged", u));
    end

    // ---- a read request is not turned into a write ----
    l2_req_we = 1'b0; #1;
    check(l3_req_we === 1'b0, "a read request reaches L3 as a read");

    if (errors == 0) begin
      $display("** ALL TESTS PASSED **");
      $finish;
    end else begin
      $display("** %0d TEST(S) FAILED **", errors);
      $fatal(1);
    end
  end

  initial begin
    #100000;
    $display("FAIL: simulation watchdog timeout");
    errors++;
    $fatal(1);
  end

endmodule
