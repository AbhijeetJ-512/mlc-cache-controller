package mlc_pkg;

  // Global widths (01_requirements.md PM-09, PM-10)
  localparam int ADDR_W         = 32;
  localparam int DATA_W         = 32;
  localparam int BYTES_PER_WORD = DATA_W / 8;

  // L1 parameters (01_requirements.md PM-01, PM-02; 02_architecture.md §2.1)
  localparam int L1_CAPACITY_B     = 4096;
  localparam int L1_LINE_B         = 32;
  localparam int L1_LINE_W         = L1_LINE_B * 8;
  localparam int L1_WORDS_PER_LINE = L1_LINE_B / BYTES_PER_WORD;
  localparam int L1_SETS           = L1_CAPACITY_B / L1_LINE_B; // direct-mapped: sets == lines
  localparam int L1_OFFSET_W       = $clog2(L1_LINE_B);         // 5
  localparam int L1_INDEX_W        = $clog2(L1_SETS);           // 7
  localparam int L1_TAG_W          = ADDR_W - L1_INDEX_W - L1_OFFSET_W; // 20
  localparam int L1_WORD_SEL_W     = $clog2(L1_WORDS_PER_LINE); // 3

  // L2 parameters (01_requirements.md PM-03..PM-05; 02_architecture.md §2.2)
  localparam int L2_CAPACITY_B = 32768;
  localparam int L2_LINE_B     = 32;
  localparam int L2_WAYS       = 4;

endpackage
