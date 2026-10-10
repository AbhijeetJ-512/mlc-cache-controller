`timescale 1ns/1ps

// Boundary-contract test (D-030, D-033): the real L1 instruction cache and the real L1 data cache,
// both on the real arbiter, on the real L2 controller (and a behavioural L3 stub below it). It is
// NOT a test of the integrated hierarchy - that stays with the Tier-2 UVM environment (D-013). It
// exists because the arbiter is where two L1 controllers meet one L2 port, and every property it
// must keep (a response goes to its asker, a posted write never leaves it waiting, neither side
// starves) is a property of the real L1 and L2 behaviour, which tb_arbiter only models.
module tb_l1_pair_l2;

  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n;       // L1-I, L1-D, the arbiter and the stub
  logic rst_n_l2;    // L2 alone, so an L1 can keep a line that L2 has forgotten
  int errors = 0;

  // CPU side of L1-I (fetch) and L1-D (load/store)
  logic                              i_req_valid = 1'b0, i_resp_ready = 1'b1;
  logic [mlc_pkg::ADDR_W-1:0]        i_req_addr = '0;
  wire                               i_req_ready, i_resp_valid;
  wire  [mlc_pkg::DATA_W-1:0]        i_resp_rdata;

  logic                              d_req_valid = 1'b0, d_req_we = 1'b0, d_resp_ready = 1'b1;
  logic [mlc_pkg::ADDR_W-1:0]        d_req_addr = '0;
  logic [mlc_pkg::DATA_W-1:0]        d_req_wdata = '0;
  logic [mlc_pkg::BYTES_PER_WORD-1:0] d_req_wstrb = '0;
  wire                               d_req_ready, d_resp_valid;
  wire  [mlc_pkg::DATA_W-1:0]        d_resp_rdata;

  // L1 downstream == arbiter upstream
  wire                               i_dn_req_valid, i_dn_req_ready, i_dn_req_we, i_dn_resp_valid, i_dn_resp_ready;
  wire  [mlc_pkg::ADDR_W-1:0]        i_dn_req_addr;
  wire  [mlc_pkg::DATA_W-1:0]        i_dn_req_wdata;
  wire  [mlc_pkg::BYTES_PER_WORD-1:0] i_dn_req_wstrb;
  wire                               d_dn_req_valid, d_dn_req_ready, d_dn_req_we, d_dn_resp_valid, d_dn_resp_ready;
  wire  [mlc_pkg::ADDR_W-1:0]        d_dn_req_addr;
  wire  [mlc_pkg::DATA_W-1:0]        d_dn_req_wdata;
  wire  [mlc_pkg::BYTES_PER_WORD-1:0] d_dn_req_wstrb;

  // arbiter downstream == L2 upstream
  wire                               a_req_valid, a_req_ready, a_req_we, a_resp_valid, a_resp_ready;
  wire  [mlc_pkg::ADDR_W-1:0]        a_req_addr;
  wire  [mlc_pkg::DATA_W-1:0]        a_req_wdata;
  wire  [mlc_pkg::BYTES_PER_WORD-1:0] a_req_wstrb;
  wire  [mlc_pkg::L2_LINE_B*8-1:0]   l2_resp_line;

  // L2 downstream == stub
  wire                               l2_dn_req_valid, l2_dn_req_ready, l2_dn_req_we, l2_dn_resp_valid, l2_dn_resp_ready;
  wire  [mlc_pkg::ADDR_W-1:0]        l2_dn_req_addr;
  wire  [mlc_pkg::L2_LINE_B*8-1:0]   l2_dn_req_line, l2_dn_resp_line;

  l1_icache_ctrl l1i (
    .clk, .rst_n, .req_valid(i_req_valid), .req_ready(i_req_ready), .req_addr(i_req_addr),
    .resp_valid(i_resp_valid), .resp_ready(i_resp_ready), .resp_rdata(i_resp_rdata),
    .dn_req_valid(i_dn_req_valid), .dn_req_ready(i_dn_req_ready), .dn_req_addr(i_dn_req_addr),
    .dn_req_we(i_dn_req_we), .dn_req_wdata(i_dn_req_wdata), .dn_req_wstrb(i_dn_req_wstrb),
    .dn_resp_valid(i_dn_resp_valid), .dn_resp_ready(i_dn_resp_ready), .dn_resp_line(l2_resp_line)
  );

  l1_dcache_ctrl l1d (
    .clk, .rst_n, .req_valid(d_req_valid), .req_ready(d_req_ready), .req_addr(d_req_addr), .req_we(d_req_we),
    .req_wdata(d_req_wdata), .req_wstrb(d_req_wstrb),
    .resp_valid(d_resp_valid), .resp_ready(d_resp_ready), .resp_rdata(d_resp_rdata),
    .dn_req_valid(d_dn_req_valid), .dn_req_ready(d_dn_req_ready), .dn_req_addr(d_dn_req_addr),
    .dn_req_we(d_dn_req_we), .dn_req_wdata(d_dn_req_wdata), .dn_req_wstrb(d_dn_req_wstrb),
    .dn_resp_valid(d_dn_resp_valid), .dn_resp_ready(d_dn_resp_ready), .dn_resp_line(l2_resp_line)
  );

  l1_l2_arbiter arb (
    .clk, .rst_n,
    .up0_req_valid(i_dn_req_valid), .up0_req_ready(i_dn_req_ready), .up0_req_addr(i_dn_req_addr), .up0_req_we(i_dn_req_we),
    .up0_req_wdata(i_dn_req_wdata), .up0_req_wstrb(i_dn_req_wstrb), .up0_resp_valid(i_dn_resp_valid), .up0_resp_ready(i_dn_resp_ready),
    .up1_req_valid(d_dn_req_valid), .up1_req_ready(d_dn_req_ready), .up1_req_addr(d_dn_req_addr), .up1_req_we(d_dn_req_we),
    .up1_req_wdata(d_dn_req_wdata), .up1_req_wstrb(d_dn_req_wstrb), .up1_resp_valid(d_dn_resp_valid), .up1_resp_ready(d_dn_resp_ready),
    .l2_req_valid(a_req_valid), .l2_req_ready(a_req_ready), .l2_req_addr(a_req_addr), .l2_req_we(a_req_we),
    .l2_req_wdata(a_req_wdata), .l2_req_wstrb(a_req_wstrb), .l2_resp_valid(a_resp_valid), .l2_resp_ready(a_resp_ready)
  );

  l2_cache_ctrl l2 (
    .clk, .rst_n(rst_n_l2),
    .req_valid(a_req_valid), .req_ready(a_req_ready), .req_addr(a_req_addr),
    .req_we(a_req_we), .req_wdata(a_req_wdata), .req_wstrb(a_req_wstrb),
    .resp_valid(a_resp_valid), .resp_ready(a_resp_ready), .resp_line(l2_resp_line),
    .dn_req_valid(l2_dn_req_valid), .dn_req_ready(l2_dn_req_ready), .dn_req_addr(l2_dn_req_addr),
    .dn_req_we(l2_dn_req_we), .dn_req_line(l2_dn_req_line),
    .dn_resp_valid(l2_dn_resp_valid), .dn_resp_ready(l2_dn_resp_ready), .dn_resp_line(l2_dn_resp_line)
  );

  l3_stub mem (
    .clk, .rst_n, .hold_not_ready(1'b0),
    .req_valid(l2_dn_req_valid), .req_ready(l2_dn_req_ready), .req_addr(l2_dn_req_addr),
    .req_we(l2_dn_req_we), .req_line(l2_dn_req_line),
    .resp_valid(l2_dn_resp_valid), .resp_ready(l2_dn_resp_ready), .resp_line(l2_dn_resp_line)
  );

  task automatic check(input logic cond, input string msg);
    if (cond) $display("PASS: %s", msg);
    else begin
      $display("FAIL: %s", msg);
      errors++;
    end
  endtask

  // l3_stub's memory image: word w of the line at a holds (line_base + w).
  function automatic logic [31:0] image_word(input logic [31:0] a);
    image_word = (a & ~(mlc_pkg::L2_LINE_B - 1)) + ((a % mlc_pkg::L2_LINE_B) / 4);
  endfunction

  // ---- CPU drivers: the same sequences tb_l1_l2 uses, one set per port ----
  task automatic wait_ready_or_fail(input string what);
    int n;
    n = 0;
    while ((i_req_ready !== 1'b1 || d_req_ready !== 1'b1) && n < 400) begin
      @(posedge clk);
      n++;
    end
    check(i_req_ready === 1'b1 && d_req_ready === 1'b1, {what, ": both L1 controllers accept the next request again (no deadlock)"});
  endtask

  task automatic i_read(input logic [31:0] addr, output logic [31:0] data);
    @(posedge clk);
    i_req_valid <= 1'b1; i_req_addr <= addr; i_resp_ready <= 1'b1;
    wait (i_req_ready);
    @(posedge clk);
    i_req_valid <= 1'b0;
    wait (i_resp_valid);
    data = i_resp_rdata;
    @(posedge clk);
  endtask

  task automatic d_read(input logic [31:0] addr, output logic [31:0] data);
    @(posedge clk);
    d_req_valid <= 1'b1; d_req_we <= 1'b0; d_req_addr <= addr; d_resp_ready <= 1'b1;
    wait (d_req_ready);
    @(posedge clk);
    d_req_valid <= 1'b0;
    wait (d_resp_valid);
    data = d_resp_rdata;
    @(posedge clk);
  endtask

  task automatic d_write(input logic [31:0] addr, input logic [31:0] data);
    @(posedge clk);
    d_req_valid <= 1'b1; d_req_we <= 1'b1; d_req_addr <= addr; d_req_wdata <= data; d_req_wstrb <= 4'hF; d_resp_ready <= 1'b1;
    wait (d_req_ready);
    @(posedge clk);
    d_req_valid <= 1'b0;
  endtask

  task automatic d_write_strb(input logic [31:0] addr, input logic [31:0] data, input logic [3:0] strb);
    @(posedge clk);
    d_req_valid <= 1'b1; d_req_we <= 1'b1; d_req_addr <= addr; d_req_wdata <= data; d_req_wstrb <= strb; d_resp_ready <= 1'b1;
    wait (d_req_ready);
    @(posedge clk);
    d_req_valid <= 1'b0;
  endtask

  // A write per cycle for as long as L1-D accepts them (all hits on one resident line, each forwarded
  // to L2 as its own posted write): the traffic that would starve the instruction side under a fixed
  // priority for the data side. Assumes the caller is just after a clock edge.
  task automatic d_write_stream(input logic [31:0] base, input int n);
    int sent;
    sent = 0;
    d_req_valid <= 1'b1; d_req_we <= 1'b1; d_req_addr <= base; d_req_wdata <= 32'h7000_0000; d_req_wstrb <= 4'hF; d_resp_ready <= 1'b1;
    while (sent < n) begin
      @(posedge clk);
      if (d_req_ready) begin
        sent++;
        if (sent < n) begin d_req_addr <= base + 4 * sent; d_req_wdata <= 32'h7000_0000 + sent; end
        else d_req_valid <= 1'b0;
      end
    end
  endtask

  // What L2 accepted from the arbiter, in order: 1 for a request from the instruction side's region.
  logic        acc_from_i [$];
  logic        acc_we     [$];
  always @(posedge clk) if (rst_n && a_req_valid && a_req_ready) begin
    acc_from_i.push_back(a_req_addr[19:16] == 4'h4);
    acc_we.push_back(a_req_we);
  end

  task automatic l2_reset();
    rst_n_l2 = 1'b0;
    repeat (3) @(posedge clk);
    rst_n_l2 = 1'b1;
    @(posedge clk);
  endtask

  // Fetch lines (I side) and data lines (D side) live in different 4 KiB-aligned regions; a line
  // at region + 0x2000 shares its L1 set (bits 11:5) and so evicts it.
  localparam logic [31:0] IA = 32'h0004_0000;   // L1-I set 0
  localparam logic [31:0] DA = 32'h0008_0000;   // L1-D set 0
  localparam logic [31:0] SH = 32'h0006_0100;   // a line both sides use

  logic [31:0] gi, gd, gx;

  initial begin
    rst_n = 1'b0; rst_n_l2 = 1'b0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1; rst_n_l2 = 1'b1;
    @(posedge clk);

    // ---- both sides miss in the same cycle: each gets its own word ----
    fork
      i_read(IA + 4, gi);
      d_read(DA + 8, gd);
    join
    check(gi === image_word(IA + 4), "a fetch and a load that miss together: the fetch gets its own word");
    check(gd === image_word(DA + 8), "a fetch and a load that miss together: the load gets its own word");

    // ---- hits on both sides ----
    fork
      i_read(IA + 4, gi);
      d_read(DA + 8, gd);
    join
    check(gi === image_word(IA + 4) && gd === image_word(DA + 8), "both L1 caches hit on the lines they just filled");

    // ---- the unified L2: a line one side brought in is an L2 hit for the other side ----
    d_read(SH, gd);
    i_read(SH + 8, gi);
    check(gi === image_word(SH + 8), "a fetch of a line the data side already brought in is served by L2");

    // ---- a store reaches L2 and a later fetch of that line sees it (unified L2) ----
    d_read(SH + 32'h40, gd);                                   // line in L1-D and L2
    d_write(SH + 32'h44, 32'h5151_0001);                       // L1-D write hit, forwarded to L2
    i_read(SH + 32'h44, gi);                                   // L1-I misses, L2 hits on the written line
    check(gi === 32'h5151_0001, "a store from the data side is visible to a later fetch through L2");

    // ---- one side fills while the other forwards stores: nothing is lost on either side ----
    begin
      logic [31:0] gt [0:3];
      fork
        begin : istream
          for (int k = 0; k < 8; k++) begin
            i_read(IA + 32'h1000 + k * 32'h20 + 4, gi);
            check(gi === image_word(IA + 32'h1000 + k * 32'h20 + 4), $sformatf("fetch %0d, concurrent with stores, returns its own word", k));
          end
        end
        begin : dstream
          for (int k = 0; k < 4; k++) begin
            d_read(DA + 32'h1000 + k * 32'h20, gd);
            d_write(DA + 32'h1000 + k * 32'h20 + 4, 32'hA000_0000 + k);
          end
        end
      join
      wait_ready_or_fail("stores forwarded during instruction fills");
      for (int k = 0; k < 4; k++) begin
        d_read(DA + 32'h1000 + k * 32'h20 + 32'h2000, gd);             // evicts line k from L1-D (same L1 set)
        d_read(DA + 32'h1000 + k * 32'h20 + 4, gt[k]);                 // refilled from L2, which must hold the store
        check(gt[k] === 32'hA000_0000 + k, $sformatf("store %0d reached L2 while the instruction side was filling", k));
      end
    end

    // ---- a stream of stores must not starve an instruction fill ----
    d_read(DA + 32'h6000, gd);                                 // the line the stores hit
    d_read(DA + 32'h6000 + 32'h2000, gd);                      // evict it again...
    d_read(DA + 32'h6000, gd);                                 // ...and bring it back, so the stream is all hits
    @(posedge clk);
    acc_from_i.delete(); acc_we.delete();
    fork
      d_write_stream(DA + 32'h6000, 8);
      i_read(IA + 32'h6000 + 4, gi);
    join
    #1;
    wait_ready_or_fail("a stream of stores beside an instruction fill");
    check(gi === image_word(IA + 32'h6000 + 4), "the fetch asked for beside a stream of stores gets its own word");
    begin
      int first_i;
      first_i = -1;
      for (int q = 0; q < acc_from_i.size(); q++) if (first_i < 0 && acc_from_i[q]) first_i = q;
      check(first_i >= 0 && first_i <= 2, "the instruction fill is accepted within the first few requests of a store stream");
      check(acc_from_i.size() == 9, "the stream's eight stores and the fill were all accepted exactly once");
    end
    d_read(DA + 32'h6000 + 32'h2000, gd);                      // evict the line from L1-D; L2 must hold all eight stores
    for (int w = 0; w < 8; w++) begin
      d_read(DA + 32'h6000 + w * 4, gx);
      check(gx === 32'h7000_0000 + w, $sformatf("store %0d of the stream reached L2", w));
    end

    // ---- both L1 controllers miss at once and L2 hits for both: each hit response goes to the side being accepted ----
    // (a response routed by anything but "the requester being accepted" hands one side the other's word)
    d_read(DA + 32'h0A00, gd);                                 // X: in L1-D and L2
    d_read(DA + 32'h0B00, gd);                                 // Y: in L1-D and L2
    d_read(DA + 32'h0A00 + 32'h2000, gd);                      // evict X from L1-D, it stays in L2
    i_read(IA + 32'h0C00, gi);                                 // the instruction side was accepted last
    fork
      i_read(DA + 32'h0B00 + 4, gi);                           // L1-I miss, L2 hit on Y
      d_read(DA + 32'h0A00 + 8, gd);                           // L1-D miss, L2 hit on X
    join
    check(gi === image_word(DA + 32'h0B00 + 4), "a tie of two L2 hits (instruction side accepted last): the fetch gets its own word");
    check(gd === image_word(DA + 32'h0A00 + 8), "a tie of two L2 hits (instruction side accepted last): the load gets its own word");
    d_read(DA + 32'h0A00 + 32'h2000, gd);                      // evict X from L1-D again; the data side was accepted last
    i_read(DA + 32'h0B00 + 32'h2000, gi);                      // evict Y from L1-I
    d_read(DA + 32'h0C40, gd);
    fork
      i_read(DA + 32'h0B00 + 12, gi);
      d_read(DA + 32'h0A00 + 16, gd);
    join
    check(gi === image_word(DA + 32'h0B00 + 12), "a tie of two L2 hits (data side accepted last): the fetch gets its own word");
    check(gd === image_word(DA + 32'h0A00 + 16), "a tie of two L2 hits (data side accepted last): the load gets its own word");

    // ---- a store with a partial byte strobe keeps its strobe all the way to L2 ----
    d_read(DA + 32'h7000, gd);
    d_write_strb(DA + 32'h7004, 32'hAABB_CCDD, 4'b0101);       // bytes 0 and 2 only
    d_read(DA + 32'h7000 + 32'h2000, gd);                      // evict from L1-D; the merge must have happened in L2
    d_read(DA + 32'h7004, gx);
    check(gx === ((image_word(DA + 32'h7004) & 32'hFF00_FF00) | (32'hAABB_CCDD & 32'h00FF_00FF)),
          "a partial-strobe store reached L2 with its byte strobes");

    // ---- L2 forgets a line L1-D holds: a store to it is a posted write miss at L2 ----
    // A write miss makes L2 busy behind req_ready, with no response. The arbiter must neither wait for
    // one nor lose the request of the other side that arrives while L2 is busy.
    d_read(DA + 32'h3000, gd);
    l2_reset();
    fork
      d_write(DA + 32'h3000 + 4, 32'hB000_0001);
      begin repeat (2) @(posedge clk); i_read(IA + 32'h3000 + 8, gi); end
    join
    wait_ready_or_fail("a store forwarded to an L2 write miss, with a fetch behind it");
    check(gi === image_word(IA + 32'h3000 + 8), "a fetch asked for while L2 was busy with a write miss is served with its own word");
    d_read(DA + 32'h3000 + 32'h2000, gd);                          // evict from L1-D
    d_read(DA + 32'h3000 + 4, gx);
    check(gx === 32'hB000_0001, "the store forwarded to the L2 write miss was write-allocated in L2");

    // ---- two stores in a row to lines L2 forgot, then fetches on both sides ----
    d_read(DA + 32'h4000, gd);
    d_read(DA + 32'h4020, gd);
    l2_reset();
    d_write(DA + 32'h4000 + 4, 32'hC000_0001);
    d_write(DA + 32'h4020 + 4, 32'hC000_0002);
    fork
      i_read(IA + 32'h4000 + 4, gi);
      d_read(DA + 32'h5000, gd);
    join
    check(gi === image_word(IA + 32'h4000 + 4) && gd === image_word(DA + 32'h5000), "after two stores to L2 write misses both sides still fill with their own words");
    d_read(DA + 32'h4000 + 32'h2000, gd);
    d_read(DA + 32'h4020 + 32'h2000, gd);
    d_read(DA + 32'h4000 + 4, gx);
    check(gx === 32'hC000_0001, "the first of two back-to-back stores reached L2");
    d_read(DA + 32'h4020 + 4, gx);
    check(gx === 32'hC000_0002, "the second of two back-to-back stores reached L2");

    if (errors == 0) begin
      $display("** ALL TESTS PASSED **");
      $finish;
    end else begin
      $display("** %0d TEST(S) FAILED **", errors);
      $fatal(1);
    end
  end

  initial begin
    #2000000;
    $display("FAIL: simulation watchdog timeout");
    errors++;
    $fatal(1);
  end

endmodule
