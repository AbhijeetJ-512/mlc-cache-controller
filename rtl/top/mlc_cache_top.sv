// mlc_cache_top - the whole hierarchy as one IP (D-034). Structural only: this file instantiates
// the units and wires them together, and contains no logic of its own, so a reviewer can confirm
// that by inspection and scripts/check_top.py confirms it mechanically (no always/initial/generate,
// every instance port connected by name, every assign a plain wire or a constant).
//
//   CPU fetch  -> L1-I --\
//                         arbiter -> L2 -> adapter -> L3 -> AXI4 fill engine -> AXI4 master
//   CPU load/store -> L1-D -/
//
// Reset: rst_n is asynchronous on the way in (CR-02) and is synchronised to clk here, once, for every
// unit below (reset_sync: asynchronous assert, synchronous deassert).
module mlc_cache_top #(
  // Constants driven on the AXI4 sideband signals the engine does not use. The cache has no
  // opinion about them; the memory behind it sees the same values on every burst. Override per
  // integration. AXI4 IDs are absent (one transaction at a time, so ID width 0).
  parameter logic [2:0] AXI_PROT   = 3'b000,
  parameter logic [3:0] AXI_CACHE  = 4'b0011,
  parameter logic [3:0] AXI_QOS    = 4'b0000,
  parameter logic [3:0] AXI_REGION = 4'b0000
) (
  input  logic                              clk,
  input  logic                              rst_n,

  // Instruction fetch port (read-only; no write signals exist, FR-10)
  input  logic                              i_req_valid,
  output logic                              i_req_ready,
  input  logic [mlc_pkg::ADDR_W-1:0]         i_req_addr,
  output logic                              i_resp_valid,
  input  logic                              i_resp_ready,
  output logic [mlc_pkg::DATA_W-1:0]         i_resp_rdata,

  // Data load/store port
  input  logic                              d_req_valid,
  output logic                              d_req_ready,
  input  logic [mlc_pkg::ADDR_W-1:0]         d_req_addr,
  input  logic                              d_req_we,
  input  logic [mlc_pkg::DATA_W-1:0]         d_req_wdata,
  input  logic [mlc_pkg::BYTES_PER_WORD-1:0] d_req_wstrb,
  output logic                              d_resp_valid,
  input  logic                              d_resp_ready,
  output logic [mlc_pkg::DATA_W-1:0]         d_resp_rdata,

  // AXI4 master, write address channel
  output logic [mlc_pkg::ADDR_W-1:0]         m_axi_awaddr,
  output logic [7:0]                        m_axi_awlen,
  output logic [2:0]                        m_axi_awsize,
  output logic [1:0]                        m_axi_awburst,
  output logic                              m_axi_awlock,
  output logic [3:0]                        m_axi_awcache,
  output logic [2:0]                        m_axi_awprot,
  output logic [3:0]                        m_axi_awqos,
  output logic [3:0]                        m_axi_awregion,
  output logic                              m_axi_awvalid,
  input  logic                              m_axi_awready,
  // write data channel
  output logic [mlc_pkg::AXI_DATA_W-1:0]     m_axi_wdata,
  output logic [mlc_pkg::AXI_DATA_W/8-1:0]   m_axi_wstrb,
  output logic                              m_axi_wlast,
  output logic                              m_axi_wvalid,
  input  logic                              m_axi_wready,
  // write response channel
  input  logic [1:0]                        m_axi_bresp,
  input  logic                              m_axi_bvalid,
  output logic                              m_axi_bready,
  // read address channel
  output logic [mlc_pkg::ADDR_W-1:0]         m_axi_araddr,
  output logic [7:0]                        m_axi_arlen,
  output logic [2:0]                        m_axi_arsize,
  output logic [1:0]                        m_axi_arburst,
  output logic                              m_axi_arlock,
  output logic [3:0]                        m_axi_arcache,
  output logic [2:0]                        m_axi_arprot,
  output logic [3:0]                        m_axi_arqos,
  output logic [3:0]                        m_axi_arregion,
  output logic                              m_axi_arvalid,
  input  logic                              m_axi_arready,
  // read data channel
  input  logic [mlc_pkg::AXI_DATA_W-1:0]     m_axi_rdata,
  input  logic [1:0]                        m_axi_rresp,
  input  logic                              m_axi_rlast,
  input  logic                              m_axi_rvalid,
  output logic                              m_axi_rready,

  // Sticky: any SLVERR/DECERR or RLAST mismatch seen on the AXI4 port since reset
  output logic                              mem_err
);

  localparam int L2_LINE_W = mlc_pkg::L2_LINE_B * 8;
  localparam int L3_LINE_W = mlc_pkg::L3_LINE_B * 8;

  logic rst_n_sync;

  // L1-I downstream -> arbiter port 0
  logic                              i_dn_req_valid, i_dn_req_ready, i_dn_req_we, i_dn_resp_valid, i_dn_resp_ready;
  logic [mlc_pkg::ADDR_W-1:0]         i_dn_req_addr;
  logic [mlc_pkg::DATA_W-1:0]         i_dn_req_wdata;
  logic [mlc_pkg::BYTES_PER_WORD-1:0] i_dn_req_wstrb;

  // L1-D downstream -> arbiter port 1
  logic                              d_dn_req_valid, d_dn_req_ready, d_dn_req_we, d_dn_resp_valid, d_dn_resp_ready;
  logic [mlc_pkg::ADDR_W-1:0]         d_dn_req_addr;
  logic [mlc_pkg::DATA_W-1:0]         d_dn_req_wdata;
  logic [mlc_pkg::BYTES_PER_WORD-1:0] d_dn_req_wstrb;

  // arbiter -> L2 upstream; L2's response line goes to both L1 controllers
  logic                              l2_req_valid, l2_req_ready, l2_req_we, l2_resp_valid, l2_resp_ready;
  logic [mlc_pkg::ADDR_W-1:0]         l2_req_addr;
  logic [mlc_pkg::DATA_W-1:0]         l2_req_wdata;
  logic [mlc_pkg::BYTES_PER_WORD-1:0] l2_req_wstrb;
  logic [L2_LINE_W-1:0]               l2_resp_line;

  // L2 downstream -> adapter
  logic                              l2_dn_req_valid, l2_dn_req_ready, l2_dn_req_we, l2_dn_resp_valid, l2_dn_resp_ready;
  logic [mlc_pkg::ADDR_W-1:0]         l2_dn_req_addr;
  logic [L2_LINE_W-1:0]               l2_dn_req_line, l2_dn_resp_line;

  // adapter -> L3 upstream
  logic                              l3_req_valid, l3_req_ready, l3_req_we, l3_resp_valid, l3_resp_ready;
  logic [mlc_pkg::ADDR_W-1:0]         l3_req_addr;
  logic [L2_LINE_W-1:0]               l3_req_wdata;
  logic [mlc_pkg::L2_LINE_B-1:0]      l3_req_wstrb;
  logic [L3_LINE_W-1:0]               l3_resp_line;

  // L3 downstream -> AXI4 fill engine
  logic                              l3_dn_req_valid, l3_dn_req_ready, l3_dn_req_we, l3_dn_resp_valid, l3_dn_resp_ready;
  logic [mlc_pkg::ADDR_W-1:0]         l3_dn_req_addr;
  logic [L3_LINE_W-1:0]               l3_dn_req_line, l3_dn_resp_line;

  reset_sync u_reset (
    .clk         (clk),
    .async_rst_n (rst_n),
    .rst_n       (rst_n_sync)
  );

  l1_icache_ctrl u_l1i (
    .clk           (clk),
    .rst_n         (rst_n_sync),
    .req_valid     (i_req_valid),
    .req_ready     (i_req_ready),
    .req_addr      (i_req_addr),
    .resp_valid    (i_resp_valid),
    .resp_ready    (i_resp_ready),
    .resp_rdata    (i_resp_rdata),
    .dn_req_valid  (i_dn_req_valid),
    .dn_req_ready  (i_dn_req_ready),
    .dn_req_addr   (i_dn_req_addr),
    .dn_req_we     (i_dn_req_we),
    .dn_req_wdata  (i_dn_req_wdata),
    .dn_req_wstrb  (i_dn_req_wstrb),
    .dn_resp_valid (i_dn_resp_valid),
    .dn_resp_ready (i_dn_resp_ready),
    .dn_resp_line  (l2_resp_line)
  );

  l1_dcache_ctrl u_l1d (
    .clk           (clk),
    .rst_n         (rst_n_sync),
    .req_valid     (d_req_valid),
    .req_ready     (d_req_ready),
    .req_addr      (d_req_addr),
    .req_we        (d_req_we),
    .req_wdata     (d_req_wdata),
    .req_wstrb     (d_req_wstrb),
    .resp_valid    (d_resp_valid),
    .resp_ready    (d_resp_ready),
    .resp_rdata    (d_resp_rdata),
    .dn_req_valid  (d_dn_req_valid),
    .dn_req_ready  (d_dn_req_ready),
    .dn_req_addr   (d_dn_req_addr),
    .dn_req_we     (d_dn_req_we),
    .dn_req_wdata  (d_dn_req_wdata),
    .dn_req_wstrb  (d_dn_req_wstrb),
    .dn_resp_valid (d_dn_resp_valid),
    .dn_resp_ready (d_dn_resp_ready),
    .dn_resp_line  (l2_resp_line)
  );

  l1_l2_arbiter u_arb (
    .clk            (clk),
    .rst_n          (rst_n_sync),
    .up0_req_valid  (i_dn_req_valid),
    .up0_req_ready  (i_dn_req_ready),
    .up0_req_addr   (i_dn_req_addr),
    .up0_req_we     (i_dn_req_we),
    .up0_req_wdata  (i_dn_req_wdata),
    .up0_req_wstrb  (i_dn_req_wstrb),
    .up0_resp_valid (i_dn_resp_valid),
    .up0_resp_ready (i_dn_resp_ready),
    .up1_req_valid  (d_dn_req_valid),
    .up1_req_ready  (d_dn_req_ready),
    .up1_req_addr   (d_dn_req_addr),
    .up1_req_we     (d_dn_req_we),
    .up1_req_wdata  (d_dn_req_wdata),
    .up1_req_wstrb  (d_dn_req_wstrb),
    .up1_resp_valid (d_dn_resp_valid),
    .up1_resp_ready (d_dn_resp_ready),
    .l2_req_valid   (l2_req_valid),
    .l2_req_ready   (l2_req_ready),
    .l2_req_addr    (l2_req_addr),
    .l2_req_we      (l2_req_we),
    .l2_req_wdata   (l2_req_wdata),
    .l2_req_wstrb   (l2_req_wstrb),
    .l2_resp_valid  (l2_resp_valid),
    .l2_resp_ready  (l2_resp_ready)
  );

  l2_cache_ctrl u_l2 (
    .clk           (clk),
    .rst_n         (rst_n_sync),
    .req_valid     (l2_req_valid),
    .req_ready     (l2_req_ready),
    .req_addr      (l2_req_addr),
    .req_we        (l2_req_we),
    .req_wdata     (l2_req_wdata),
    .req_wstrb     (l2_req_wstrb),
    .resp_valid    (l2_resp_valid),
    .resp_ready    (l2_resp_ready),
    .resp_line     (l2_resp_line),
    .dn_req_valid  (l2_dn_req_valid),
    .dn_req_ready  (l2_dn_req_ready),
    .dn_req_addr   (l2_dn_req_addr),
    .dn_req_we     (l2_dn_req_we),
    .dn_req_line   (l2_dn_req_line),
    .dn_resp_valid (l2_dn_resp_valid),
    .dn_resp_ready (l2_dn_resp_ready),
    .dn_resp_line  (l2_dn_resp_line)
  );

  l2_l3_width_adapter u_adapter (
    .l2_req_valid  (l2_dn_req_valid),
    .l2_req_ready  (l2_dn_req_ready),
    .l2_req_addr   (l2_dn_req_addr),
    .l2_req_we     (l2_dn_req_we),
    .l2_req_line   (l2_dn_req_line),
    .l2_resp_valid (l2_dn_resp_valid),
    .l2_resp_ready (l2_dn_resp_ready),
    .l2_resp_line  (l2_dn_resp_line),
    .l3_req_valid  (l3_req_valid),
    .l3_req_ready  (l3_req_ready),
    .l3_req_addr   (l3_req_addr),
    .l3_req_we     (l3_req_we),
    .l3_req_wdata  (l3_req_wdata),
    .l3_req_wstrb  (l3_req_wstrb),
    .l3_resp_valid (l3_resp_valid),
    .l3_resp_ready (l3_resp_ready),
    .l3_resp_line  (l3_resp_line)
  );

  l3_cache_ctrl u_l3 (
    .clk           (clk),
    .rst_n         (rst_n_sync),
    .req_valid     (l3_req_valid),
    .req_ready     (l3_req_ready),
    .req_addr      (l3_req_addr),
    .req_we        (l3_req_we),
    .req_wdata     (l3_req_wdata),
    .req_wstrb     (l3_req_wstrb),
    .resp_valid    (l3_resp_valid),
    .resp_ready    (l3_resp_ready),
    .resp_line     (l3_resp_line),
    .dn_req_valid  (l3_dn_req_valid),
    .dn_req_ready  (l3_dn_req_ready),
    .dn_req_addr   (l3_dn_req_addr),
    .dn_req_we     (l3_dn_req_we),
    .dn_req_line   (l3_dn_req_line),
    .dn_resp_valid (l3_dn_resp_valid),
    .dn_resp_ready (l3_dn_resp_ready),
    .dn_resp_line  (l3_dn_resp_line)
  );

  axi4_fill_engine u_axi (
    .clk        (clk),
    .rst_n      (rst_n_sync),
    .req_valid  (l3_dn_req_valid),
    .req_ready  (l3_dn_req_ready),
    .req_addr   (l3_dn_req_addr),
    .req_we     (l3_dn_req_we),
    .req_line   (l3_dn_req_line),
    .resp_valid (l3_dn_resp_valid),
    .resp_ready (l3_dn_resp_ready),
    .resp_line  (l3_dn_resp_line),
    .awaddr     (m_axi_awaddr),
    .awlen      (m_axi_awlen),
    .awsize     (m_axi_awsize),
    .awburst    (m_axi_awburst),
    .awvalid    (m_axi_awvalid),
    .awready    (m_axi_awready),
    .wdata      (m_axi_wdata),
    .wstrb      (m_axi_wstrb),
    .wlast      (m_axi_wlast),
    .wvalid     (m_axi_wvalid),
    .wready     (m_axi_wready),
    .bresp      (m_axi_bresp),
    .bvalid     (m_axi_bvalid),
    .bready     (m_axi_bready),
    .araddr     (m_axi_araddr),
    .arlen      (m_axi_arlen),
    .arsize     (m_axi_arsize),
    .arburst    (m_axi_arburst),
    .arvalid    (m_axi_arvalid),
    .arready    (m_axi_arready),
    .rdata      (m_axi_rdata),
    .rresp      (m_axi_rresp),
    .rlast      (m_axi_rlast),
    .rvalid     (m_axi_rvalid),
    .rready     (m_axi_rready),
    .mem_err    (mem_err)
  );

  // AXI4 sideband constants (parameters above); the engine never drives these.
  assign m_axi_awlock   = 1'b0;
  assign m_axi_arlock   = 1'b0;
  assign m_axi_awcache  = AXI_CACHE;
  assign m_axi_arcache  = AXI_CACHE;
  assign m_axi_awprot   = AXI_PROT;
  assign m_axi_arprot   = AXI_PROT;
  assign m_axi_awqos    = AXI_QOS;
  assign m_axi_arqos    = AXI_QOS;
  assign m_axi_awregion = AXI_REGION;
  assign m_axi_arregion = AXI_REGION;

endmodule
