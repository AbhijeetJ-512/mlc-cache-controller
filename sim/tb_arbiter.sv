`timescale 1ns/1ps

// Tier-1 test of l1_l2_arbiter alone (D-033). Two requester drivers behave like the two L1
// controllers at their L2-facing ports (a read holds req_valid and resp_ready until its response
// arrives; a write is posted and is done when req_ready accepts it), and a small behavioural model
// stands in for L2's upstream port with the same contract (blocking after a read miss, a hit
// answered in its accept cycle only if resp_ready is high, writes never answered).
//
// Addresses say who asked and what L2 does with them: 0x001x_xxxx is requester 0 (L1-I), 0x002x_xxxx
// requester 1 (L1-D); address bit 12 set means L2 hits, clear means it misses. The line L2 returns is
// a function of the address, so a requester that is handed somebody else's response sees the wrong line.
module tb_arbiter;

  localparam int MISS_LAT   = 3;   // cycles between accepting a read miss and answering it
  localparam int WBUSY_LAT  = 2;   // cycles L2 stays busy behind an accepted write miss

  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n;
  int errors = 0;

  // ---- requester-side signals, one element per requester ----
  logic        q_valid [0:1];
  logic        q_we    [0:1];
  logic [31:0] q_addr  [0:1];
  logic [31:0] q_wdata [0:1];
  logic [3:0]  q_wstrb [0:1];
  logic        q_rdr   [0:1];       // resp_ready
  wire         r_ready [0:1];       // req_ready
  wire         r_valid [0:1];       // resp_valid
  bit          waiting [0:1];       // the driver is waiting for a response

  // ---- L2-side signals ----
  wire         l2_req_valid, l2_req_ready, l2_req_we, l2_resp_valid, l2_resp_ready;
  wire  [31:0] l2_req_addr, l2_req_wdata;
  wire  [3:0]  l2_req_wstrb;
  wire  [255:0] l2_resp_line;

  l1_l2_arbiter dut (
    .clk, .rst_n,
    .up0_req_valid(q_valid[0]), .up0_req_ready(r_ready[0]), .up0_req_addr(q_addr[0]), .up0_req_we(q_we[0]),
    .up0_req_wdata(q_wdata[0]), .up0_req_wstrb(q_wstrb[0]), .up0_resp_valid(r_valid[0]), .up0_resp_ready(q_rdr[0]),
    .up1_req_valid(q_valid[1]), .up1_req_ready(r_ready[1]), .up1_req_addr(q_addr[1]), .up1_req_we(q_we[1]),
    .up1_req_wdata(q_wdata[1]), .up1_req_wstrb(q_wstrb[1]), .up1_resp_valid(r_valid[1]), .up1_resp_ready(q_rdr[1]),
    .l2_req_valid, .l2_req_ready, .l2_req_addr, .l2_req_we, .l2_req_wdata, .l2_req_wstrb,
    .l2_resp_valid, .l2_resp_ready
  );

  // ---- the L2 port model ----
  function automatic logic [255:0] line_of(input logic [31:0] a);
    for (int w = 0; w < 8; w++) line_of[w*32 +: 32] = (a & ~32'h1F) + w;
  endfunction

  typedef enum logic [1:0] {M_IDLE, M_MISS, M_RESP, M_WBUSY} mstate_e;
  mstate_e m;
  int          cnt;
  logic [31:0] saved_addr;
  wire         is_hit = l2_req_addr[12];

  assign l2_req_ready  = (m == M_IDLE) && (!l2_req_valid || !is_hit || l2_req_we || l2_resp_ready);
  assign l2_resp_valid = (m == M_RESP) || (m == M_IDLE && l2_req_valid && l2_req_ready && is_hit && !l2_req_we);
  assign l2_resp_line  = (m == M_RESP) ? line_of(saved_addr) : line_of(l2_req_addr);

  // What L2 accepted, in order.
  logic [31:0] acc_addr [$];
  logic        acc_we   [$];
  logic [31:0] acc_data [$];
  logic [3:0]  acc_strb [$];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) m <= M_IDLE;
    else case (m)
      M_IDLE: if (l2_req_valid && l2_req_ready) begin
        acc_addr.push_back(l2_req_addr); acc_we.push_back(l2_req_we); acc_data.push_back(l2_req_wdata); acc_strb.push_back(l2_req_wstrb);
        if (l2_req_we) begin
          if (!is_hit) begin m <= M_WBUSY; cnt <= WBUSY_LAT; end
        end else if (!is_hit) begin
          saved_addr <= l2_req_addr; m <= M_MISS; cnt <= MISS_LAT;
        end
      end
      M_MISS:  if (cnt == 0) m <= M_RESP; else cnt <= cnt - 1;
      M_RESP:  if (l2_resp_ready) m <= M_IDLE;
      M_WBUSY: if (cnt == 0) m <= M_IDLE; else cnt <= cnt - 1;
    endcase
  end

  task automatic check(input logic cond, input string msg);
    if (cond) $display("PASS: %s", msg);
    else begin
      $display("FAIL: %s", msg);
      errors++;
    end
  endtask

  // ---- monitors, sampled mid-cycle so they never race the drivers ----
  int resp_both = 0, resp_stray = 0, ready_both = 0, shown_while_outstanding = 0;
  always @(negedge clk) if (rst_n) begin
    if (r_valid[0] && r_valid[1]) resp_both++;
    if (r_valid[0] && !waiting[0]) resp_stray++;
    if (r_valid[1] && !waiting[1]) resp_stray++;
    if (l2_resp_valid && !(r_valid[0] || r_valid[1])) resp_stray++;
    if (!l2_resp_valid && (r_valid[0] || r_valid[1])) resp_stray++;
    if (r_ready[0] && r_ready[1]) ready_both++;
    // L2 must not be shown a request while one of its reads is outstanding (04_interfaces.md section 2)
    if ((m == M_MISS || m == M_RESP) && l2_req_valid) shown_while_outstanding++;
  end

  // ---- requester drivers (they assume the caller is just after a clock edge) ----
  task automatic read_now(input int s, input logic [31:0] addr, output logic [255:0] line);
    bit done;
    q_valid[s] <= 1'b1; q_we[s] <= 1'b0; q_addr[s] <= addr; q_rdr[s] <= 1'b1;
    waiting[s] = 1'b1;
    done = 1'b0;
    while (!done) begin
      @(posedge clk);
      if (r_valid[s] && q_rdr[s]) begin line = l2_resp_line; done = 1'b1; end
    end
    q_valid[s] <= 1'b0; q_rdr[s] <= 1'b0;
    waiting[s] = 1'b0;
  endtask

  task automatic write_now(input int s, input logic [31:0] addr, input logic [31:0] data, input logic [3:0] strb);
    bit done;
    q_valid[s] <= 1'b1; q_we[s] <= 1'b1; q_addr[s] <= addr; q_wdata[s] <= data; q_wstrb[s] <= strb; q_rdr[s] <= 1'b0;
    done = 1'b0;
    while (!done) begin
      @(posedge clk);
      if (r_ready[s]) done = 1'b1;
    end
    q_valid[s] <= 1'b0;
  endtask

  function automatic logic [31:0] ia(input int hit, input int n); ia = 32'h0010_0000 + hit * 32'h1000 + n * 32'h20 + (n % 8) * 4; endfunction
  function automatic logic [31:0] da(input int hit, input int n); da = 32'h0020_0000 + hit * 32'h1000 + n * 32'h20 + (n % 8) * 4; endfunction

  task automatic idle(input int n); repeat (n) @(posedge clk); endtask

  task automatic clear_log();
    acc_addr.delete(); acc_we.delete(); acc_data.delete(); acc_strb.delete();
  endtask

  task automatic reset_all();
    rst_n <= 1'b0;
    repeat (3) @(posedge clk);
    rst_n <= 1'b1;
    @(posedge clk);
  endtask

  logic [255:0] l0, l1;
  bit got_late, accepted_once;

  initial begin
    for (int i = 0; i < 2; i++) begin
      q_valid[i] = 0; q_we[i] = 0; q_addr[i] = '0; q_wdata[i] = '0; q_wstrb[i] = '0; q_rdr[i] = 0; waiting[i] = 0;
    end
    rst_n = 1'b0;
    repeat (3) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // ---- one requester at a time: hit, miss, and nobody else hears about it ----
    read_now(0, ia(1, 0), l0);
    check(l0 === line_of(ia(1, 0)), "requester 0: a read that hits in L2 gets its own line");
    idle(1);
    read_now(1, da(1, 0), l1);
    check(l1 === line_of(da(1, 0)), "requester 1: a read that hits in L2 gets its own line");
    idle(1);
    read_now(0, ia(0, 1), l0);
    check(l0 === line_of(ia(0, 1)), "requester 0: a read that misses in L2 gets its own line");
    idle(1);
    read_now(1, da(0, 1), l1);
    check(l1 === line_of(da(0, 1)), "requester 1: a read that misses in L2 gets its own line");
    idle(1);
    #1;
    check(acc_addr.size() == 4, "L2 accepted exactly the four reads");

    // ---- both ask in the same cycle: both are served, the tie goes round-robin ----
    reset_all();
    clear_log();
    fork
      read_now(0, ia(0, 2), l0);
      read_now(1, da(0, 2), l1);
    join
    #1;
    check(l0 === line_of(ia(0, 2)) && l1 === line_of(da(0, 2)), "two simultaneous misses: each requester gets its own line");
    check(acc_addr.size() == 2 && acc_addr[0] == ia(0, 2) && acc_addr[1] == da(0, 2),
          "after reset a tie goes to requester 0, then the other one is served");
    // requester 0 is now the most recent winner when it is served alone, so the next tie goes to requester 1
    idle(2);
    read_now(0, ia(1, 3), l0);
    idle(2);
    clear_log();
    fork
      read_now(0, ia(0, 3), l0);
      read_now(1, da(0, 3), l1);
    join
    #1;
    check(acc_addr.size() == 2 && acc_addr[0] == da(0, 3) && acc_addr[1] == ia(0, 3),
          "after requester 0 won last, a tie goes to requester 1 first");

    // round-robin means "the one not accepted last", not "the one that did not win the last tie": after reset
    // one lone request from requester 0, then a tie, must go to requester 1 first
    reset_all();
    clear_log();
    read_now(0, ia(1, 40), l0);
    idle(2);
    clear_log();
    fork
      read_now(0, ia(0, 41), l0);
      read_now(1, da(0, 41), l1);
    join
    #1;
    check(acc_addr.size() == 2 && acc_addr[0] == da(0, 41), "after requester 0 was accepted alone, a tie goes to requester 1");

    // ---- both ask at once and L2 hits for both: each hit response goes to the requester being accepted ----
    reset_all();
    clear_log();
    fork
      read_now(0, ia(1, 60), l0);
      read_now(1, da(1, 60), l1);
    join
    #1;
    check(l0 === line_of(ia(1, 60)) && l1 === line_of(da(1, 60)), "a tie of two L2 hits after reset: each requester gets its own line");
    check(acc_addr.size() == 2 && acc_addr[0] == ia(1, 60), "a tie of two hits is served requester 0 first after reset");
    read_now(0, ia(1, 61), l0);
    idle(1);
    fork
      read_now(0, ia(1, 62), l0);
      read_now(1, da(1, 62), l1);
    join
    #1;
    check(l0 === line_of(ia(1, 62)) && l1 === line_of(da(1, 62)), "a tie of two L2 hits after requester 0 won: each gets its own line");
    read_now(1, da(1, 63), l1);
    idle(1);
    fork
      read_now(0, ia(1, 64), l0);
      read_now(1, da(1, 64), l1);
    join
    #1;
    check(l0 === line_of(ia(1, 64)) && l1 === line_of(da(1, 64)), "a tie of two L2 hits after requester 1 won: each gets its own line");
    // one side hits and the other misses in the same cycle
    idle(1);
    fork
      read_now(0, ia(0, 65), l0);
      read_now(1, da(1, 65), l1);
    join
    #1;
    check(l0 === line_of(ia(0, 65)) && l1 === line_of(da(1, 65)), "a tie of a miss and a hit: each requester gets its own line");

    // ---- a hit on one side while the other side has a miss outstanding ----
    reset_all();
    clear_log();
    fork
      read_now(0, ia(0, 4), l0);                                    // miss, takes MISS_LAT + 2 cycles
      begin idle(1); read_now(1, da(1, 4), l1); end                 // asks while the miss is outstanding
    join
    #1;
    check(l0 === line_of(ia(0, 4)) && l1 === line_of(da(1, 4)), "a hit asked for during the other side's miss gets its own line, not the miss's");
    check(acc_addr.size() == 2 && acc_addr[0] == ia(0, 4) && acc_addr[1] == da(1, 4),
          "the second request is not accepted until the first read's response has been taken");

    // ---- the owner's resp_ready decides, nobody else's ----
    reset_all();
    clear_log();
    fork
      begin  // requester 0 takes its response late
        q_valid[0] <= 1'b1; q_we[0] <= 1'b0; q_addr[0] <= ia(0, 5); q_rdr[0] <= 1'b0; waiting[0] = 1'b1;
        idle(MISS_LAT + 6);
        check(m == M_RESP, "the miss response waits for its owner's resp_ready");
        q_rdr[0] <= 1'b1;
        got_late = 1'b0;
        while (!got_late) begin @(posedge clk); if (r_valid[0] && q_rdr[0]) begin l0 = l2_resp_line; got_late = 1'b1; end end
        q_valid[0] <= 1'b0; q_rdr[0] <= 1'b0; waiting[0] = 1'b0;
      end
      begin idle(2); read_now(1, da(0, 5), l1); end                  // asks, with resp_ready high, while 0 is outstanding
    join
    #1;
    check(l0 === line_of(ia(0, 5)) && l1 === line_of(da(0, 5)), "late resp_ready: both requesters still get their own lines");
    check(acc_addr[0] == ia(0, 5) && acc_addr[1] == da(0, 5), "late resp_ready: the other side was served after, not instead");

    // ---- a posted write is accepted by req_ready alone, and a write behind a read waits ----
    reset_all();
    clear_log();
    fork
      read_now(0, ia(0, 6), l0);
      begin idle(1); write_now(1, da(1, 6), 32'hD00D_0001, 4'h6); end
    join
    #1;
    check(l0 === line_of(ia(0, 6)), "a write forwarded during a read miss does not disturb the read's response");
    check(acc_addr.size() == 2 && acc_we[0] == 1'b0 && acc_we[1] == 1'b1 && acc_data[1] == 32'hD00D_0001 && acc_strb[1] == 4'h6 && acc_addr[1] == da(1, 6),
          "the write waited for the read's response, then reached L2 intact");
    idle(2);
    clear_log();
    write_now(1, da(0, 7), 32'hD00D_0002, 4'hA);                            // write miss: L2 stays busy behind it
    read_now(0, ia(1, 7), l0);                                        // asks while L2 is busy with the write
    #1;
    check(l0 === line_of(ia(1, 7)), "a read asked for while L2 is busy behind a write miss is served afterwards");
    check(acc_addr.size() == 2 && acc_we[0] == 1'b1 && acc_data[0] == 32'hD00D_0002 && acc_strb[0] == 4'hA && acc_we[1] == 1'b0,
          "the read is accepted only after L2 finished the write, and the write arrived intact");

    // ---- both requesters write in the same cycle: both writes arrive intact, requester 0 first after reset ----
    reset_all();
    clear_log();
    fork
      write_now(0, ia(1, 70), 32'h1111_0001, 4'h3);
      write_now(1, da(1, 70), 32'h2222_0002, 4'hC);
    join
    #1;
    check(acc_addr.size() == 2 && acc_we[0] && acc_we[1] &&
          acc_addr[0] == ia(1, 70) && acc_data[0] == 32'h1111_0001 && acc_strb[0] == 4'h3 &&
          acc_addr[1] == da(1, 70) && acc_data[1] == 32'h2222_0002 && acc_strb[1] == 4'hC,
          "two writes in the same cycle: each reaches L2 with its own address, data and strobes, requester 0 first");
    idle(2);

    // ---- fairness: neither side can starve the other ----
    reset_all();
    clear_log();
    fork
      begin int i; @(posedge clk); for (i = 0; i < 4; i++) read_now(0, ia(0, 8 + i), l0); end        // streams of misses
      begin int i; @(posedge clk); for (i = 0; i < 4; i++) read_now(1, da(0, 8 + i), l1); end
    join
    #1;
    check(acc_addr.size() == 8, "two streams of four read misses: all eight were served");
    begin
      bit alt;
      logic [31:0] a;
      alt = 1'b1;
      for (int i = 0; i < 8; i++) begin
        a = acc_addr[i];
        alt &= (a[23:20] == ((i % 2 == 0) ? 4'h1 : 4'h2));
      end
      check(alt, "two continuously asking requesters alternate, starting with requester 0");
    end
    idle(2);
    clear_log();
    fork
      begin int i; @(posedge clk); for (i = 0; i < 4; i++) read_now(0, ia(0, 20 + i), l0); end        // read misses against a write stream
      begin int i; @(posedge clk); for (i = 0; i < 12; i++) write_now(1, da(1, i), 32'hFEED_0000 + i, 4'hF); end
    join
    #1;
    begin
      int reads_seen, writes_between, worst;
      reads_seen = 0; writes_between = 0; worst = 0;
      for (int i = 0; i < acc_addr.size(); i++) begin
        if (!acc_we[i]) begin
          reads_seen++;
          if (writes_between > worst) worst = writes_between;
          writes_between = 0;
        end else if (reads_seen < 4) begin
          writes_between++;
        end
      end
      check(reads_seen == 4, "against a continuous write stream all four reads were served");
      check(worst <= 1, "at most one write is served between two of the reads: the write stream cannot starve them");
    end

    // ---- fairness while L2 stalls: write misses keep L2 busy behind each accepted write ----
    reset_all();
    clear_log();
    fork
      begin int i; @(posedge clk); for (i = 0; i < 4; i++) read_now(0, ia(1, 50 + i), l0); end
      begin int i; @(posedge clk); for (i = 0; i < 12; i++) write_now(1, da(0, 50 + i), 32'hBEEF_0000 + i, 4'hF); end
    join
    #1;
    begin
      int reads_seen, writes_between, worst;
      reads_seen = 0; writes_between = 0; worst = 0;
      for (int i = 0; i < acc_addr.size(); i++) begin
        if (!acc_we[i]) begin
          reads_seen++;
          if (writes_between > worst) worst = writes_between;
          writes_between = 0;
        end else if (reads_seen < 4) begin
          writes_between++;
        end
      end
      check(reads_seen == 4, "against a stream of write misses all four reads were served");
      check(worst <= 1, "at most one write miss is served between two reads: a stalled L2 does not let the writes starve the reads");
    end
    idle(2);

    // ---- a requester that drops its read request as soon as it is accepted still gets its response ----
    // (the L1 controllers hold the request through the fill, but the arbiter must not depend on that)
    reset_all();
    clear_log();
    q_valid[1] <= 1'b1; q_we[1] <= 1'b0; q_addr[1] <= da(0, 72); q_rdr[1] <= 1'b1; waiting[1] = 1'b1;
    accepted_once = 1'b0;
    while (!accepted_once) begin @(posedge clk); if (r_ready[1]) accepted_once = 1'b1; end
    q_valid[1] <= 1'b0;
    got_late = 1'b0;
    while (!got_late) begin @(posedge clk); if (r_valid[1] && q_rdr[1]) begin l1 = l2_resp_line; got_late = 1'b1; end end
    q_rdr[1] <= 1'b0; waiting[1] = 1'b0;
    #1;
    check(l1 === line_of(da(0, 72)), "a requester that drops its read request once accepted still gets its response");
    idle(1);
    read_now(0, ia(1, 72), l0);
    check(l0 === line_of(ia(1, 72)), "and the arbiter is free for the next request");

    // ---- reset in the middle of an outstanding read leaves the arbiter idle and usable ----
    reset_all();
    clear_log();
    q_valid[0] <= 1'b1; q_we[0] <= 1'b0; q_addr[0] <= ia(0, 30); q_rdr[0] <= 1'b1; waiting[0] = 1'b1;
    idle(3);                                                           // accepted, the miss is outstanding
    rst_n <= 1'b0;
    idle(2);
    q_valid[0] <= 1'b0; q_rdr[0] <= 1'b0; waiting[0] = 1'b0;
    idle(1);
    rst_n <= 1'b1;
    idle(2);
    clear_log();
    read_now(1, da(1, 31), l1);
    check(l1 === line_of(da(1, 31)), "after a reset in the middle of a read requester 1 is served normally");
    idle(1);
    read_now(0, ia(0, 31), l0);
    check(l0 === line_of(ia(0, 31)), "and so is requester 0, with a miss");

    // ---- things that must never happen anywhere in the run ----
    check(resp_both == 0, "a response was never given to both requesters");
    check(resp_stray == 0, "a response was never given to a requester that was not waiting, or dropped");
    check(ready_both == 0, "both requesters were never told their request was accepted in the same cycle");
    check(shown_while_outstanding == 0, "L2 was never shown a request while one of its reads was outstanding");

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
