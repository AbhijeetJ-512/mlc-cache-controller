module l1_downstream_stub #(
  parameter int FILL_LATENCY = 3
) (
  input  logic clk,
  input  logic rst_n,
  input  logic hold_not_ready,

  input  logic                      req_valid,
  output logic                      req_ready,
  input  logic [mlc_pkg::ADDR_W-1:0]         req_addr,
  input  logic                      req_we,
  input  logic [mlc_pkg::DATA_W-1:0]         req_wdata,
  input  logic [mlc_pkg::BYTES_PER_WORD-1:0] req_wstrb,

  output logic                      resp_valid,
  input  logic                      resp_ready,
  output logic [mlc_pkg::L1_LINE_W-1:0]      resp_line
);

  // Deterministic "memory": word w of the line at `addr` is (line_base_addr + w).
  function automatic logic [mlc_pkg::L1_LINE_W-1:0] line_pattern(input logic [mlc_pkg::ADDR_W-1:0] addr);
    logic [mlc_pkg::ADDR_W-1:0] line_base;
    line_pattern = '0;
    line_base = addr & ~(mlc_pkg::L1_LINE_B - 1);
    for (int w = 0; w < mlc_pkg::L1_WORDS_PER_LINE; w++) begin
      line_pattern[w*mlc_pkg::DATA_W +: mlc_pkg::DATA_W] = line_base + w;
    end
  endfunction

  typedef enum logic [1:0] {S_READY, S_BUSY, S_RESP} state_e;
  state_e state;
  int latency_cnt;
  logic [mlc_pkg::ADDR_W-1:0] latched_addr;

  assign req_ready  = (state == S_READY) && !hold_not_ready;
  assign resp_valid = (state == S_RESP);
  assign resp_line  = line_pattern(latched_addr);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_READY;
    end else begin
      case (state)
        S_READY: begin
          if (req_valid && !hold_not_ready) begin
            if (!req_we) begin
              latched_addr <= req_addr;
              latency_cnt  <= FILL_LATENCY;
              state        <= S_BUSY;
            end
            // a write-forward (req_we=1) is absorbed instantly: no response, stay S_READY
          end
        end
        S_BUSY: begin
          if (latency_cnt == 0) state <= S_RESP;
          else latency_cnt <= latency_cnt - 1;
        end
        S_RESP: begin
          if (resp_ready) state <= S_READY;
        end
        default: state <= S_READY;
      endcase
    end
  end
endmodule
