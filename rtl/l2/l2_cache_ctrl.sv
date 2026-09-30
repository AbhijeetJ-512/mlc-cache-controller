module l2_cache_ctrl #(
  parameter int CAPACITY_B = mlc_pkg::L2_CAPACITY_B,
  parameter int LINE_B     = mlc_pkg::L2_LINE_B,
  parameter int WAYS       = mlc_pkg::L2_WAYS
) (
  input  logic                              clk,
  input  logic                              rst_n,

  input  logic                              req_valid,
  output logic                              req_ready,
  input  logic [mlc_pkg::ADDR_W-1:0]         req_addr,
  input  logic                              req_we,
  input  logic [mlc_pkg::DATA_W-1:0]         req_wdata,
  input  logic [mlc_pkg::BYTES_PER_WORD-1:0] req_wstrb,
  output logic                              resp_valid,
  input  logic                              resp_ready,
  output logic [LINE_B*8-1:0]                resp_line,

  output logic                              dn_req_valid,
  input  logic                              dn_req_ready,
  output logic [mlc_pkg::ADDR_W-1:0]         dn_req_addr,
  output logic                              dn_req_we,
  output logic [mlc_pkg::DATA_W-1:0]         dn_req_wdata,
  output logic [mlc_pkg::BYTES_PER_WORD-1:0] dn_req_wstrb,
  output logic [LINE_B*8-1:0]                dn_req_line,
  input  logic                              dn_resp_valid,
  output logic                              dn_resp_ready,
  input  logic [LINE_B*8-1:0]                dn_resp_line
);

  localparam int LINE_W         = LINE_B * 8;
  localparam int WORDS_PER_LINE = LINE_B / mlc_pkg::BYTES_PER_WORD;
  localparam int LINES          = CAPACITY_B / LINE_B;
  localparam int SETS           = LINES / WAYS;
  localparam int OFFSET_W       = $clog2(LINE_B);
  localparam int INDEX_W        = $clog2(SETS);
  localparam int TAG_W          = mlc_pkg::ADDR_W - INDEX_W - OFFSET_W;
  localparam int WORD_SEL_W     = $clog2(WORDS_PER_LINE);
  localparam int WAY_SEL_W      = $clog2(WAYS);

  typedef enum logic [2:0] {S_IDLE, S_TAG_CHECK, S_EVICT_WRITEBACK, S_ALLOC_FILL, S_UPDATE_TAG} state_e;
  state_e state;

  // Reset-free arrays (D-019): tag/dirty/data content is don't-care until validated (FR-06).
  // Kept in their own always_ff with no reset so Yosys infers real $mem cells instead of
  // flattening to SETS*WAYS discrete registers - verified necessary at this scale, not optional.
  logic [TAG_W-1:0]  tag_array   [0:SETS-1][0:WAYS-1];
  logic              dirty_array [0:SETS-1][0:WAYS-1];
  logic [LINE_W-1:0] data_array  [0:SETS-1][0:WAYS-1];

  // Reset-bearing (D-019): only valid_array must reach a defined value on reset (FR-06).
  logic valid_array [0:SETS-1][0:WAYS-1];

  logic [TAG_W-1:0]   req_tag;
  logic [INDEX_W-1:0] req_index;
  logic [WORD_SEL_W-1:0] req_word_sel;
  assign req_tag      = req_addr[mlc_pkg::ADDR_W-1 -: TAG_W];
  assign req_index    = req_addr[OFFSET_W +: INDEX_W];
  assign req_word_sel = req_addr[$clog2(mlc_pkg::BYTES_PER_WORD) +: WORD_SEL_W];

  logic [WAYS-1:0]    way_hit;
  logic [WAY_SEL_W-1:0] hit_way;
  logic                is_hit;
  always_comb begin
    for (int w = 0; w < WAYS; w++) begin
      way_hit[w] = valid_array[req_index][w] && (tag_array[req_index][w] == req_tag);
    end
  end
  assign is_hit = |way_hit;
  always_comb begin
    hit_way = '0;
    for (int w = 0; w < WAYS; w++) begin
      if (way_hit[w]) hit_way = w[WAY_SEL_W-1:0];
    end
  end

  logic [LINE_W-1:0] hit_line_rd;
  assign hit_line_rd = data_array[req_index][hit_way];

  function automatic logic [mlc_pkg::DATA_W-1:0] merge_wstrb(
    input logic [mlc_pkg::DATA_W-1:0]        old_word,
    input logic [mlc_pkg::DATA_W-1:0]        new_data,
    input logic [mlc_pkg::BYTES_PER_WORD-1:0] wstrb
  );
    merge_wstrb = old_word;
    for (int b = 0; b < mlc_pkg::BYTES_PER_WORD; b++) begin
      if (wstrb[b]) merge_wstrb[b*8 +: 8] = new_data[b*8 +: 8];
    end
  endfunction

  logic [LINE_W-1:0] hit_write_line_merged;
  always_comb begin
    hit_write_line_merged = hit_line_rd;
    hit_write_line_merged[req_word_sel*mlc_pkg::DATA_W +: mlc_pkg::DATA_W] =
        merge_wstrb(hit_line_rd[req_word_sel*mlc_pkg::DATA_W +: mlc_pkg::DATA_W], req_wdata, req_wstrb);
  end

  // --- miss latches ---
  logic [mlc_pkg::ADDR_W-1:0]         miss_addr;
  logic [INDEX_W-1:0]                 miss_index;
  logic [TAG_W-1:0]                   miss_tag;
  logic [WORD_SEL_W-1:0]              miss_word_sel;
  logic                               miss_is_write;
  logic [mlc_pkg::DATA_W-1:0]         miss_wdata;
  logic [mlc_pkg::BYTES_PER_WORD-1:0] miss_wstrb;

  // --- victim register (D-018: one register, never a per-level buffer - eviction always
  // completes before the fill it triggered begins) ---
  logic [WAY_SEL_W-1:0] victim_way;      // combinational, from plru_tree, valid while in S_TAG_CHECK
  logic [WAY_SEL_W-1:0] victim_way_latched;
  logic [TAG_W-1:0]     victim_tag_latched;
  logic [LINE_W-1:0]    victim_line_latched;

  // PLRU access port, driven below (declared before the instantiation that connects it).
  logic                 plru_access_valid;
  logic [INDEX_W-1:0]   plru_access_set;
  logic [WAY_SEL_W-1:0] plru_access_way;

  // victim_way (the plru_tree's combinational output) is only ever consumed once, in
  // commit_tag_check's latch below - and by the time the FSM is actually in S_TAG_CHECK,
  // miss_index is already correctly latched (set on the same edge as the S_IDLE->S_TAG_CHECK
  // transition). So set_index can simply always be miss_index: its value is don't-care in every
  // other state, since nothing reads victim_way then.
  plru_tree #(.WAYS(WAYS), .SETS(SETS)) u_plru (
    .clk          (clk),
    .rst_n        (rst_n),
    .set_index    (miss_index),
    .victim_way   (victim_way),
    .access_valid (plru_access_valid),
    .access_set   (plru_access_set),
    .access_way   (plru_access_way)
  );

  logic [LINE_W-1:0] fill_line_merged;
  always_comb begin
    fill_line_merged = dn_resp_line;
    if (miss_is_write) begin
      fill_line_merged[miss_word_sel*mlc_pkg::DATA_W +: mlc_pkg::DATA_W] =
          merge_wstrb(dn_resp_line[miss_word_sel*mlc_pkg::DATA_W +: mlc_pkg::DATA_W], miss_wdata, miss_wstrb);
    end
  end

  // --- shared commit-condition signals (see Global Constraints: computed once, used by both
  // the reset-free and reset-bearing always_ff blocks below, so they cannot drift apart) ---
  // hit_accept: a hit is being accepted this cycle. The one definition feeds the write-hit commit,
  // the PLRU hit update and the read-hit response, so those three can never disagree about it.
  logic hit_accept;
  logic commit_write_hit;
  logic commit_tag_check;
  logic commit_fill;
  assign hit_accept       = (state == S_IDLE) && req_valid && req_ready && is_hit;
  assign commit_write_hit = hit_accept && req_we;
  assign commit_tag_check = (state == S_TAG_CHECK);
  assign commit_fill      = (state == S_ALLOC_FILL) && dn_resp_valid;

  assign plru_access_valid = hit_accept || commit_fill;
  assign plru_access_set   = commit_fill ? miss_index : req_index;
  assign plru_access_way   = commit_fill ? victim_way_latched : hit_way;

  // D-021: upstream writes are posted. Only a read hit hands back data in its acceptance cycle, so
  // only a read hit needs resp_ready to be accepted; a write (hit or write-allocate miss) never
  // raises resp_valid - matching L1's write-through forward, which never waits for a response.
  assign req_ready = rst_n && (state == S_IDLE) && (!req_valid || !is_hit || req_we || resp_ready);

  assign resp_valid = (state == S_UPDATE_TAG && !miss_is_write) || (hit_accept && !req_we);

  always_comb begin
    if (state == S_UPDATE_TAG) resp_line = data_array[miss_index][victim_way_latched];
    else                       resp_line = hit_line_rd;
  end

  assign dn_resp_ready = (state == S_ALLOC_FILL);

  always_comb begin
    if (state == S_EVICT_WRITEBACK) begin
      dn_req_valid = 1'b1;
      dn_req_addr  = {victim_tag_latched, miss_index, {OFFSET_W{1'b0}}};
      dn_req_we    = 1'b1;
      dn_req_wdata = '0; dn_req_wstrb = '0;
      dn_req_line  = victim_line_latched;
    end else if (state == S_ALLOC_FILL) begin
      dn_req_valid = 1'b1;
      dn_req_addr  = miss_addr;
      dn_req_we    = 1'b0;
      dn_req_wdata = '0; dn_req_wstrb = '0; dn_req_line = '0;
    end else begin
      dn_req_valid = 1'b0; dn_req_addr = '0; dn_req_we = 1'b0;
      dn_req_wdata = '0; dn_req_wstrb = '0; dn_req_line = '0;
    end
  end

  // --- reset-free: tag/dirty/data array writes and the victim_* register (D-019) ---
  always_ff @(posedge clk) begin
    if (commit_write_hit) begin
      data_array[req_index][hit_way]  <= hit_write_line_merged;
      dirty_array[req_index][hit_way] <= 1'b1;
    end
    if (commit_tag_check) begin
      victim_way_latched  <= victim_way;
      victim_tag_latched  <= tag_array[miss_index][victim_way];
      victim_line_latched <= data_array[miss_index][victim_way];
    end
    if (commit_fill) begin
      tag_array[miss_index][victim_way_latched]   <= miss_tag;
      data_array[miss_index][victim_way_latched]  <= fill_line_merged;
      dirty_array[miss_index][victim_way_latched] <= miss_is_write;
    end
  end

  // --- reset-bearing: valid_array, the FSM state, and the miss_* latches (D-019) ---
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
      for (int s = 0; s < SETS; s++)
        for (int w = 0; w < WAYS; w++)
          valid_array[s][w] <= 1'b0;
    end else begin
      if (commit_fill) valid_array[miss_index][victim_way_latched] <= 1'b1;

      case (state)
        S_IDLE: begin
          if (req_valid && req_ready && !is_hit) begin
            miss_addr     <= req_addr;
            miss_index    <= req_index;
            miss_tag      <= req_tag;
            miss_word_sel <= req_word_sel;
            miss_is_write <= req_we;
            miss_wdata    <= req_wdata;
            miss_wstrb    <= req_wstrb;
            state <= S_TAG_CHECK;
          end
        end
        S_TAG_CHECK: begin
          if (valid_array[miss_index][victim_way] && dirty_array[miss_index][victim_way])
            state <= S_EVICT_WRITEBACK;
          else
            state <= S_ALLOC_FILL;
        end
        S_EVICT_WRITEBACK: begin
          if (dn_req_ready) state <= S_ALLOC_FILL;
        end
        S_ALLOC_FILL: begin
          if (dn_resp_valid) state <= S_UPDATE_TAG;
        end
        S_UPDATE_TAG: begin
          if (miss_is_write || resp_ready) state <= S_IDLE;
        end
        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
