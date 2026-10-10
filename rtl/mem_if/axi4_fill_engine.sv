// AXI4 fill engine (FR-22..FR-24, FR-26, D-012). Turns L3's line-sized requests into exactly one
// fixed-length INCR burst each:
//   read request  -> AR burst, collect the R beats into a line, then answer with resp_valid
//   write request -> AW burst and the W beats from the line, presented together and finished in
//                    either order, then wait for B; posted, so no resp_valid (D-021, D-032)
// One transaction at a time (D-004), so no AXI IDs. req_addr is expected to be line-aligned
// already (FR-24: L3 aligns the addresses it issues), so there is no alignment logic here; the
// AXI memory model in the testbenches checks it.
module axi4_fill_engine #(
  parameter int LINE_B     = mlc_pkg::L3_LINE_B,
  parameter int AXI_DATA_W = mlc_pkg::AXI_DATA_W
) (
  input  logic                          clk,
  input  logic                          rst_n,

  // Request side: L3's downstream port.
  input  logic                          req_valid,
  output logic                          req_ready,
  input  logic [mlc_pkg::ADDR_W-1:0]     req_addr,
  input  logic                          req_we,
  input  logic [LINE_B*8-1:0]            req_line,
  output logic                          resp_valid,
  input  logic                          resp_ready,
  output logic [LINE_B*8-1:0]            resp_line,

  // AXI4 master, write address channel
  output logic [mlc_pkg::ADDR_W-1:0]     awaddr,
  output logic [7:0]                    awlen,
  output logic [2:0]                    awsize,
  output logic [1:0]                    awburst,
  output logic                          awvalid,
  input  logic                          awready,
  // write data channel
  output logic [AXI_DATA_W-1:0]          wdata,
  output logic [AXI_DATA_W/8-1:0]        wstrb,
  output logic                          wlast,
  output logic                          wvalid,
  input  logic                          wready,
  // write response channel
  input  logic [1:0]                    bresp,
  input  logic                          bvalid,
  output logic                          bready,
  // read address channel
  output logic [mlc_pkg::ADDR_W-1:0]     araddr,
  output logic [7:0]                    arlen,
  output logic [2:0]                    arsize,
  output logic [1:0]                    arburst,
  output logic                          arvalid,
  input  logic                          arready,
  // read data channel
  input  logic [AXI_DATA_W-1:0]          rdata,
  input  logic [1:0]                    rresp,
  input  logic                          rlast,
  input  logic                          rvalid,
  output logic                          rready,

  // Sticky: set by any SLVERR/DECERR response or a missing/early RLAST; cleared only by reset.
  output logic                          mem_err
);

  localparam int LINE_W  = LINE_B * 8;
  localparam int BEATS   = LINE_W / AXI_DATA_W;
  localparam int BEAT_W  = (BEATS > 1) ? $clog2(BEATS) : 1;

  localparam logic [7:0] AXLEN   = BEATS - 1;
  localparam logic [2:0] AXSIZE  = $clog2(AXI_DATA_W / 8);
  localparam logic [1:0] AXBURST = 2'b01; // INCR

  initial begin
    if (LINE_W % AXI_DATA_W != 0)
      $fatal(1, "axi4_fill_engine: AXI_DATA_W (%0d) must divide the line width (%0d bits)", AXI_DATA_W, LINE_W);
    if (BEATS < 1 || BEATS > 256)
      $fatal(1, "axi4_fill_engine: a line must take 1..256 beats, got %0d", BEATS);
    if (LINE_B & (LINE_B - 1))
      $fatal(1, "axi4_fill_engine: LINE_B (%0d) must be a power of two so that an aligned burst stays inside one window", LINE_B);
    if (LINE_B > 4096)
      $fatal(1, "axi4_fill_engine: a line (%0d B) must fit in one 4 KB AXI burst window", LINE_B);
  end

  typedef enum logic [2:0] {S_IDLE, S_AR, S_R, S_RESP, S_WR, S_B} state_e;
  state_e state;

  logic [mlc_pkg::ADDR_W-1:0] addr_q;
  logic [LINE_W-1:0]          line_q;
  logic [BEAT_W-1:0]          beat_q;
  logic                       aw_done_q;   // S_WR: the AW handshake has happened
  logic                       w_done_q;    // S_WR: the last W beat has been accepted

  logic last_beat;
  assign last_beat = (beat_q == BEATS - 1);

  assign req_ready  = rst_n && (state == S_IDLE);

  assign araddr  = addr_q;
  assign arlen   = AXLEN;
  assign arsize  = AXSIZE;
  assign arburst = AXBURST;
  assign arvalid = (state == S_AR);
  assign rready  = (state == S_R);

  assign awaddr  = addr_q;
  assign awlen   = AXLEN;
  assign awsize  = AXSIZE;
  assign awburst = AXBURST;
  // AXI4 (A3.3.1): a master must not wait for AWREADY or WREADY before asserting AWVALID or WVALID,
  // and a slave may hold AWREADY back until it sees WVALID. So AW and W are presented together on
  // entry to S_WR and each is dropped when its own handshake completes, in either order (D-032).
  assign awvalid = (state == S_WR) && !aw_done_q;

  assign wvalid  = (state == S_WR) && !w_done_q;
  assign wdata   = line_q[beat_q*AXI_DATA_W +: AXI_DATA_W];
  assign wstrb   = '1;
  assign wlast   = wvalid && last_beat;
  assign bready  = (state == S_B);

  assign resp_valid = (state == S_RESP);
  assign resp_line  = line_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state   <= S_IDLE;
      mem_err <= 1'b0;
    end else begin
      case (state)
        S_IDLE: begin
          if (req_valid) begin
            addr_q <= req_addr;
            beat_q <= '0;
            aw_done_q <= 1'b0;
            w_done_q  <= 1'b0;
            if (req_we) begin
              line_q <= req_line;
              state  <= S_WR;
            end else begin
              state  <= S_AR;
            end
          end
        end
        S_AR: begin
          if (arready) state <= S_R;
        end
        S_R: begin
          if (rvalid) begin
            line_q[beat_q*AXI_DATA_W +: AXI_DATA_W] <= rdata;
            if (rresp[1]) mem_err <= 1'b1;
            if (rlast != last_beat) mem_err <= 1'b1;
            if (last_beat) state <= S_RESP;
            else           beat_q <= beat_q + 1'b1;
          end
        end
        S_RESP: begin
          if (resp_ready) state <= S_IDLE;
        end
        S_WR: begin
          if (awvalid && awready) aw_done_q <= 1'b1;
          if (wvalid && wready) begin
            if (last_beat) w_done_q <= 1'b1;
            else           beat_q   <= beat_q + 1'b1;
          end
          // Both channels finished, counting a handshake in this very cycle. While a flag is clear
          // the matching valid is high, so ready alone is the handshake.
          if ((aw_done_q || awready) && (w_done_q || (wready && last_beat))) state <= S_B;
        end
        S_B: begin
          if (bvalid) begin
            if (bresp[1]) mem_err <= 1'b1;
            state <= S_IDLE;
          end
        end
        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
