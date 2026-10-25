Synthesis, default configuration (Yosys 0.33, Sky130HD typical corner, `abc -fast`; from `build/reports/summary.md`):

| point | parameters | area (um^2) | cells | flip-flops | flip-flop area |
|---|---|---|---|---|---|
| reset_sync | defaults | 54 | 3 | 2 | 93% |
| l1_icache | defaults | 1,455,566 | 162,596 | 35,491 | 49% |
| l1_dcache | defaults | 1,496,114 | 166,059 | 35,596 | 48% |
| l2_default | defaults | 15,047,108 | 2,249,289 | 284,763 | 38% |
| adapter | defaults | 3,323 | 800 | 0 |  |
| arbiter | defaults | 1,026 | 108 | 3 | 7% |
| axi4_engine | defaults | 36,102 | 5,511 | 554 | 31% |
| l3_32k_w8 | CAPACITY_B=32768 WAYS=8 | 14,710,293 | 2,189,987 | 274,710 | 37% |
