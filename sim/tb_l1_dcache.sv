`timescale 1ns/1ps
import mlc_pkg::*;

module tb_l1_dcache;

  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n;

  logic                      req_valid, req_ready, req_we, resp_valid, resp_ready;
  logic [ADDR_W-1:0]         req_addr;
  logic [DATA_W-1:0]         req_wdata, resp_rdata;
  logic [BYTES_PER_WORD-1:0] req_wstrb;

  logic                      dn_req_valid, dn_req_ready, dn_req_we, dn_resp_valid, dn_resp_ready;
  logic [ADDR_W-1:0]         dn_req_addr;
  logic [DATA_W-1:0]         dn_req_wdata;
  logic [BYTES_PER_WORD-1:0] dn_req_wstrb;
  logic [L1_LINE_W-1:0]      dn_resp_line;
  logic                      hold_not_ready = 1'b0;

  int errors = 0;

  l1_dcache_ctrl dut (.*);

  l1_downstream_stub #(.FILL_LATENCY(3)) l2_stub (
    .clk(clk), .rst_n(rst_n), .hold_not_ready(hold_not_ready),
    .req_valid(dn_req_valid), .req_ready(dn_req_ready),
    .req_addr(dn_req_addr), .req_we(dn_req_we),
    .req_wdata(dn_req_wdata), .req_wstrb(dn_req_wstrb),
    .resp_valid(dn_resp_valid), .resp_ready(dn_resp_ready),
    .resp_line(dn_resp_line)
  );

  // Matches l1_downstream_stub's line_pattern: word w of the line containing
  // `addr` equals (line-base address of addr) + w.
  function automatic logic [DATA_W-1:0] expected_word(input logic [ADDR_W-1:0] addr);
    logic [ADDR_W-1:0] line_base;
    int word_idx;
    line_base = addr & ~(L1_LINE_B - 1);
    word_idx  = (addr - line_base) >> 2;
    expected_word = line_base + word_idx;
  endfunction

  task automatic cpu_read(input logic [ADDR_W-1:0] addr, output logic [DATA_W-1:0] rdata);
    @(posedge clk);
    req_valid  <= 1'b1; req_we <= 1'b0; req_addr <= addr;
    resp_ready <= 1'b1;
    wait (req_ready);
    @(posedge clk);
    req_valid <= 1'b0;
    wait (resp_valid);
    rdata = resp_rdata;
    @(posedge clk);
  endtask

  task automatic cpu_write(input logic [ADDR_W-1:0] addr, input logic [DATA_W-1:0] wdata,
                            input logic [BYTES_PER_WORD-1:0] wstrb);
    @(posedge clk);
    req_valid  <= 1'b1; req_we <= 1'b1; req_addr <= addr;
    req_wdata  <= wdata; req_wstrb <= wstrb;
    resp_ready <= 1'b1;
    wait (req_ready);
    @(posedge clk);
    req_valid <= 1'b0;
    wait (resp_valid);
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
      logic [DATA_W-1:0] rd;
      cpu_read(32'h0000_0000, rd);
      check(rd === expected_word(32'h0000_0000), "cold-miss read returns the fetched data");
    end

    begin
      logic [DATA_W-1:0] rd;
      cpu_read(32'h0000_0000, rd);
      check(rd === expected_word(32'h0000_0000), "repeated hit on address 0 returns the same data");
    end

    begin
      logic [DATA_W-1:0] rd;
      cpu_read(32'h0000_0020, rd); // install this line first (cold miss) so the next write is a HIT
      check(rd === expected_word(32'h0000_0020), "address 0x20 installed via cold miss");
      cpu_write(32'h0000_0020, 32'hDEAD_BEEF, 4'b1111);
      check(dut.u_core.wr_fwd_pending === 1'b0,
            "write-forward skid register never occupied when L2 is always ready");
      cpu_read(32'h0000_0020, rd);
      check(rd === 32'hDEAD_BEEF, "write hit then read-back returns the written value");
    end

    begin
      logic [DATA_W-1:0] rd;
      cpu_write(32'h0000_0020, 32'h0000_00FF, 4'b0001); // byte 0 only
      cpu_read(32'h0000_0020, rd);
      check(rd === 32'hDEAD_BEFF, "byte-enable write updates only the selected byte");
    end

    begin
      logic [DATA_W-1:0] rd;
      logic saw_write_fwd;
      saw_write_fwd = 1'b0;
      fork
        begin
          cpu_write(32'h0000_0040, 32'hCAFE_F00D, 4'b1111);
          cpu_read(32'h0000_0040, rd);
          check(rd === 32'hCAFE_F00D, "write miss installs the line locally with the write applied");
        end
        begin: wait_write_fwd
          repeat (20) begin
            @(posedge clk);
            if (dn_req_valid && dn_req_we && dn_req_addr === 32'h0000_0040) saw_write_fwd = 1'b1;
          end
        end
      join
      check(saw_write_fwd, "write-miss eventually forwards the write downstream too");
    end

    begin
      logic [DATA_W-1:0] rd;
      cpu_read(32'h0000_0060, rd);
      check(rd === expected_word(32'h0000_0060), "address 0x60 installed via cold miss");

      @(posedge clk);
      req_valid <= 1'b1; req_we <= 1'b0; req_addr <= 32'h0000_0060; resp_ready <= 1'b0;
      repeat (4) begin
        @(posedge clk);
        check(req_ready === 1'b0,
              "req_ready drops on a would-be hit while resp_ready is low (response not lost)");
      end
      resp_ready <= 1'b1;
      @(posedge clk);
      wait (resp_valid);
      rd = resp_rdata;
      check(rd === expected_word(32'h0000_0060),
            "delayed resp_ready still yields the correct hit data once accepted");
      req_valid <= 1'b0;
      @(posedge clk);
    end

    begin
      logic [DATA_W-1:0] rd;
      // L1_SETS * L1_LINE_B = 128 * 32 = 4096 = exactly one alias stride: same index, different tag.
      cpu_read(32'h0000_0000, rd);
      check(rd === expected_word(32'h0000_0000), "baseline: original line present before aliasing");
      cpu_read(32'h0000_0000 + (L1_SETS * L1_LINE_B), rd);
      check(rd === expected_word(32'h0000_0000 + (L1_SETS * L1_LINE_B)),
            "aliasing address (same index, different tag) misses and installs correctly");
      cpu_read(32'h0000_0000, rd);
      check(rd === expected_word(32'h0000_0000),
            "original line was evicted by the alias and must miss again on re-access");
    end

    if (errors == 0) $display("** ALL TESTS PASSED **");
    else $display("** %0d TEST(S) FAILED **", errors);
    $finish;
  end
endmodule
