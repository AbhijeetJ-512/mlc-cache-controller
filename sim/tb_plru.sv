`timescale 1ns/1ps

module tb_plru;

  localparam int WAYS = 4;
  localparam int SETS = 4; // small SETS for this directed/exhaustive test; Task 2 uses SETS=256

  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n;

  logic [$clog2(SETS)-1:0] set_index;
  logic [$clog2(WAYS)-1:0] victim_way;
  logic                    access_valid;
  logic [$clog2(SETS)-1:0] access_set;
  logic [$clog2(WAYS)-1:0] access_way;

  int errors = 0;

  plru_tree #(.WAYS(WAYS), .SETS(SETS)) dut (.*);

  task automatic check(input logic cond, input string msg);
    if (cond) $display("PASS: %s", msg);
    else begin
      $display("FAIL: %s", msg);
      errors++;
    end
  endtask

  task automatic do_access(input logic [$clog2(SETS)-1:0] s, input logic [$clog2(WAYS)-1:0] w);
    @(posedge clk);
    access_valid <= 1'b1; access_set <= s; access_way <= w;
    @(posedge clk);
    access_valid <= 1'b0;
  endtask

  function automatic logic [1:0] expected_victim_len1(input int a);
    case (a)
      0: expected_victim_len1 = 2'd2;
      1: expected_victim_len1 = 2'd2;
      2: expected_victim_len1 = 2'd0;
      3: expected_victim_len1 = 2'd0;
      default: expected_victim_len1 = 2'd0;
    endcase
  endfunction

  function automatic logic [1:0] expected_victim_len2(input int a, input int b);
    // Verified via an independent Python re-implementation of select_victim/next_state,
    // enumerated exhaustively over all 16 (a,b) pairs - not derived from any true-LRU model.
    // NOTE: a/b are `int` (32-bit) since they come from the enclosing for-loops - take only
    // their low 2 bits before concatenating, or the case expression is 64 bits wide and will
    // never match these 4-bit case items.
    case ({a[1:0], b[1:0]})
      {2'd0,2'd0}: expected_victim_len2 = 2'd2;
      {2'd0,2'd1}: expected_victim_len2 = 2'd2;
      {2'd0,2'd2}: expected_victim_len2 = 2'd1;
      {2'd0,2'd3}: expected_victim_len2 = 2'd1;
      {2'd1,2'd0}: expected_victim_len2 = 2'd2;
      {2'd1,2'd1}: expected_victim_len2 = 2'd2;
      {2'd1,2'd2}: expected_victim_len2 = 2'd0;
      {2'd1,2'd3}: expected_victim_len2 = 2'd0;
      {2'd2,2'd0}: expected_victim_len2 = 2'd3;
      {2'd2,2'd1}: expected_victim_len2 = 2'd3;
      {2'd2,2'd2}: expected_victim_len2 = 2'd0;
      {2'd2,2'd3}: expected_victim_len2 = 2'd0;
      {2'd3,2'd0}: expected_victim_len2 = 2'd2;
      {2'd3,2'd1}: expected_victim_len2 = 2'd2;
      {2'd3,2'd2}: expected_victim_len2 = 2'd0;
      {2'd3,2'd3}: expected_victim_len2 = 2'd0;
      default:     expected_victim_len2 = 2'd0;
    endcase
  endfunction

  initial begin
    access_valid = 0; access_set = 0; access_way = 0; set_index = 0;
    rst_n = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk); #1;

    set_index = 0;
    check(victim_way === 2'd0, "reset: set 0's victim is way0");

    do_access(0, 0); // access way0
    #1;
    set_index = 0;
    check(victim_way === 2'd2, "after accessing way0: set 0's victim is way2");

    do_access(0, 2); // access way2
    #1;
    set_index = 0;
    check(victim_way === 2'd1, "after accessing way0 then way2: set 0's victim is way1 (Phase 0 hand-worked example)");

    // Exhaustive check: every length-1 and length-2 access sequence from reset (all 4 and all
    // 16 respectively - the full state space for this length, not a sample), against the
    // hardcoded, independently-verified expected values above.
    for (int a = 0; a < WAYS; a++) begin
      // length-1 sequences
      @(negedge clk); rst_n = 0; @(negedge clk); rst_n = 1; @(posedge clk); #1;
      do_access(0, a[$clog2(WAYS)-1:0]);
      #1;
      set_index = 0;
      check(victim_way === expected_victim_len1(a),
            $sformatf("exhaustive length-1 [%0d]: victim matches the verified PLRU prediction", a));

      for (int b = 0; b < WAYS; b++) begin
        // length-2 sequences
        @(negedge clk); rst_n = 0; @(negedge clk); rst_n = 1; @(posedge clk); #1;
        do_access(0, a[$clog2(WAYS)-1:0]);
        do_access(0, b[$clog2(WAYS)-1:0]);
        #1;
        set_index = 0;
        check(victim_way === expected_victim_len2(a, b),
              $sformatf("exhaustive length-2 [%0d,%0d]: victim matches the verified PLRU prediction", a, b));
      end
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
    #100000;
    $display("FAIL: simulation watchdog timeout");
    errors++;
    $fatal(1);
  end

endmodule
