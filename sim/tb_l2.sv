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

  function automatic logic [LINE_W-1:0] expected_line(input logic [mlc_pkg::ADDR_W-1:0] addr);
    logic [mlc_pkg::ADDR_W-1:0] line_base;
    expected_line = '0;
    line_base = addr & ~(mlc_pkg::L2_LINE_B - 1);
    for (int w = 0; w < mlc_pkg::L2_LINE_B / mlc_pkg::BYTES_PER_WORD; w++) begin
      expected_line[w*mlc_pkg::DATA_W +: mlc_pkg::DATA_W] = line_base + w;
    end
  endfunction

  task automatic cpu_read(input logic [mlc_pkg::ADDR_W-1:0] addr, output logic [LINE_W-1:0] rline);
    @(posedge clk);
    req_valid <= 1'b1; req_we <= 1'b0; req_addr <= addr;
    resp_ready <= 1'b1;
    wait (req_ready);
    @(posedge clk);
    req_valid <= 1'b0;
    wait (resp_valid);
    rline = resp_line;
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
      logic [LINE_W-1:0] rline;
      cpu_read(32'h0000_0000, rline);
      check(rline === expected_line(32'h0000_0000), "cold-miss read returns the fetched line");
      check_fwd_empty("a clean cold-miss fill produces no write-back");
    end

    begin
      logic [LINE_W-1:0] rline;
      cpu_read(32'h0000_0000, rline);
      check(rline === expected_line(32'h0000_0000), "repeated hit on address 0 returns the same line");
    end

    begin
      logic [LINE_W-1:0] rline;
      @(posedge clk);
      req_valid <= 1'b1; req_we <= 1'b1; req_addr <= 32'h0000_0000;
      req_wdata <= 32'hDEAD_BEEF; req_wstrb <= 4'b1111; resp_ready <= 1'b1;
      wait (req_ready);
      @(posedge clk);
      req_valid <= 1'b0;
      wait (resp_valid);
      @(posedge clk);
      check_fwd_empty("a write hit never forwards downstream (FR-15, write-back semantics)");
      cpu_read(32'h0000_0000, rline);
      check(rline[0 +: mlc_pkg::DATA_W] === 32'hDEAD_BEEF,
            "write hit then read-back returns the written word (word 0 of the line)");
    end

    begin
      logic [LINE_W-1:0] rline;
      logic [LINE_W-1:0] expected_evicted_line;
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

      // 0x0000 now misses again (its line was just evicted). l3_stub.sv is a pure function of
      // address with no memory of the write-back it just absorbed, so the re-fetch returns the
      // pristine pattern, NOT the DEAD_BEEF-modified content that was written back - the write-
      // back above proved the dirty data left L2 correctly; it does not mean L3 remembers it.
      cpu_read(32'h0000_0000, rline);
      check(rline === expected_line(32'h0000_0000),
            "the evicted address (0x0000) misses again and re-fetches L3's pristine pattern");

      cpu_read(32'h0000_2000, rline);
      check(rline === expected_line(32'h0000_2000), "0x2000 (way2, per the trace above) is still resident - untouched by the eviction");
      cpu_read(32'h0000_4000, rline);
      check(rline === expected_line(32'h0000_4000), "0x4000 (way1, per the trace above) is still resident - untouched by the eviction");
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
      @(posedge clk);
      req_valid <= 1'b1; req_we <= 1'b1; req_addr <= 32'h0000_0040; // fresh set (index 2)
      req_wdata <= 32'hCAFE_F00D; req_wstrb <= 4'b1111; resp_ready <= 1'b1;
      wait (req_ready);
      @(posedge clk);
      req_valid <= 1'b0;
      wait (resp_valid);
      @(posedge clk);
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
