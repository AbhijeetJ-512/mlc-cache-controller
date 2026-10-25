// Behavioral AXI4 slave for the Tier-1 testbenches (not synthesizable, no IDs, one burst per
// direction at a time). Two jobs:
//   1. be a memory: reads return it, writes update it. Its initial image is defined in terms of
//      32-bit words, mem32(i) = 32'hC0DE_0000 + i, independent of DATA_W, so a testbench can
//      compute expected line contents without peeking into the model.
//   2. check the master. Burst shape (len, size, burst type), start-address alignment, WSTRB,
//      WLAST position, and VALID/payload stability are compared against values the testbench
//      passes in as literals (EXP_*), never derived from the DUT. Each violation increments
//      proto_errors and prints a line starting with "AXI PROTO:".
// Controls (stall_*, r_gap, force_*) let a test inject backpressure and error responses. Three
// more are plain variables a test sets through a hierarchical reference (they default to a
// well-behaved slave): b_delay, cycles BVALID is held off after the last W beat; rlast_mode,
// 0 normal, 1 RLAST never raised, 2 RLAST raised on beat 3 and the burst ended there; and
// rresp_err_beat, a beat number whose RRESP alone is SLVERR (-1 for none); and aw_mode, which
// picks which legal write-channel ordering the slave shows (AXI4 A3.3.1 lets a slave wait for
// AWVALID or WVALID or both, so a master may depend on none of them): 0 AWREADY at once and WREADY
// after the AW handshake, 1 AWREADY only once WVALID has been seen high in an earlier cycle
// (registered, since AXI4 allows no combinational path from an input to an output; WREADY still
// after AW), 2 the whole W burst is accepted first, held, and only then is AW accepted.
module axi_mem_model #(
  parameter int DATA_W      = 32,
  parameter int MEM_WORDS   = 131072,  // DATA_W-wide words (512 KiB at 32 bits); addresses wrap modulo this
  parameter int EXP_LEN     = 15,
  parameter int EXP_SIZE    = 2,
  parameter int EXP_ALIGN_B = 64
) (
  input  logic                clk,
  input  logic                rst_n,

  input  logic                stall_ar,
  input  logic                stall_aw,
  input  logic                stall_w,
  input  logic [3:0]          r_gap,
  input  logic [1:0]          force_rresp,
  input  logic [1:0]          force_bresp,

  input  logic [31:0]         awaddr,
  input  logic [7:0]          awlen,
  input  logic [2:0]          awsize,
  input  logic [1:0]          awburst,
  input  logic                awvalid,
  output logic                awready,
  input  logic [DATA_W-1:0]   wdata,
  input  logic [DATA_W/8-1:0] wstrb,
  input  logic                wlast,
  input  logic                wvalid,
  output logic                wready,
  output logic [1:0]          bresp,
  output logic                bvalid,
  input  logic                bready,
  input  logic [31:0]         araddr,
  input  logic [7:0]          arlen,
  input  logic [2:0]          arsize,
  input  logic [1:0]          arburst,
  input  logic                arvalid,
  output logic                arready,
  output logic [DATA_W-1:0]   rdata,
  output logic [1:0]          rresp,
  output logic                rlast,
  output logic                rvalid,
  input  logic                rready
);

  localparam int BYTES = DATA_W / 8;

  logic [DATA_W-1:0] mem [0:MEM_WORDS-1];

  // Observation, read by the testbench through hierarchical references.
  int ar_count = 0, aw_count = 0, rbeat_count = 0, wbeat_count = 0, proto_errors = 0;
  int b_delay = 0, rlast_mode = 0, rresp_err_beat = -1, aw_mode = 0;
  logic        ev_is_write[$];   // one entry per accepted AR/AW, in order: 0 = read, 1 = write
  logic [31:0] ev_addr[$];

  function automatic logic [31:0] mem32(input int i);
    mem32 = 32'hC0DE_0000 + i;
  endfunction

  function automatic int widx(input logic [31:0] byte_addr);
    widx = (byte_addr / BYTES) % MEM_WORDS;
  endfunction

  task automatic init_mem();
    for (int i = 0; i < MEM_WORDS; i++)
      for (int k = 0; k < DATA_W / 32; k++)
        mem[i][k*32 +: 32] = mem32(i * (DATA_W / 32) + k);
  endtask

  initial init_mem();

  task automatic proto_err(input string msg);
    proto_errors++;
    $display("AXI PROTO: %s (t=%0t)", msg, $time);
  endtask

  // ---------------- read channel ----------------
  typedef enum logic {R_IDLE, R_DATA} rstate_e;
  rstate_e     rstate;
  logic [31:0] r_addr_q;
  logic [7:0]  r_len_q, r_beat;
  logic [3:0]  r_gap_cnt;
  logic        first_gap_en = 1'b0;   // set by a testbench (axi.first_gap_en): r_gap then also delays the FIRST beat of a burst
  wire         r_burst_end = (rlast_mode == 2) ? (r_beat == 8'd3) : (r_beat == r_len_q);

  assign arready = (rstate == R_IDLE) && !stall_ar;
  assign rvalid  = (rstate == R_DATA) && (r_gap_cnt == 0);
  assign rdata   = mem[widx(r_addr_q + r_beat * BYTES)];
  assign rlast   = (rlast_mode == 1) ? 1'b0 : r_burst_end;
  assign rresp   = (rresp_err_beat >= 0 && r_beat == rresp_err_beat) ? 2'b10 : force_rresp;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rstate <= R_IDLE;
    end else begin
      case (rstate)
        R_IDLE: if (arvalid && arready) begin
          r_addr_q  <= araddr;
          r_len_q   <= arlen;
          r_beat    <= '0;
          r_gap_cnt <= first_gap_en ? r_gap : '0;
          rstate    <= R_DATA;
        end
        R_DATA: begin
          if (r_gap_cnt != 0) r_gap_cnt <= r_gap_cnt - 1'b1;
          else if (rready) begin
            rbeat_count++;
            if (r_burst_end) rstate <= R_IDLE;
            else begin
              r_beat    <= r_beat + 1'b1;
              r_gap_cnt <= r_gap;
            end
          end
        end
      endcase
    end
  end

  always @(posedge clk) if (rst_n && arvalid && arready) begin
    ar_count++;
    ev_is_write.push_back(1'b0);
    ev_addr.push_back(araddr);
    if (arlen   !== EXP_LEN[7:0])  proto_err($sformatf("ARLEN %0d, expected %0d", arlen, EXP_LEN));
    if (arsize  !== EXP_SIZE[2:0]) proto_err($sformatf("ARSIZE %0d, expected %0d", arsize, EXP_SIZE));
    if (arburst !== 2'b01)         proto_err($sformatf("ARBURST %0d, expected INCR", arburst));
    if (araddr % EXP_ALIGN_B != 0) proto_err($sformatf("ARADDR 0x%08h not %0d-byte aligned", araddr, EXP_ALIGN_B));
    if (araddr / BYTES + arlen >= MEM_WORDS) proto_err($sformatf("ARADDR 0x%08h burst runs past the model's memory (a test or address bug)", araddr));
  end

  // ---------------- write channel ----------------
  typedef enum logic [1:0] {W_IDLE, W_DATA, W_AWAIT, W_RESP} wstate_e;
  wstate_e     wstate;
  logic [31:0] w_addr_q;
  logic [7:0]  w_len_q, w_beat;
  int          b_cnt;
  // aw_mode 2: W beats taken before their AW are held here until the AW arrives. Strobes are not
  // stored; the WSTRB check below flags anything but all ones.
  logic [DATA_W-1:0] stage [0:255];
  logic [7:0]  st_beat;
  wire         w_staging = (wstate == W_IDLE) && (aw_mode == 2);
  logic        wvalid_q;   // WVALID one cycle ago, for aw_mode 1
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) wvalid_q <= 1'b0;
    else        wvalid_q <= wvalid;
  end
  wire  [7:0]  w_cur_beat = w_staging ? st_beat : w_beat;
  wire  [7:0]  w_cur_len  = w_staging ? EXP_LEN[7:0] : w_len_q;

  assign awready = ((wstate == W_IDLE && aw_mode != 2 && (aw_mode != 1 || wvalid_q)) || wstate == W_AWAIT) && !stall_aw;
  assign wready  = (wstate == W_DATA || w_staging) && !stall_w;
  assign bvalid  = (wstate == W_RESP) && (b_cnt == 0);
  assign bresp   = force_bresp;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wstate  <= W_IDLE;
      st_beat <= '0;
    end else begin
      case (wstate)
        W_IDLE: begin
          if (w_staging) begin
            if (wvalid && wready) begin
              stage[st_beat] <= wdata;
              wbeat_count++;
              if (wlast || st_beat == EXP_LEN[7:0]) wstate <= W_AWAIT;
              else st_beat <= st_beat + 1'b1;
            end
          end else if (awvalid && awready) begin
            w_addr_q <= awaddr;
            w_len_q  <= awlen;
            w_beat   <= '0;
            wstate   <= W_DATA;
          end
        end
        W_AWAIT: if (awvalid && awready) begin
          for (int k = 0; k <= EXP_LEN; k++) mem[widx(awaddr + k * BYTES)] <= stage[k];
          st_beat <= '0;
          wstate  <= W_RESP;
          b_cnt   <= b_delay;
        end
        W_DATA: if (wvalid && wready) begin
          for (int b = 0; b < BYTES; b++)
            if (wstrb[b]) mem[widx(w_addr_q + w_beat * BYTES)][b*8 +: 8] <= wdata[b*8 +: 8];
          wbeat_count++;
          if (wlast || w_beat == w_len_q) begin
            wstate <= W_RESP;
            b_cnt  <= b_delay;
          end else w_beat <= w_beat + 1'b1;
        end
        W_RESP: if (b_cnt != 0) b_cnt <= b_cnt - 1;
                else if (bready) wstate <= W_IDLE;
      endcase
    end
  end

  always @(posedge clk) if (rst_n && awvalid && awready) begin
    aw_count++;
    ev_is_write.push_back(1'b1);
    ev_addr.push_back(awaddr);
    if (awlen   !== EXP_LEN[7:0])  proto_err($sformatf("AWLEN %0d, expected %0d", awlen, EXP_LEN));
    if (awsize  !== EXP_SIZE[2:0]) proto_err($sformatf("AWSIZE %0d, expected %0d", awsize, EXP_SIZE));
    if (awburst !== 2'b01)         proto_err($sformatf("AWBURST %0d, expected INCR", awburst));
    if (awaddr % EXP_ALIGN_B != 0) proto_err($sformatf("AWADDR 0x%08h not %0d-byte aligned", awaddr, EXP_ALIGN_B));
    if (awaddr / BYTES + awlen >= MEM_WORDS) proto_err($sformatf("AWADDR 0x%08h burst runs past the model's memory (a test or address bug)", awaddr));
  end

  always @(posedge clk) if (rst_n && wvalid && wready) begin
    if (wstrb !== {BYTES{1'b1}}) proto_err($sformatf("WSTRB 0x%0h, expected all ones", wstrb));
    if (wlast !== (w_cur_beat == w_cur_len)) proto_err($sformatf("WLAST %b on beat %0d of %0d", wlast, w_cur_beat, w_cur_len + 1));
  end

  // ---------------- VALID/payload stability: once raised, hold until accepted ----------------
  logic        p_ar, p_aw, p_w;
  logic [31:0] p_araddr, p_awaddr;
  logic [DATA_W-1:0] p_wdata;
  logic        p_wlast;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      p_ar <= 0; p_aw <= 0; p_w <= 0;
    end else begin
      if (p_ar && !(arvalid && araddr === p_araddr)) proto_err("ARVALID/ARADDR changed before ARREADY");
      if (p_aw && !(awvalid && awaddr === p_awaddr)) proto_err("AWVALID/AWADDR changed before AWREADY");
      if (p_w  && !(wvalid  && wdata === p_wdata && wlast === p_wlast)) proto_err("WVALID/WDATA/WLAST changed before WREADY");
      p_ar <= arvalid && !arready; p_araddr <= araddr;
      p_aw <= awvalid && !awready; p_awaddr <= awaddr;
      p_w  <= wvalid  && !wready;  p_wdata  <= wdata; p_wlast <= wlast;
    end
  end

endmodule
