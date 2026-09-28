import mlc_pkg::*;

module l1_cache_ctrl (
  input  logic                      clk,
  input  logic                      rst_n,

  input  logic                      req_valid,
  output logic                      req_ready,
  input  logic [ADDR_W-1:0]         req_addr,
  input  logic                      req_we,
  input  logic [DATA_W-1:0]         req_wdata,
  input  logic [BYTES_PER_WORD-1:0] req_wstrb,
  output logic                      resp_valid,
  input  logic                      resp_ready,
  output logic [DATA_W-1:0]         resp_rdata,

  output logic                      dn_req_valid,
  input  logic                      dn_req_ready,
  output logic [ADDR_W-1:0]         dn_req_addr,
  output logic                      dn_req_we,
  output logic [DATA_W-1:0]         dn_req_wdata,
  output logic [BYTES_PER_WORD-1:0] dn_req_wstrb,
  input  logic                      dn_resp_valid,
  output logic                      dn_resp_ready,
  input  logic [L1_LINE_W-1:0]      dn_resp_line
);

  typedef enum logic [1:0] {S_IDLE, S_ALLOC_FILL, S_UPDATE_TAG} state_e;
  state_e state;

  logic [L1_TAG_W-1:0]  tag_array   [0:L1_SETS-1];
  logic                 valid_array [0:L1_SETS-1];
  logic [L1_LINE_W-1:0] data_array  [0:L1_SETS-1];

  logic [L1_TAG_W-1:0]      req_tag;
  logic [L1_INDEX_W-1:0]    req_index;
  logic [L1_WORD_SEL_W-1:0] req_word_sel;
  assign req_tag      = req_addr[ADDR_W-1 -: L1_TAG_W];
  assign req_index    = req_addr[L1_OFFSET_W +: L1_INDEX_W];
  assign req_word_sel = req_addr[2 +: L1_WORD_SEL_W]; // req_addr[1:0] assumed 00 (word-aligned)

  logic is_hit;
  assign is_hit = valid_array[req_index] && (tag_array[req_index] == req_tag);

  logic [ADDR_W-1:0]        miss_addr;
  logic [L1_INDEX_W-1:0]    miss_index;
  logic [L1_TAG_W-1:0]      miss_tag;
  logic [L1_WORD_SEL_W-1:0] miss_word_sel;
  logic                     miss_is_write;
  logic [DATA_W-1:0]        miss_wdata;
  logic [BYTES_PER_WORD-1:0] miss_wstrb;

  logic                      wr_fwd_pending;
  logic [ADDR_W-1:0]         wr_fwd_addr;
  logic [DATA_W-1:0]         wr_fwd_wdata;
  logic [BYTES_PER_WORD-1:0] wr_fwd_wstrb;

  function automatic logic [DATA_W-1:0] merge_wstrb(
    input logic [DATA_W-1:0]        old_word,
    input logic [DATA_W-1:0]        new_data,
    input logic [BYTES_PER_WORD-1:0] wstrb
  );
    merge_wstrb = old_word;
    for (int b = 0; b < BYTES_PER_WORD; b++) begin
      if (wstrb[b]) merge_wstrb[b*8 +: 8] = new_data[b*8 +: 8];
    end
  endfunction

  logic [L1_LINE_W-1:0] fill_line_merged;
  always_comb begin
    fill_line_merged = dn_resp_line;
    if (miss_is_write) begin
      fill_line_merged[miss_word_sel*DATA_W +: DATA_W] =
          merge_wstrb(dn_resp_line[miss_word_sel*DATA_W +: DATA_W], miss_wdata, miss_wstrb);
    end
  end

  assign req_ready = rst_n && (state == S_IDLE) && !wr_fwd_pending &&
                      (!req_valid || !is_hit || resp_ready);

  assign resp_valid = (state == S_UPDATE_TAG) || (state == S_IDLE && req_valid && req_ready && is_hit);

  always_comb begin
    if (state == S_UPDATE_TAG) resp_rdata = data_array[miss_index][miss_word_sel*DATA_W +: DATA_W];
    else                       resp_rdata = data_array[req_index][req_word_sel*DATA_W +: DATA_W];
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
      for (int i = 0; i < L1_SETS; i++) valid_array[i] <= 1'b0;
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
                data_array[req_index][req_word_sel*DATA_W +: DATA_W] <=
                    merge_wstrb(data_array[req_index][req_word_sel*DATA_W +: DATA_W],
                                req_wdata, req_wstrb);
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
