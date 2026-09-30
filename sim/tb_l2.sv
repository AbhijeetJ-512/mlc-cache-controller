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

  // Downstream READ (fill request) handshake counter. l3_stub returns purely address-derived data,
  // so a read's returned line cannot tell a genuine hit from a silent miss-and-refetch - both give
  // the same pattern. A hit is proven only by the count NOT increasing across the access.
  int dn_rd_count = 0;
  always @(posedge clk) begin
    if (dn_req_valid && dn_req_ready && !dn_req_we) dn_rd_count++;
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

  // Posted-write monitor (D-021): no write, hit or miss, may ever produce an upstream response.
  // acc_we remembers whether the most recently accepted request was a write, so a later
  // miss-completion response (S_UPDATE_TAG) can be attributed to the request that caused it; a
  // same-cycle hit response belongs to the request being accepted in that same cycle.
  logic acc_we;
  int   write_resp_count = 0;
  always @(posedge clk) begin
    if (rst_n && resp_valid === 1'b1) begin
      if (req_valid && req_ready) begin
        if (req_we !== 1'b0) write_resp_count++;
      end else if (acc_we !== 1'b0) begin
        write_resp_count++;
      end
    end
    if (req_valid && req_ready) acc_we <= req_we;
  end

  function automatic logic [LINE_W-1:0] expected_line(input logic [mlc_pkg::ADDR_W-1:0] addr);
    logic [mlc_pkg::ADDR_W-1:0] line_base;
    expected_line = '0;
    line_base = addr & ~(mlc_pkg::L2_LINE_B - 1);
    for (int w = 0; w < mlc_pkg::L2_LINE_B / mlc_pkg::BYTES_PER_WORD; w++) begin
      expected_line[w*mlc_pkg::DATA_W +: mlc_pkg::DATA_W] = line_base + w;
    end
  endfunction

  // Latched-vs-live guard (mutation-driven). Once a miss has been accepted, the controller must work
  // only from its latched miss_* copies, never from the live req_* inputs - but a testbench that
  // holds req_* steady for the whole miss cannot tell the two apart. So right after every accepted
  // miss (and after every cpu_read, where a hit's response has already been sampled by then), all
  // request fields except req_valid are driven to clearly wrong values: an address whose tag,
  // set (247, never used by any test) and word (3) all differ from every test address, and X for
  // the write controls and data. If the RTL re-read any live req_* field mid-miss, the wrong set,
  // tag, word, or an X would show up in a checked result.
  localparam logic [mlc_pkg::ADDR_W-1:0] POISON_ADDR = 32'hDEAD_BEEC;
  task automatic poison_req();
    req_addr  <= POISON_ADDR;
    req_we    <= 1'bx;
    req_wdata <= 'x;
    req_wstrb <= 'x;
  endtask

  task automatic cpu_read(input logic [mlc_pkg::ADDR_W-1:0] addr, output logic [LINE_W-1:0] rline);
    @(posedge clk);
    req_valid <= 1'b1; req_we <= 1'b0; req_addr <= addr;
    resp_ready <= 1'b1;
    wait (req_ready);
    @(posedge clk);
    req_valid <= 1'b0;
    // Nonblocking, so it lands after this edge: a hit's same-cycle response is still sampled below
    // with the real request, while a miss runs its whole sequence against the poisoned inputs.
    poison_req();
    wait (resp_valid);
    rline = resp_line;
    @(posedge clk);
  endtask

  // Write hit, posted (D-021). resp_ready is driven low, as L1 does for every write-through
  // forward it sends: a write never gets a response, so it must be accepted without one. A write
  // hit commits on its acceptance edge, so the task is done once req_valid drops. It also checks,
  // at that edge, that the write really was accepted and really was a hit (the controller stays in
  // S_IDLE instead of starting a miss sequence), so no call site can silently take the miss path.
  task automatic cpu_write_hit(input logic [mlc_pkg::ADDR_W-1:0] addr, input logic [mlc_pkg::DATA_W-1:0] wdata);
    logic accepted;
    @(posedge clk);
    req_valid <= 1'b1; req_we <= 1'b1; req_addr <= addr;
    req_wdata <= wdata; req_wstrb <= 4'b1111; resp_ready <= 1'b0;
    wait (req_ready);
    @(posedge clk);
    accepted = req_ready; // sampled at the acceptance edge, before any state update lands
    req_valid <= 1'b0;
    #1;
    check(accepted === 1'b1 && dut.state === dut.S_IDLE,
          $sformatf("write to 0x%08h is accepted with resp_ready low and completes as a genuine hit", addr));
  endtask

  // Write miss (write-allocate), posted (D-021). resp_ready is held low throughout. After the
  // write is accepted, the task waits for the miss sequence to start (S_TAG_CHECK) and then to run
  // all the way back to S_IDLE (eviction if needed, fill, merge, commit) - which it must do without
  // ever seeing resp_ready.
  task automatic cpu_write_alloc(input logic [mlc_pkg::ADDR_W-1:0] addr, input logic [mlc_pkg::DATA_W-1:0] wdata,
                                 input logic [mlc_pkg::BYTES_PER_WORD-1:0] wstrb);
    @(posedge clk);
    req_valid <= 1'b1; req_we <= 1'b1; req_addr <= addr;
    req_wdata <= wdata; req_wstrb <= wstrb; resp_ready <= 1'b0;
    wait (req_ready);
    @(posedge clk);
    req_valid <= 1'b0;
    poison_req();
    wait (dut.state === dut.S_TAG_CHECK);
    wait (dut.state === dut.S_IDLE);
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
      int rd_count_before;
      rd_count_before = dn_rd_count;
      cpu_read(32'h0000_0000, rline);
      check(rline === expected_line(32'h0000_0000), "repeated hit on address 0 returns the same line");
      check(dn_rd_count == rd_count_before, "the repeated access to address 0 is a genuine hit (no downstream read)");
    end

    begin
      logic [LINE_W-1:0] rline;
      // Posted write hit (D-021): completes on req_ready alone, no response.
      cpu_write_hit(32'h0000_0000, 32'hDEAD_BEEF);
      check_fwd_empty("a write hit never forwards downstream (FR-15, write-back semantics)");
      cpu_read(32'h0000_0000, rline);
      check(rline[0 +: mlc_pkg::DATA_W] === 32'hDEAD_BEEF,
            "write hit then read-back returns the written word (word 0 of the line)");
    end

    begin
      logic [LINE_W-1:0] rline;
      logic [LINE_W-1:0] expected_evicted_line;
      int rd_count_before;
      // 0x0000 is already resident (way0, from earlier). Fill the remaining 3 ways of set 0 -
      // each installs into whichever way select_victim currently predicts (see the trace above;
      // do not assume a fixed way0->way1->way2->way3 fill order).
      cpu_read(32'h0000_2000, rline);
      check(rline === expected_line(32'h0000_2000), "set 0's 2nd distinct tag installs correctly");
      cpu_read(32'h0000_4000, rline);
      check(rline === expected_line(32'h0000_4000), "set 0's 3rd distinct tag installs correctly");
      cpu_read(32'h0000_6000, rline);
      check(rline === expected_line(32'h0000_6000), "set 0's 4th distinct tag installs correctly (all 4 ways now occupied)");

      // A 5th access to set 0 (a new tag) evicts the traced-through victim (way0 / address
      // 0x0000) and must produce exactly one write-back, of exactly its dirty content.
      cpu_read(32'h0000_8000, rline);
      check(rline === expected_line(32'h0000_8000), "set 0, 5th access installs correctly");

      expected_evicted_line = expected_line(32'h0000_0000);
      expected_evicted_line[0 +: mlc_pkg::DATA_W] = 32'hDEAD_BEEF;
      check_fwd_one(32'h0000_0000, expected_evicted_line,
                    "traced-through eviction (way0) writes back its dirty content exactly");

      // The eviction took way0 only, so 0x2000 (installed in way2) and 0x4000 (installed in way1)
      // must still be resident. Returned data alone cannot prove that (a miss would refetch the
      // same address-derived pattern from l3_stub), so each read must also issue no downstream
      // read. These reads come before the 0x0000 re-fetch below on purpose: that re-fetch is itself
      // a miss into this full set and evicts another way.
      rd_count_before = dn_rd_count;
      cpu_read(32'h0000_2000, rline);
      check(rline === expected_line(32'h0000_2000), "0x2000 (way2) returns its line after the way0 eviction");
      check(dn_rd_count == rd_count_before,
            "0x2000 (way2) is still resident - a genuine hit, no downstream read was issued");
      rd_count_before = dn_rd_count;
      cpu_read(32'h0000_4000, rline);
      check(rline === expected_line(32'h0000_4000), "0x4000 (way1) returns its line after the way0 eviction");
      check(dn_rd_count == rd_count_before,
            "0x4000 (way1) is still resident - a genuine hit, no downstream read was issued");

      // 0x0000 now misses again (its line was just evicted). l3_stub.sv is a pure function of
      // address with no memory of the write-back it just absorbed, so the re-fetch returns the
      // pristine pattern, NOT the DEAD_BEEF-modified content that was written back - the write-
      // back above proved the dirty data left L2 correctly; it does not mean L3 remembers it.
      rd_count_before = dn_rd_count;
      cpu_read(32'h0000_0000, rline);
      check(rline === expected_line(32'h0000_0000),
            "the evicted address (0x0000) misses again and re-fetches L3's pristine pattern");
      check(dn_rd_count == rd_count_before + 1,
            "the evicted address (0x0000) is a genuine miss - exactly one downstream read was issued");
      check_fwd_empty("the 0x0000 re-fetch evicts a clean line (every resident way of set 0 is clean now) - no write-back");
    end

    begin
      logic [LINE_W-1:0] rline;
      cpu_read(32'h0000_0020, rline); // set 1, way?
      cpu_read(32'h0000_2020, rline); // set 1, way? (same index, different tag)
      cpu_read(32'h0000_4020, rline);
      cpu_read(32'h0000_6020, rline);
      // all 4 ways of set 1 are now resident and clean (never written)
      cpu_read(32'h0000_8020, rline); // 5th access - forces a clean eviction
      check(rline === expected_line(32'h0000_8020), "clean-victim eviction installs the new line correctly");
      check_fwd_empty("evicting a clean victim produces zero write-backs");
    end

    begin
      logic [LINE_W-1:0] rline;
      // Posted write miss (D-021) to a fresh set (index 2): the task confirms the write-allocate
      // sequence starts (S_TAG_CHECK) and fully completes (back to S_IDLE) with resp_ready low.
      cpu_write_alloc(32'h0000_0040, 32'hCAFE_F00D, 4'b1111);
      check_fwd_empty("write-allocate does not forward downstream immediately (write-back semantics)");
      cpu_read(32'h0000_0040, rline);
      check(rline[0 +: mlc_pkg::DATA_W] === 32'hCAFE_F00D,
            "write-allocate merged the write into the fetched line correctly");
      // Per-word loop, not a bit-slice on expected_line(...)'s return value directly: Icarus 12
      // rejects a part-select applied straight to a function call's result (confirmed by direct
      // isolated reproduction), so the comparison line is materialized into a temporary first.
      // The brief calls out this exact substitution as an equally-valid style choice.
      begin
        logic [LINE_W-1:0] exp_line_0040;
        exp_line_0040 = expected_line(32'h0000_0040);
        for (int w = 1; w < mlc_pkg::L2_LINE_B / mlc_pkg::BYTES_PER_WORD; w++) begin
          check(rline[w*mlc_pkg::DATA_W +: mlc_pkg::DATA_W] === exp_line_0040[w*mlc_pkg::DATA_W +: mlc_pkg::DATA_W],
                $sformatf("write-allocate left word %0d of the fetched line unmodified", w));
        end
      end
    end

    begin
      logic [LINE_W-1:0] rline;
      cpu_read(32'h0000_0080, rline);
      check(rline === expected_line(32'h0000_0080), "address 0x80 installed fresh for the resp_ready regression");

      @(posedge clk);
      req_valid <= 1'b1; req_we <= 1'b0; req_addr <= 32'h0000_0080; resp_ready <= 1'b0;
      repeat (4) begin
        @(posedge clk);
        check(req_ready === 1'b0, "req_ready drops on a would-be hit while resp_ready is low");
        check(resp_valid === 1'b0, "resp_valid does not fire while the request has not been accepted");
      end
      resp_ready <= 1'b1;
      @(posedge clk);
      wait (resp_valid);
      rline = resp_line;
      check(rline === expected_line(32'h0000_0080),
            "delayed resp_ready still yields the correct hit data once accepted");
      req_valid <= 1'b0;
      @(posedge clk);
    end

    begin
      // D-021 regression: upstream writes are posted. L1 forwards a write and treats it as done
      // once req_ready accepts it - it never asserts resp_ready for a forwarded write. So with
      // resp_ready held low the whole time, a write hit must still be accepted (and commit), a
      // write-allocate miss must still run to completion, and neither may raise resp_valid.
      logic [LINE_W-1:0] rline;
      cpu_read(32'h0000_00E0, rline); // install 0xE0 (set 7) for the write-hit half

      @(posedge clk);
      req_valid <= 1'b1; req_we <= 1'b1; req_addr <= 32'h0000_00E0;
      req_wdata <= 32'h0D21_0001; req_wstrb <= 4'b1111; resp_ready <= 1'b0;
      @(posedge clk); // acceptance edge: req_ready/resp_valid read here are the pre-edge values
      check(req_ready === 1'b1, "D-021: a write hit is accepted while resp_ready is low");
      check(resp_valid === 1'b0, "D-021: a write hit does not raise resp_valid");
      req_valid <= 1'b0;

      @(posedge clk);
      req_valid <= 1'b1; req_we <= 1'b1; req_addr <= 32'h0000_20E0; // set 7, second tag: a miss
      req_wdata <= 32'h0D21_0002; req_wstrb <= 4'b1111; resp_ready <= 1'b0;
      @(posedge clk);
      check(req_ready === 1'b1 && resp_valid === 1'b0,
            "D-021: a write miss is accepted with resp_ready low and without a response");
      req_valid <= 1'b0;
      poison_req();
      wait (dut.state === dut.S_UPDATE_TAG);
      #1;
      check(resp_valid === 1'b0, "D-021: a write-allocate miss completion does not raise resp_valid");
      @(posedge clk); #1;
      check(dut.state === dut.S_IDLE,
            "D-021: a write-allocate miss leaves S_UPDATE_TAG after one cycle without resp_ready");

      cpu_read(32'h0000_00E0, rline);
      check(rline[0 +: mlc_pkg::DATA_W] === 32'h0D21_0001,
            "D-021: the posted write hit committed to the array");
      cpu_read(32'h0000_20E0, rline);
      check(rline[0 +: mlc_pkg::DATA_W] === 32'h0D21_0002,
            "D-021: the posted write-allocate miss merged its write into the filled line");
      check_fwd_empty("D-021: neither posted write forwarded anything downstream");
    end

    // (insert near the top of the test sequence, right after the initial reset block, or as a
    // second reset pulse here - either placement is fine as long as rst_n is observed low with
    // a live check on req_ready)
    rst_n <= 1'b0;
    @(posedge clk); #1;
    check(req_ready === 1'b0, "req_ready is held low while rst_n is asserted");
    rst_n <= 1'b1;
    @(posedge clk);

    begin
      logic [LINE_W-1:0] rline;
      @(posedge clk);
      req_valid <= 1'b1; req_we <= 1'b0; req_addr <= 32'h0000_0060; // fresh set (index 3)
      resp_ready <= 1'b0;
      wait (req_ready);
      @(posedge clk);
      req_valid <= 1'b0;
      poison_req();
      wait (dut.state === dut.S_UPDATE_TAG);
      repeat (4) begin
        @(posedge clk); #1;
        check(dut.state === dut.S_UPDATE_TAG, "miss completion stays in S_UPDATE_TAG while resp_ready is low");
        check(resp_valid === 1'b1 && resp_line === expected_line(32'h0000_0060),
              "miss response is held (resp_valid high, correct line) while resp_ready is low");
      end
      resp_ready <= 1'b1;
      @(posedge clk); #1;
      check(dut.state === dut.S_IDLE, "S_UPDATE_TAG advances to S_IDLE once resp_ready is asserted");
    end

    begin
      logic [LINE_W-1:0] rline;
      // The reset pulse above cleared every valid bit, so set 0 is empty here. Install four
      // distinct tags with read misses first (PLRU fill order from a reset tree: way0, way2, way1,
      // way3), then write-hit each of them. Because the lines are already resident, these writes
      // are genuine hits - they exercise the write-hit commit path on way 0 and on non-zero ways -
      // and they leave every way of set 0 valid and dirty, so this scenario's eviction is dirty
      // regardless of which way PLRU selects as the victim.
      cpu_read(32'h0000_0000, rline);
      cpu_read(32'h0000_2000, rline);
      cpu_read(32'h0000_4000, rline);
      cpu_read(32'h0000_6000, rline);
      cpu_write_hit(32'h0000_0000, 32'hFEED_0000);
      cpu_write_hit(32'h0000_2000, 32'hFEED_0001);
      cpu_write_hit(32'h0000_4000, 32'hFEED_0002);
      cpu_write_hit(32'h0000_6000, 32'hFEED_0003);

      // Reset mid-EVICT_WRITEBACK: force an eviction by accessing set 0 (all 4 ways valid and
      // dirty, per the writes above) with a fifth distinct tag, and reset while it is stalled
      // waiting for the L3 stub (hold_not_ready blocks EVICT_WRITEBACK from completing).
      hold_not_ready = 1'b1;
      @(posedge clk);
      req_valid <= 1'b1; req_we <= 1'b0; req_addr <= 32'h0000_A000; resp_ready <= 1'b1;
      wait (req_ready);
      @(posedge clk);
      req_valid <= 1'b0;
      poison_req();
      wait (dut.state === dut.S_EVICT_WRITEBACK);
      check(dut.state === dut.S_EVICT_WRITEBACK,
            "the 6th access to set 0 reaches S_EVICT_WRITEBACK (dirty victim, per the writes above)");
      repeat (3) @(posedge clk);
      rst_n <= 1'b0;
      repeat (2) @(posedge clk);
      rst_n <= 1'b1;
      hold_not_ready <= 1'b0;
      @(posedge clk); #1;
      check(dut.state === dut.S_IDLE, "controller returns to IDLE after reset mid-eviction");
      check(req_ready === 1'b1, "req_ready is high again after reset mid-eviction");
    end

    begin
      // Reset mid-ALLOC_FILL, mirroring the same check already proven for L1.
      @(posedge clk);
      req_valid <= 1'b1; req_we <= 1'b0; req_addr <= 32'h0000_00A0; resp_ready <= 1'b1; // fresh set
      wait (req_ready);
      @(posedge clk);
      req_valid <= 1'b0;
      poison_req();
      wait (dut.state === dut.S_ALLOC_FILL);
      rst_n <= 1'b0;
      repeat (2) @(posedge clk);
      rst_n <= 1'b1;
      @(posedge clk); #1;
      check(dut.state === dut.S_IDLE, "controller returns to IDLE after reset mid-fill");
      check(req_ready === 1'b1, "req_ready is high again after reset mid-fill");
    end

    check(write_resp_count == 0,
          "no write (hit or write-allocate miss) raised resp_valid anywhere in the run (D-021, posted writes)");

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
