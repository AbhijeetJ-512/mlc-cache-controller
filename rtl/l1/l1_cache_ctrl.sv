// l1_cache_ctrl - shared L1 controller core, instantiated by both l1_icache_ctrl and l1_dcache_ctrl.
// Key design decisions this module embodies (full reasoning in docs/engineering_log.md):
//   D-003: direct-mapped, write-through - one tag compare on the hit path, no way-select mux.
//   D-006: no eviction state - write-through lines are never dirty (TAG_CHECK is combinational in S_IDLE).
//   D-015: 1-entry write-forward skid register (wr_fwd_*) - a write hit still completes the same cycle
//          when L2 is not ready; req_ready drops until the pending forward drains.
//   D-017: data_array is only ever single-indexed; word-level merges are done on plain temporaries
//          (fill_line_merged, hit_write_line_merged) to keep Yosys's proc pass tractable.
module l1_cache_ctrl (
  input  logic                      clk,
  input  logic                      rst_n,

  input  logic                      req_valid,
  output logic                      req_ready,
  input  logic [mlc_pkg::ADDR_W-1:0]         req_addr,
  input  logic                      req_we,
  input  logic [mlc_pkg::DATA_W-1:0]         req_wdata,
  input  logic [mlc_pkg::BYTES_PER_WORD-1:0] req_wstrb,
  output logic                      resp_valid,
  input  logic                      resp_ready,
  output logic [mlc_pkg::DATA_W-1:0]         resp_rdata,

  output logic                      dn_req_valid,
  input  logic                      dn_req_ready,
  output logic [mlc_pkg::ADDR_W-1:0]         dn_req_addr,
  output logic                      dn_req_we,
  output logic [mlc_pkg::DATA_W-1:0]         dn_req_wdata,
  output logic [mlc_pkg::BYTES_PER_WORD-1:0] dn_req_wstrb,
  input  logic                      dn_resp_valid,
  output logic                      dn_resp_ready,
  input  logic [mlc_pkg::L1_LINE_W-1:0]      dn_resp_line
);

  typedef enum logic [1:0] {S_IDLE, S_ALLOC_FILL, S_UPDATE_TAG} state_e;
  state_e state;

  logic [mlc_pkg::L1_TAG_W-1:0]  tag_array   [0:mlc_pkg::L1_SETS-1];
  logic                 valid_array [0:mlc_pkg::L1_SETS-1];
  logic [mlc_pkg::L1_LINE_W-1:0] data_array  [0:mlc_pkg::L1_SETS-1];

  logic [mlc_pkg::L1_TAG_W-1:0]      req_tag;
  logic [mlc_pkg::L1_INDEX_W-1:0]    req_index;
  logic [mlc_pkg::L1_WORD_SEL_W-1:0] req_word_sel;
  assign req_tag      = req_addr[mlc_pkg::ADDR_W-1 -: mlc_pkg::L1_TAG_W];
  assign req_index    = req_addr[mlc_pkg::L1_OFFSET_W +: mlc_pkg::L1_INDEX_W];
  // The low $clog2(BYTES_PER_WORD) address bits (the byte offset within a word) are assumed 0
  // (word-aligned requests); the word select sits immediately above them.
  assign req_word_sel = req_addr[$clog2(mlc_pkg::BYTES_PER_WORD) +: mlc_pkg::L1_WORD_SEL_W];

  logic is_hit;
  assign is_hit = valid_array[req_index] && (tag_array[req_index] == req_tag);

  logic [mlc_pkg::ADDR_W-1:0]        miss_addr;
  logic [mlc_pkg::L1_INDEX_W-1:0]    miss_index;
  logic [mlc_pkg::L1_LINE_W-1:0] req_line_rd;
  logic [mlc_pkg::L1_LINE_W-1:0] miss_line_rd;
  assign req_line_rd  = data_array[req_index];
  assign miss_line_rd = data_array[miss_index];
  logic [mlc_pkg::L1_TAG_W-1:0]      miss_tag;
  logic [mlc_pkg::L1_WORD_SEL_W-1:0] miss_word_sel;
  logic                     miss_is_write;
  logic [mlc_pkg::DATA_W-1:0]        miss_wdata;
  logic [mlc_pkg::BYTES_PER_WORD-1:0] miss_wstrb;

  logic                      wr_fwd_pending;
  logic [mlc_pkg::ADDR_W-1:0]         wr_fwd_addr;
  logic [mlc_pkg::DATA_W-1:0]         wr_fwd_wdata;
  logic [mlc_pkg::BYTES_PER_WORD-1:0] wr_fwd_wstrb;

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

  logic [mlc_pkg::L1_LINE_W-1:0] fill_line_merged;
  always_comb begin
    fill_line_merged = dn_resp_line;
    if (miss_is_write) begin
      fill_line_merged[miss_word_sel*mlc_pkg::DATA_W +: mlc_pkg::DATA_W] =
          merge_wstrb(dn_resp_line[miss_word_sel*mlc_pkg::DATA_W +: mlc_pkg::DATA_W], miss_wdata, miss_wstrb);
    end
  end

  // Mirrors fill_line_merged's pattern for write-hit case: merge write data into one full line for
  // single-indexed update (no guard needed here: call site in S_IDLE is already gated on req_we).
  logic [mlc_pkg::L1_LINE_W-1:0] hit_write_line_merged;
  always_comb begin
    hit_write_line_merged = req_line_rd;
    hit_write_line_merged[req_word_sel*mlc_pkg::DATA_W +: mlc_pkg::DATA_W] =
        merge_wstrb(req_line_rd[req_word_sel*mlc_pkg::DATA_W +: mlc_pkg::DATA_W], req_wdata, req_wstrb);
  end

  assign req_ready = rst_n && (state == S_IDLE) && !wr_fwd_pending &&
                      (!req_valid || !is_hit || resp_ready);

  // The hit term includes req_ready on purpose: for a hit, request acceptance and response delivery
  // are the same synchronous event (PF-01), so resp_valid must never report a hit that req_ready did
  // not accept. Since req_ready itself depends on resp_ready for a hit, the CPU must drive
  // resp_ready independently of resp_valid - deriving it from having seen resp_valid deadlocks.
  // This is a binding interface requirement: docs/04_interfaces.md §1.
  assign resp_valid = (state == S_UPDATE_TAG) || (state == S_IDLE && req_valid && req_ready && is_hit);

  always_comb begin
    if (state == S_UPDATE_TAG) resp_rdata = miss_line_rd[miss_word_sel*mlc_pkg::DATA_W +: mlc_pkg::DATA_W];
    else                       resp_rdata = req_line_rd[req_word_sel*mlc_pkg::DATA_W +: mlc_pkg::DATA_W];
  end

  assign dn_resp_ready = (state == S_ALLOC_FILL);

  always_comb begin
    if (wr_fwd_pending) begin
      dn_req_valid = 1'b1; dn_req_addr = wr_fwd_addr; dn_req_we = 1'b1;
      dn_req_wdata = wr_fwd_wdata; dn_req_wstrb = wr_fwd_wstrb;
    end else if (state == S_IDLE && req_valid && req_ready && req_we && is_hit) begin
      dn_req_valid = 1'b1; dn_req_addr = req_addr; dn_req_we = 1'b1;
      dn_req_wdata = req_wdata; dn_req_wstrb = req_wstrb;
    end else if (state == S_ALLOC_FILL) begin
      dn_req_valid = 1'b1; dn_req_addr = miss_addr; dn_req_we = 1'b0;
      dn_req_wdata = '0; dn_req_wstrb = '0;
    end else begin
      dn_req_valid = 1'b0; dn_req_addr = '0; dn_req_we = 1'b0;
      dn_req_wdata = '0; dn_req_wstrb = '0;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state          <= S_IDLE;
      wr_fwd_pending <= 1'b0;
      for (int i = 0; i < mlc_pkg::L1_SETS; i++) valid_array[i] <= 1'b0;
      // tag_array/data_array and the skid register's payload fields (wr_fwd_addr/wdata/wstrb)
      // are intentionally not reset - their contents are don't-care until validated by their
      // respective valid/pending bit, per FR-06.
    end else begin

      if (wr_fwd_pending) begin
        if (dn_req_ready) wr_fwd_pending <= 1'b0;
      end else if (state == S_IDLE && req_valid && req_ready && req_we && is_hit && !dn_req_ready) begin
        wr_fwd_pending <= 1'b1;
        wr_fwd_addr    <= req_addr;
        wr_fwd_wdata   <= req_wdata;
        wr_fwd_wstrb   <= req_wstrb;
      end

      case (state)
        S_IDLE: begin
          if (req_valid && req_ready) begin
            if (is_hit) begin
              if (req_we) begin
                data_array[req_index] <= hit_write_line_merged;
              end
            end else begin
              miss_addr     <= req_addr;
              miss_index    <= req_index;
              miss_tag      <= req_tag;
              miss_word_sel <= req_word_sel;
              miss_is_write <= req_we;
              miss_wdata    <= req_wdata;
              miss_wstrb    <= req_wstrb;
              state <= S_ALLOC_FILL;
            end
          end
        end

        S_ALLOC_FILL: begin
          if (dn_resp_valid) begin
            tag_array[miss_index]   <= miss_tag;
            valid_array[miss_index] <= 1'b1;
            data_array[miss_index]  <= fill_line_merged;
            if (miss_is_write) begin
              wr_fwd_pending <= 1'b1;
              wr_fwd_addr    <= miss_addr;
              wr_fwd_wdata   <= miss_wdata;
              wr_fwd_wstrb   <= miss_wstrb;
            end
            state <= S_UPDATE_TAG;
          end
        end

        S_UPDATE_TAG: begin
          if (resp_ready) state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
