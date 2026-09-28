`timescale 1ns/1ps
module tb_reset_sync;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic async_rst_n;
  logic rst_n;
  int   errors = 0;

  reset_sync dut (.clk(clk), .async_rst_n(async_rst_n), .rst_n(rst_n));

  task automatic check(input logic cond, input string msg);
    if (cond) $display("PASS: %s", msg);
    else begin
      $display("FAIL: %s", msg);
      errors++;
    end
  endtask

  initial begin
    async_rst_n = 1'b0;
    @(posedge clk); #1;
    check(rst_n === 1'b0, "rst_n is low while async_rst_n is held low");

    async_rst_n = 1'b1;
    @(posedge clk); #1;
    check(rst_n === 1'b0, "rst_n still low 1 cycle after async_rst_n deasserts (sync stage 1)");

    @(posedge clk); #1;
    check(rst_n === 1'b1, "rst_n high 2 cycles after async_rst_n deasserts (sync stage 2)");

    async_rst_n = 1'b0;
    #1;
    check(rst_n === 1'b0, "rst_n drops immediately (asynchronously) on re-assertion");

    if (errors == 0) $display("** ALL TESTS PASSED **");
    else $display("** %0d TEST(S) FAILED **", errors);
    $finish;
  end
endmodule
