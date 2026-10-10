module plru_tree #(
  parameter int WAYS = 4,
  parameter int SETS = 256
) (
  input  logic                          clk,
  input  logic                          rst_n,

  input  logic [$clog2(SETS)-1:0]       set_index,
  output logic [$clog2(WAYS)-1:0]       victim_way,

  input  logic                          access_valid,
  input  logic [$clog2(SETS)-1:0]       access_set,
  input  logic [$clog2(WAYS)-1:0]       access_way
);

  localparam int LEVELS = $clog2(WAYS);

  logic [WAYS-2:0] state [0:SETS-1];

  // The way index is accumulated in an int, not in a $clog2(WAYS)-bit vector shifted left each
  // level: the shifted form needs a part-select [$clog2(WAYS)-2:0], which is out of order (and a
  // compile error) at WAYS=2, where LEVELS is 1.
  function automatic logic [$clog2(WAYS)-1:0] select_victim(input logic [WAYS-2:0] st);
    int node;
    int way;
    node = 0;
    way  = 0;
    for (int lvl = 0; lvl < LEVELS; lvl++) begin
      way = (way * 2) + (st[node] ? 1 : 0);
      if (st[node] == 1'b0) node = 2*node + 1;
      else                  node = 2*node + 2;
    end
    select_victim = way[$clog2(WAYS)-1:0];
  endfunction

  function automatic logic [WAYS-2:0] next_state(input logic [WAYS-2:0] st, input logic [$clog2(WAYS)-1:0] way);
    int node;
    logic [WAYS-2:0] ns;
    ns   = st;
    node = 0;
    for (int lvl = 0; lvl < LEVELS; lvl++) begin
      logic dir;
      dir = way[$clog2(WAYS)-1-lvl];
      ns[node] = ~dir;
      if (dir == 1'b0) node = 2*node + 1;
      else             node = 2*node + 2;
    end
    next_state = ns;
  endfunction

  assign victim_way = select_victim(state[set_index]);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      for (int i = 0; i < SETS; i++) state[i] <= '0;
    end else begin
      if (access_valid) state[access_set] <= next_state(state[access_set], access_way);
    end
  end

endmodule
