Static timing, timing-driven mapping, one unit at a time (OpenSTA 2.7.0; from `build/reports/timing_summary.md`):

| point | cells | area (um^2) | min period (ns) | Fmax (MHz) | limiting class | depth | worst hold slack (ns) |
|---|---|---|---|---|---|---|---|
| reset_sync_speed | 3 | 54 | 0.638 | 1567.4 | reg2out | 0 | 0.331 |
| arbiter_speed | 95 | 1,041 | 1.859 | 537.9 | reg2out | 4 | 0.517 |
| adapter_speed | 316 | 3,332 | 1.446 | 691.6 | in2out | 3 | 0.553 |
| axi4_engine_speed | 3,791 | 35,425 | 2.495 | 400.8 | reg2reg | 7 | 0.481 |
| l1_icache_speed | 128,692 | 1,514,111 | 4.171 | 239.8 | reg2out | 16 | 0.431 |
| l1_dcache_speed | 132,737 | 1,548,375 | 5.929 | 168.7 | in2reg | 23 | 0.427 |
| l2_default_speed | 887,109 | 13,679,955 | 9.028 | 110.8 | in2reg | 34 | 0.416 |
| l3_32k_w8_speed | 1,146,921 | 12,663,505 | 8.274 | 120.9 | in2reg | 32 | 0.418 |

Same flow at 8 KiB (the comparison the microarchitecture document predicted):

| point | cells | area (um^2) | min period (ns) | Fmax (MHz) | limiting class | depth | in2reg | req2resp |
|---|---|---|---|---|---|---|---|---|
| l1_dcache_8k_speed | 260,514 | 3,066,431 | 5.545 | 180.3 | in2reg | 25 | 5.545 | 4.292 |
| l2_8k_w4_speed | 226,336 | 3,474,946 | 8.514 | 117.5 | in2reg | 28 | 8.514 | 7.172 |
| l3_8k_w4_speed | 293,374 | 3,212,237 | 7.052 | 141.8 | in2reg | 27 | 7.052 | 6.040 |
| l3_8k_w8_speed | 293,500 | 3,222,235 | 7.220 | 138.5 | in2reg | 29 | 7.220 | 6.317 |
