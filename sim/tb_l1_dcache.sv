`timescale 1ns/1ps

module tb_l1_dcache;

  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n;

  logic                      req_valid, req_ready, req_we, resp_valid, resp_ready;
  logic [mlc_pkg::ADDR_W-1:0]         req_addr;
  logic [mlc_pkg::DATA_W-1:0]         req_wdata, resp_rdata;
  logic [mlc_pkg::BYTES_PER_WORD-1:0] req_wstrb;

  logic                      dn_req_valid, dn_req_ready, dn_req_we, dn_resp_valid, dn_resp_ready;
  logic [mlc_pkg::ADDR_W-1:0]         dn_req_addr;
  logic [mlc_pkg::DATA_W-1:0]         dn_req_wdata;
  logic [mlc_pkg::BYTES_PER_WORD-1:0] dn_req_wstrb;
  logic [mlc_pkg::L1_LINE_W-1:0]      dn_resp_line;
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
  function automatic logic [mlc_pkg::DATA_W-1:0] expected_word(input logic [mlc_pkg::ADDR_W-1:0] addr);
    logic [mlc_pkg::ADDR_W-1:0] line_base;
    int word_idx;
    line_base = addr & ~(mlc_pkg::L1_LINE_B - 1);
    word_idx  = (addr - line_base) >> 2;
    expected_word = line_base + word_idx;
  endfunction

  task automatic cpu_read(input logic [mlc_pkg::ADDR_W-1:0] addr, output logic [mlc_pkg::DATA_W-1:0] rdata);
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

  task automatic cpu_write(input logic [mlc_pkg::ADDR_W-1:0] addr, input logic [mlc_pkg::DATA_W-1:0] wdata,
                            input logic [mlc_pkg::BYTES_PER_WORD-1:0] wstrb);
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
      logic [mlc_pkg::DATA_W-1:0] rd;
      cpu_read(32'h0000_0000, rd);
      check(rd === expected_word(32'h0000_0000), "cold-miss read returns the fetched data");
    end

    begin
      logic [mlc_pkg::DATA_W-1:0] rd;
      cpu_read(32'h0000_0000, rd);
      check(rd === expected_word(32'h0000_0000), "repeated hit on address 0 returns the same data");
    end

    begin
      logic [mlc_pkg::DATA_W-1:0] rd;
      cpu_read(32'h0000_0020, rd); // install this line first (cold miss) so the next write is a HIT
      check(rd === expected_word(32'h0000_0020), "address 0x20 installed via cold miss");
      cpu_write(32'h0000_0020, 32'hDEAD_BEEF, 4'b1111);
      check(dut.u_core.wr_fwd_pending === 1'b0,
            "write-forward skid register never occupied when L2 is always ready");
      cpu_read(32'h0000_0020, rd);
      check(rd === 32'hDEAD_BEEF, "write hit then read-back returns the written value");
    end

    begin
      logic [mlc_pkg::DATA_W-1:0] rd;
      cpu_write(32'h0000_0020, 32'h0000_00FF, 4'b0001); // byte 0 only
      cpu_read(32'h0000_0020, rd);
      check(rd === 32'hDEAD_BEFF, "byte-enable write updates only the selected byte");
    end

    begin
      // Genuine back-to-back write-hit burst (Review Focus #3): one write hit per cycle, no
      // gaps, confirming the skid register never engages even under sustained pressure.
      // Reuses 0x0000_0020, which is valid here (installed by the earlier fast-path scenario,
      // most recently written by the byte-enable test above); nothing later depends on its
      // exact stored value before the next full-cache reset (Step 28) invalidates it anyway.
      logic all_accepted;
      all_accepted = 1'b1;
      @(posedge clk);
      req_valid <= 1'b1; req_we <= 1'b1; req_addr <= 32'h0000_0020;
      req_wdata <= 32'h0000_0001; req_wstrb <= 4'b1111; resp_ready <= 1'b1;
      for (int i = 0; i < 4; i++) begin
        @(posedge clk);
        if (!req_ready) all_accepted = 1'b0;
        check(dut.u_core.wr_fwd_pending === 1'b0,
              "skid register stays empty through a back-to-back write-hit burst (Review Focus #3)");
        req_addr  <= 32'h0000_0020;
        req_wdata <= req_wdata + 1;
      end
      req_valid <= 1'b0;
      @(posedge clk);
      check(all_accepted, "every write hit in the burst was accepted with req_ready held high throughout");
    end

    begin
      logic [mlc_pkg::DATA_W-1:0] rd;
      logic saw_write_fwd;
      logic fwd_data_correct;
      saw_write_fwd = 1'b0;
      fwd_data_correct = 1'b0;
      fork
        begin
          cpu_write(32'h0000_0040, 32'hCAFE_F00D, 4'b1111);
          cpu_read(32'h0000_0040, rd);
          check(rd === 32'hCAFE_F00D, "write miss installs the line locally with the write applied");
        end
        begin: wait_write_fwd
          repeat (20) begin
            @(posedge clk);
            if (dn_req_valid && dn_req_we && dn_req_addr === 32'h0000_0040) begin
              saw_write_fwd = 1'b1;
              fwd_data_correct = (dn_req_wdata === 32'hCAFE_F00D) && (dn_req_wstrb === 4'b1111);
            end
          end
        end
      join
      check(saw_write_fwd, "write-miss eventually forwards the write downstream too");
      check(fwd_data_correct, "the forwarded write carries the correct wdata/wstrb, not stale req_* inputs");
    end

    begin
      logic [mlc_pkg::DATA_W-1:0] rd;
      cpu_read(32'h0000_0060, rd);
      check(rd === expected_word(32'h0000_0060), "address 0x60 installed via cold miss");

      @(posedge clk);
      req_valid <= 1'b1; req_we <= 1'b0; req_addr <= 32'h0000_0060; resp_ready <= 1'b0;
      repeat (4) begin
        @(posedge clk);
        check(req_ready === 1'b0,
              "req_ready drops on a would-be hit while resp_ready is low (response not lost)");
        check(resp_valid === 1'b0,
              "resp_valid does not fire while the request has not actually been accepted (req_ready=0)");
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
      logic [mlc_pkg::DATA_W-1:0] rd;
      logic saw_miss;
      // L1_SETS * mlc_pkg::L1_LINE_B = 128 * 32 = 4096 = exactly one alias stride: same index, different tag.
      cpu_read(32'h0000_0000, rd);
      check(rd === expected_word(32'h0000_0000), "baseline: original line present before aliasing");
      cpu_read(32'h0000_0000 + (mlc_pkg::L1_SETS * mlc_pkg::L1_LINE_B), rd);
      check(rd === expected_word(32'h0000_0000 + (mlc_pkg::L1_SETS * mlc_pkg::L1_LINE_B)),
            "aliasing address (same index, different tag) misses and installs correctly");

      saw_miss = 1'b0;
      fork
        begin
          cpu_read(32'h0000_0000, rd);
        end
        begin
          repeat (15) begin
            @(posedge clk);
            if (dut.u_core.state === dut.u_core.S_ALLOC_FILL) saw_miss = 1'b1;
          end
        end
      join
      check(rd === expected_word(32'h0000_0000),
            "original line was evicted by the alias and must miss again on re-access");
      check(saw_miss,
            "the re-access genuinely took the miss path (S_ALLOC_FILL), not a stale hit (Review Focus #4)");
    end

    begin
      logic [mlc_pkg::DATA_W-1:0] rd0, rd1;
      cpu_read(32'h0000_0080, rd0);
      cpu_read(32'h0000_00A0, rd1);
      check(rd0 === expected_word(32'h0000_0080) && rd1 === expected_word(32'h0000_00A0),
            "back-to-back misses to different sets both resolve correctly");
    end

    begin
      hold_not_ready = 1'b1;
      @(posedge clk);
      req_valid <= 1'b1; req_we <= 1'b1; req_addr <= 32'h0000_0080;
      req_wdata <= 32'hFACE_0FF1; req_wstrb <= 4'b1111; resp_ready <= 1'b1;
      wait (req_ready);
      @(posedge clk);
      req_valid <= 1'b0;
      repeat (5) begin
        @(posedge clk);
        check(req_ready === 1'b0, "req_ready stays low while the write-forward cannot drain to L2");
      end
      hold_not_ready = 1'b0;
      @(posedge clk);
      wait (req_ready);
      @(posedge clk);
    end

    begin
      @(posedge clk);
      req_valid <= 1'b1; req_we <= 1'b0; req_addr <= 32'h0000_00E0; resp_ready <= 1'b1;
      wait (req_ready);
      @(posedge clk);
      req_valid <= 1'b0;
      @(posedge clk); // now inside S_ALLOC_FILL
      check(dut.u_core.state === dut.u_core.S_ALLOC_FILL, "confirmed mid-fill before reset");
      rst_n <= 1'b0;
      repeat (2) @(posedge clk);
      rst_n <= 1'b1;
      @(posedge clk); #1;
      check(dut.u_core.state === dut.u_core.S_IDLE, "controller returns to IDLE after reset mid-fill");
      check(req_ready === 1'b1, "req_ready is high again after reset mid-fill");
    end

    begin
      logic [mlc_pkg::DATA_W-1:0] rd;
      // 0x80 was invalidated by Step 28's full reset (clears the entire valid_array, not just
      // the line being filled) - re-install it here before reusing it as a hit.
      cpu_read(32'h0000_0080, rd);
      check(rd === expected_word(32'h0000_0080), "address 0x80 re-installed after Step 28's reset");

      hold_not_ready = 1'b1;
      @(posedge clk);
      req_valid <= 1'b1; req_we <= 1'b1; req_addr <= 32'h0000_0080;
      req_wdata <= 32'h1111_2222; req_wstrb <= 4'b1111; resp_ready <= 1'b1;
      wait (req_ready);
      @(posedge clk);
      req_valid <= 1'b0;
      @(posedge clk);
      check(dut.u_core.wr_fwd_pending === 1'b1, "write-forward is pending before reset");
      // hold_not_ready stays asserted through reset AND the post-reset check below, so the
      // normal (non-reset) drain path cannot be the reason wr_fwd_pending reads 0 afterward -
      // isolating what CR-03/reset itself does from what draining does (Review Focus #5).
      rst_n <= 1'b0;
      repeat (2) @(posedge clk);
      rst_n <= 1'b1;
      @(posedge clk); #1;
      check(dut.u_core.wr_fwd_pending === 1'b0,
            "write-forward skid register clears on reset (CR-03), checked while L2 is still held not-ready so this can only be reset's own doing");
      check(dn_req_valid === 1'b0,
            "no downstream write request is still asserted after reset clears the pending forward");
      hold_not_ready <= 1'b0;
      @(posedge clk);
      wait (req_ready);
    end

    begin
      // Regression for the resp_valid/req_ready coupling bug found during Task 2 review:
      // resp_valid must never fire for a hit that req_ready did not actually accept.
      logic [mlc_pkg::DATA_W-1:0] rd;
      cpu_read(32'h0000_00C0, rd); // W1's address (index 6) - install first so its write is a hit
      check(rd === expected_word(32'h0000_00C0), "0xC0 installed for the resp_valid regression");
      cpu_read(32'h0000_0020, rd); // W2's address (index 1) - install first so its write is a hit
      check(rd === expected_word(32'h0000_0020), "0x20 re-installed for the resp_valid regression");

      hold_not_ready = 1'b1;
      @(posedge clk);
      req_valid <= 1'b1; req_we <= 1'b1; req_addr <= 32'h0000_00C0;
      req_wdata <= 32'hAAAA_0001; req_wstrb <= 4'b1111; resp_ready <= 1'b1;
      wait (req_ready);
      @(posedge clk);
      req_valid <= 1'b0;
      @(posedge clk);
      check(dut.u_core.wr_fwd_pending === 1'b1, "W1's forward is pending (regression setup)");

      // Present W2, a hit at a different address, while W1's forward is still pending and
      // blocked. req_ready must be 0 for W2, and resp_valid must never fire for it.
      @(posedge clk);
      req_valid <= 1'b1; req_we <= 1'b1; req_addr <= 32'h0000_0020;
      req_wdata <= 32'hBBBB_0002; req_wstrb <= 4'b1111; resp_ready <= 1'b1;
      repeat (3) begin
        @(posedge clk);
        check(req_ready === 1'b0, "req_ready stays low for W2 while W1's forward is pending");
        check(resp_valid === 1'b0, "resp_valid does not fire for a request req_ready never accepted");
      end
      req_valid <= 1'b0;
      hold_not_ready <= 1'b0;
      @(posedge clk);
      wait (req_ready);

      // Confirm W2 was genuinely never applied (data must be unchanged, since it was never accepted).
      cpu_read(32'h0000_0020, rd);
      check(rd === expected_word(32'h0000_0020), "W2's write never actually landed - value is still pristine");
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
