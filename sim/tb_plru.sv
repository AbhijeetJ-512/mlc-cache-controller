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
