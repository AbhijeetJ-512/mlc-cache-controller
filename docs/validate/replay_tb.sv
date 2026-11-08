`timescale 1ns/1ps
// replay_tb - drives the REAL mlc_cache_top (and the REAL sim/axi_mem_model.sv) with the CPU-port inputs and memory stall pattern
// recorded from the explorer's JavaScript model, and prints, per cycle, every output and unit state the model predicted.
// +vec=<file>  +out=<file>  +n=<cycles>
// vec file: line 1 = r_gap first_gap b_delay rresp_err_beat force_rresp force_bresp (hex); then one line per cycle, 44 hex fields:
//   inputs [0..11]  : i_req_valid i_req_addr i_resp_ready d_req_valid d_req_addr d_req_we d_req_wdata d_req_wstrb d_resp_ready stall_ar stall_aw stall_w
//   expected [12..43]: see the print below (data fields are zero unless their valid is high)
module replay_tb;
  logic clk = 1'b0;
  always #5 clk = ~clk;
  logic rst_n;
  logic        i_req_valid = 1'b0, i_resp_ready = 1'b1;
  logic [31:0] i_req_addr  = '0;
  wire         i_req_ready, i_resp_valid;
  wire  [31:0] i_resp_rdata;
  logic        d_req_valid = 1'b0, d_req_we = 1'b0, d_resp_ready = 1'b1;
  logic [31:0] d_req_addr  = '0, d_req_wdata = '0;
  logic [3:0]  d_req_wstrb = '0;
  wire         d_req_ready, d_resp_valid;
  wire  [31:0] d_resp_rdata;
  wire [31:0] awaddr, araddr, wdata, rdata;
  wire [7:0]  awlen, arlen;
  wire [2:0]  awsize, arsize, awprot, arprot;
  wire [1:0]  awburst, arburst, bresp, rresp;
  wire [3:0]  awcache, arcache, awqos, arqos, awregion, arregion, wstrb;
  wire        awlock, arlock, awvalid, awready, wlast, wvalid, wready, bvalid, bready, arvalid, arready, rlast, rvalid, rready;
  wire        mem_err;
  logic       stall_ar = 1'b0, stall_aw = 1'b0, stall_w = 1'b0;
  logic [3:0] r_gap = 4'd0;
  logic [1:0] force_rresp = 2'b00, force_bresp = 2'b00;

  mlc_cache_top dut (
    .clk, .rst_n,
    .i_req_valid, .i_req_ready, .i_req_addr, .i_resp_valid, .i_resp_ready, .i_resp_rdata,
    .d_req_valid, .d_req_ready, .d_req_addr, .d_req_we, .d_req_wdata, .d_req_wstrb, .d_resp_valid, .d_resp_ready, .d_resp_rdata,
    .m_axi_awaddr(awaddr), .m_axi_awlen(awlen), .m_axi_awsize(awsize), .m_axi_awburst(awburst), .m_axi_awlock(awlock),
    .m_axi_awcache(awcache), .m_axi_awprot(awprot), .m_axi_awqos(awqos), .m_axi_awregion(awregion),
    .m_axi_awvalid(awvalid), .m_axi_awready(awready),
    .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
    .m_axi_bresp(bresp), .m_axi_bvalid(bvalid), .m_axi_bready(bready),
    .m_axi_araddr(araddr), .m_axi_arlen(arlen), .m_axi_arsize(arsize), .m_axi_arburst(arburst), .m_axi_arlock(arlock),
    .m_axi_arcache(arcache), .m_axi_arprot(arprot), .m_axi_arqos(arqos), .m_axi_arregion(arregion),
    .m_axi_arvalid(arvalid), .m_axi_arready(arready),
    .m_axi_rdata(rdata), .m_axi_rresp(rresp), .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready),
    .mem_err
  );
  axi_mem_model #(.DATA_W(32), .EXP_LEN(15), .EXP_SIZE(2), .EXP_ALIGN_B(64)) mem (
    .clk, .rst_n,
    .stall_ar, .stall_aw, .stall_w, .r_gap, .force_rresp, .force_bresp,
    .awaddr, .awlen, .awsize, .awburst, .awvalid, .awready,
    .wdata, .wstrb, .wlast, .wvalid, .wready,
    .bresp, .bvalid, .bready,
    .araddr, .arlen, .arsize, .arburst, .arvalid, .arready,
    .rdata, .rresp, .rlast, .rvalid, .rready
  );

  string vecfile, outfile;
  int    n, fd, fo, c, k;
  logic [31:0] v [0:43];
  logic [31:0] hgap, hfirst, hbd, hrerr, hfrr, hfbr;
  initial begin
    if (!$value$plusargs("vec=%s", vecfile) || !$value$plusargs("out=%s", outfile) || !$value$plusargs("n=%d", n)) begin
      $display("replay_tb: +vec= +out= +n= required"); $finish;
    end
    fd = $fopen(vecfile, "r"); fo = $fopen(outfile, "w");
    k = $fscanf(fd, "%h", hgap); k = $fscanf(fd, "%h", hfirst); k = $fscanf(fd, "%h", hbd);
    k = $fscanf(fd, "%h", hrerr); k = $fscanf(fd, "%h", hfrr); k = $fscanf(fd, "%h", hfbr);
    r_gap = hgap[3:0]; mem.first_gap_en = hfirst[0]; mem.b_delay = int'(hbd);
    mem.rresp_err_beat = (hrerr == 32'hFFFF) ? -1 : int'(hrerr);
    force_rresp = hfrr[1:0]; force_bresp = hfbr[1:0];
    rst_n = 1'b0;
    repeat (4) @(posedge clk);
    #1 rst_n = 1'b1;
    repeat (2) @(posedge clk);          // reset_sync releases the units two clocks after rst_n
    for (c = 0; c < n; c++) begin
      for (k = 0; k < 44; k++) begin if ($fscanf(fd, "%h", v[k]) != 1) begin $display("replay_tb: vector file too short at cycle %0d", c+1); $finish; end end
      #1;
      i_req_valid = v[0][0]; i_req_addr = v[1]; i_resp_ready = v[2][0];
      d_req_valid = v[3][0]; d_req_addr = v[4]; d_req_we = v[5][0]; d_req_wdata = v[6]; d_req_wstrb = v[7][3:0]; d_resp_ready = v[8][0];
      stall_ar = v[9][0]; stall_aw = v[10][0]; stall_w = v[11][0];
      #7;
      $fdisplay(fo, "%0h %0h %0h %0h %0h %0h %0h %0h %0h %0h %0h %0h %0h %0h %0h %0h %0h %0h %0h %0h %0h %0h %0h %0h %0h %0h %0h %0h %0h %0h %0h %0h",
        i_req_ready, i_resp_valid, i_resp_valid ? i_resp_rdata : 32'h0,
        d_req_ready, d_resp_valid, d_resp_valid ? d_resp_rdata : 32'h0,
        awvalid, awvalid ? awaddr : 32'h0, wvalid, wvalid ? wdata : 32'h0, wlast, bready,
        arvalid, arvalid ? araddr : 32'h0, rready, mem_err,
        arready, awready, wready, bvalid, rvalid, rvalid ? rdata : 32'h0, rvalid ? rlast : 1'b0, rvalid ? rresp : 2'b0,
        $unsigned(dut.u_l1i.u_core.state), $unsigned(dut.u_l1d.u_core.state), $unsigned(dut.u_l2.state), $unsigned(dut.u_l3.core.state),
        $unsigned(dut.u_axi.state), dut.u_arb.busy, dut.u_arb.owner, dut.u_arb.last);
      @(posedge clk);
    end
    $fclose(fo);
    $display("replay_tb: %0d cycles replayed, AXI PROTO errors seen by the real memory model: %0d", n, mem.proto_errors);
    $finish;
  end
endmodule
