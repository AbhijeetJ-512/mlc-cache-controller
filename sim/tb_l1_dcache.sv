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
    word_idx  = (addr - line_base) >> $clog2(mlc_pkg::BYTES_PER_WORD);
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

  // Global record of every write that actually reached L2: one entry per clock edge on which
  // dn_req_valid && dn_req_ready && dn_req_we. The L2 stub absorbs write-forwards without storing
  // them, so this log is the only thing that verifies what L2 received (FR-08). Every scenario
  // that forwards a write drains it via check_fwd_one/check_fwd_empty (or pops it directly), so
  // each check sees only its own scenario's forwards. Icarus 12 supports neither a queue of
  // structs nor named-member assignment patterns, so the queue element is fwd_entry_t's
  // equivalent packed vector; assigning through fwd_entry_t still gives named-field access.
  typedef struct packed {
    logic [mlc_pkg::ADDR_W-1:0]         addr;
    logic [mlc_pkg::DATA_W-1:0]         wdata;
    logic [mlc_pkg::BYTES_PER_WORD-1:0] wstrb;
  } fwd_entry_t;
  logic [$bits(fwd_entry_t)-1:0] fwd_log[$];

  always @(posedge clk) begin
    fwd_entry_t e;
    if (dn_req_valid && dn_req_ready && dn_req_we) begin
      e.addr = dn_req_addr; e.wdata = dn_req_wdata; e.wstrb = dn_req_wstrb;
      fwd_log.push_back(e);
    end
  end

  // On failure these clear the log, so one scenario's bad forward does not cascade into FAILs
  // in every later scenario's forward checks.
  task automatic check_fwd_one(input logic [mlc_pkg::ADDR_W-1:0]         exp_addr,
                               input logic [mlc_pkg::DATA_W-1:0]         exp_wdata,
                               input logic [mlc_pkg::BYTES_PER_WORD-1:0] exp_wstrb,
                               input string msg);
    fwd_entry_t e;
    if (fwd_log.size() != 1) begin
      $display("FAIL: %s (expected exactly 1 forward, got %0d)", msg, fwd_log.size());
      errors++;
      fwd_log.delete();
    end else begin
      e = fwd_log.pop_front();
      check(e.addr === exp_addr && e.wdata === exp_wdata && e.wstrb === exp_wstrb, msg);
      if (!(e.addr === exp_addr && e.wdata === exp_wdata && e.wstrb === exp_wstrb))
        $display("      (L2 received addr=%h wdata=%h wstrb=%b)", e.addr, e.wdata, e.wstrb);
    end
  endtask

  task automatic check_fwd_empty(input string msg);
    if (fwd_log.size() != 0)
      $display("      (%0d unexpected forward(s) reached L2)", fwd_log.size());
    check(fwd_log.size() == 0, msg);
    fwd_log.delete();
  endtask

  // Simulation watchdog: bounds any stall regression (every wait() below is otherwise unbounded)
  // to a FAIL line and a nonzero exit instead of a silent hang. The full passing run finishes at
  // 2525 ns (sim/logs/tb_l1_dcache.log); this 10000 ns limit is ~4.0x that - raise it if new
  // scenarios push the legitimate runtime anywhere near it.
  initial begin
    #10000;
    $display("FAIL: simulation watchdog timeout - a scenario is stuck");
    errors++;
    $fatal(1);
  end

  initial begin
    req_valid = 0; req_we = 0; req_addr = 0; req_wdata = 0; req_wstrb = 0; resp_ready = 0;
    rst_n = 0;
    repeat (3) @(posedge clk);
    // Nothing else holds req_ready low here (FSM is in S_IDLE, no forward pending, req_valid=0),
    // so this isolates the rst_n term of req_ready (04_interfaces.md §5).
    check(req_ready === 1'b0, "req_ready is held low while rst_n is asserted");
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
      check_fwd_one(32'h0000_0020, 32'hDEAD_BEEF, 4'b1111, "fast-path write hit forwards exactly once with correct payload");
      cpu_read(32'h0000_0020, rd);
      check(rd === 32'hDEAD_BEEF, "write hit then read-back returns the written value");
    end

    begin
      logic [mlc_pkg::DATA_W-1:0] rd;
      cpu_write(32'h0000_0020, 32'h0000_00FF, 4'b0001); // byte 0 only
      // The only fast-path (L2-ready) write hit with a partial wstrb - without this, a fast-path
      // forward that always sent wstrb=4'b1111 would pass every other fast-path forward check.
      check_fwd_one(32'h0000_0020, 32'h0000_00FF, 4'b0001, "byte-enable write hit forwards exactly once, with its partial wstrb intact");
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
      @(posedge clk); // let the last forward land
      // The loop above presents wdata 1, 2, 3, 4 on its four accepting edges (req_wdata increments
      // by NBA after each edge samples it), all to 0x20 with full wstrb.
      check(fwd_log.size() == 4, "burst of 4 write hits forwards exactly 4 times");
      for (int k = 0; k < 4 && fwd_log.size() > 0; k++) begin
        fwd_entry_t e;
        e = fwd_log.pop_front();
        check(e.addr === 32'h0000_0020 && e.wdata === (32'h0000_0001 + k) && e.wstrb === 4'b1111,
              $sformatf("burst forward %0d carries the correct address/wdata", k));
      end
      fwd_log.delete(); // only non-empty if the count check above already FAILed - don't cascade
    end

    begin
      logic [mlc_pkg::DATA_W-1:0] rd;
      logic saw_write_fwd;
      logic fwd_data_correct;
      saw_write_fwd = 1'b0;
      fwd_data_correct = 1'b0;
      fork
        begin
          // Issued inline rather than via cpu_write: cpu_write only returns after the whole miss
          // has completed, and this write's forward reaches L2 on that same returning edge, so
          // changing req_* after cpu_write returns would prove nothing. Instead the live
          // req_addr/req_wdata/req_wstrb are stomped with junk on the very edge the miss is
          // accepted (req_valid drops on that same edge, so no handshake ever sees the junk).
          // From then on only the latched miss_* registers hold the real values, so if the RTL
          // used live req_* instead of miss_* for the fill merge or the downstream forward, the
          // read-back and forward checks below would see the junk instead of matching by
          // coincidence.
          @(posedge clk);
          req_valid <= 1'b1; req_we <= 1'b1; req_addr <= 32'h0000_0040;
          req_wdata <= 32'hCAFE_F00D; req_wstrb <= 4'b1111; resp_ready <= 1'b1;
          wait (req_ready);
          @(posedge clk); // miss accepted on this edge
          req_valid <= 1'b0;
          req_addr <= 32'hFFFF_FFFF; req_wdata <= 32'hFFFF_FFFF; req_wstrb <= 4'b0000;
          wait (resp_valid);
          @(posedge clk);
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
      check_fwd_one(32'h0000_0040, 32'hCAFE_F00D, 4'b1111,
                    "write miss reaches L2 exactly once, with the latched (not live) address/wdata/wstrb");
    end

    begin
      logic [mlc_pkg::DATA_W-1:0] rd;
      cpu_read(32'h0000_0060, rd);
      check(rd === expected_word(32'h0000_0060), "address 0x60 installed via cold miss");

      @(posedge clk);
      req_valid <= 1'b1; req_we <= 1'b0; req_addr <= 32'h0000_0060; resp_ready <= 1'b0;
      // Exercises the documented same-cycle hit contract (04_interfaces.md §1), not an incidental case.
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
      // Miss-completion counterpart of the scenario above: once a miss reaches S_UPDATE_TAG, the
      // controller must hold its response (stay in S_UPDATE_TAG, resp_valid high, data stable)
      // for as long as resp_ready is low, and leave only on the response handshake.
      // 0x114 is a never-touched line (index 8) at a non-zero word offset (word 5), so this also
      // exercises the miss-path word select (miss_word_sel) away from word 0.
      logic [mlc_pkg::DATA_W-1:0] rd;
      @(posedge clk);
      req_valid <= 1'b1; req_we <= 1'b0; req_addr <= 32'h0000_0114; resp_ready <= 1'b0;
      wait (req_ready); // a miss is accepted even with resp_ready low (only a hit waits on it)
      @(posedge clk);
      req_valid <= 1'b0;
      wait (dut.u_core.state === dut.u_core.S_UPDATE_TAG);
      repeat (4) begin
        @(posedge clk); #1;
        check(dut.u_core.state === dut.u_core.S_UPDATE_TAG,
              "miss completion stays in S_UPDATE_TAG while resp_ready is low");
        check(resp_valid === 1'b1 && resp_rdata === expected_word(32'h0000_0114),
              "miss response is held (resp_valid high, correct data) while resp_ready is low");
      end
      resp_ready <= 1'b1;
      @(posedge clk); // the response handshake happens on this edge
      rd = resp_rdata;
      check(resp_valid === 1'b1 && rd === expected_word(32'h0000_0114),
            "stalled miss response completes with the correct data once resp_ready is asserted");
      #1;
      check(dut.u_core.state === dut.u_core.S_IDLE,
            "S_UPDATE_TAG advances to S_IDLE on the response handshake");
    end

    begin
      logic [mlc_pkg::DATA_W-1:0] rd;
      logic saw_miss;
      // mlc_pkg::L1_SETS * mlc_pkg::L1_LINE_B = 128 * 32 = 4096 = exactly one alias stride: same index, different tag.
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
      check_fwd_empty("no forward reaches L2 while it is held not-ready");
      // Released by NBA (not a blocking assignment) so the DUT, the stub and the forward log all
      // see the same dn_req_ready on the release edge - no ordering race between them.
      hold_not_ready <= 1'b0;
      @(posedge clk);
      wait (req_ready);
      check_fwd_one(32'h0000_0080, 32'hFACE_0FF1, 4'b1111, "the pending forward lands exactly once, correctly, after release");
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
      #1;
      check_fwd_empty("the forward discarded by reset never reaches L2, even once L2 frees up");
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
      check_fwd_one(32'h0000_00C0, 32'hAAAA_0001, 4'b1111, "W1's forward lands correctly once L2 is available");

      // Confirm W2 was genuinely never applied (data must be unchanged, since it was never accepted).
      cpu_read(32'h0000_0020, rd);
      check(rd === expected_word(32'h0000_0020), "W2's write never actually landed - value is still pristine");
      check_fwd_empty("W2 was never accepted, so it never reached L2 either");
    end

    begin
      // Regression for Task 4 review: no existing test exercises a non-zero word-select
      // offset within a line (every prior address was line-aligned, word_sel always 0).
      // This directly tests the hit_write_line_merged/req_line_rd restructuring (D-017).
      logic [mlc_pkg::DATA_W-1:0] rd;
      cpu_read(32'h0000_0060, rd); // (re-)install this line fresh, regardless of prior state
      check(rd === expected_word(32'h0000_0060), "0x60 installed fresh for the word-offset regression");

      cpu_write(32'h0000_006C, 32'hFEED_1234, 4'b1111); // same line, word_sel=3 (0x60 + 3*4)
      check_fwd_one(32'h0000_006C, 32'hFEED_1234, 4'b1111,
                    "write hit at a non-zero word offset forwards its exact (non-line-aligned) address");
      cpu_read(32'h0000_006C, rd);
      check(rd === 32'hFEED_1234, "write hit at a non-zero word offset updates that word");

      cpu_read(32'h0000_0068, rd); // word 2 of the same line, must be untouched
      check(rd === expected_word(32'h0000_0068),
            "neighboring word (word 2) in the same line is unaffected by a non-zero-offset write");

      cpu_read(32'h0000_0060, rd); // word 0 of the same line, must also be untouched
      check(rd === expected_word(32'h0000_0060),
            "word 0 of the same line is unaffected by a non-zero-offset write");
    end

    begin
      // Partial-wstrb coverage of the two forward paths every scenario above drives only with
      // wstrb=4'b1111 (so a path that forced wstrb to all-ones would pass all of them):
      // (1) a write MISS (miss_wstrb -> fill merge and wr_fwd_wstrb), and (2) a write HIT captured
      // by the skid register while L2 is held not-ready (req_wstrb -> wr_fwd_wstrb).
      // 0x144 is a never-touched line (index 10), word 1, whose fetched value is 0x0000_0141.
      logic [mlc_pkg::DATA_W-1:0] rd;
      cpu_write(32'h0000_0144, 32'hA1B2_C3D4, 4'b0110); // miss: only bytes 1-2 are written
      cpu_read(32'h0000_0144, rd); // also lets the miss's forward (sent as cpu_write returns) land
      check(rd === 32'h00B2_C341, "partial-wstrb write miss merges only its enabled bytes into the fill");
      check_fwd_one(32'h0000_0144, 32'hA1B2_C3D4, 4'b0110, "partial-wstrb write miss forwards its wstrb intact");

      hold_not_ready <= 1'b1;
      @(posedge clk);
      req_valid <= 1'b1; req_we <= 1'b1; req_addr <= 32'h0000_0144;
      req_wdata <= 32'h5566_7788; req_wstrb <= 4'b1001; resp_ready <= 1'b1;
      wait (req_ready);
      @(posedge clk);
      req_valid <= 1'b0;
      @(posedge clk);
      check(dut.u_core.wr_fwd_pending === 1'b1, "partial-wstrb write hit is held in the skid register while L2 is not ready");
      hold_not_ready <= 1'b0;
      @(posedge clk);
      wait (req_ready);
      check_fwd_one(32'h0000_0144, 32'h5566_7788, 4'b1001, "partial-wstrb write hit drains from the skid register with its wstrb intact");
      cpu_read(32'h0000_0144, rd);
      check(rd === 32'h55B2_C388, "partial-wstrb write hit merges only its enabled bytes (bytes 0 and 3)");
    end

    begin
      // The fill request sent to L2 must carry the latched miss_addr, not the live req_addr.
      // Driven manually (cpu_read holds req_addr stable until the response, which would hide a
      // live-vs-latched bug): req_addr is stomped with junk on the very edge the miss is accepted,
      // which is legal - nothing requires the CPU to hold req_addr once req_valid drops. L2 only
      // accepts the fill request on a later edge, so a fill request built from live req_addr
      // would reach L2 as junk and bring back the wrong line.
      // 0x178 is a never-touched line (index 11) at word 6 (junk req_addr would select word 7).
      logic [mlc_pkg::DATA_W-1:0] rd;
      int   fill_handshakes;
      logic fill_addr_ok, fill_addr_stable;
      fill_handshakes = 0; fill_addr_ok = 1'b0; fill_addr_stable = 1'b1;
      fork
        begin
          @(posedge clk);
          req_valid <= 1'b1; req_we <= 1'b0; req_addr <= 32'h0000_0178; resp_ready <= 1'b1;
          wait (req_ready);
          @(posedge clk); // miss accepted on this edge
          req_valid <= 1'b0;
          req_addr  <= 32'hFFFF_FFFF;
          #1;
          check(dut.u_core.state === dut.u_core.S_ALLOC_FILL,
                "fresh-line read miss accepted into S_ALLOC_FILL (req_addr now stomped with junk)");
          wait (resp_valid);
          rd = resp_rdata;
          @(posedge clk);
        end
        begin: watch_fill_req
          repeat (15) begin
            @(posedge clk);
            if (dn_req_valid && !dn_req_we) begin
              if (dn_req_addr !== 32'h0000_0178) fill_addr_stable = 1'b0;
              if (dn_req_ready) begin
                fill_handshakes++;
                fill_addr_ok = (dn_req_addr === 32'h0000_0178);
              end
            end
          end
        end
      join
      check(rd === expected_word(32'h0000_0178),
            "miss with req_addr stomped after acceptance returns the original address's data, not junk-derived data");
      check(fill_handshakes == 1 && fill_addr_ok,
            "L2 accepts exactly one fill request, carrying the latched miss address");
      check(fill_addr_stable,
            "the fill request's address stays the latched miss address for its whole duration");
    end

    check_fwd_empty("no unaccounted-for write forward reached L2 anywhere in the run");

    if (errors == 0) begin
      $display("** ALL TESTS PASSED **");
      $finish;
    end else begin
      $display("** %0d TEST(S) FAILED **", errors);
      $fatal(1);
    end
  end
endmodule
