# sky130hd/

`sky130hd_tt.lib` is the Sky130 high-density standard-cell library at the typical corner (`tt_025C_1v80`, 1.80 V, 25 C),
copied byte for byte so that synthesis needs nothing outside this repository (SR-07).

| | |
|---|---|
| Library name inside the file | `sky130_fd_sc_hd__tt_025C_1v80` |
| Copied from | `OpenROAD/test/sky130hd/sky130_fd_sc_hd__tt_025C_1v80.lib` on the development machine (the file `sky130hd_tt.lib` there is a symlink to it) |
| SHA-256 | `92eb4e93a3d4c2563018ac81cdec2f02fdeaced9b39337ed5c141fa63e0ad8f8` (same as the copy in the `Full-Adder` project) |
| Size | 12,800,126 bytes |
| Origin and licence | SkyWater `sky130_fd_sc_hd`, published by SkyWater under Apache-2.0; the file carries no licence header of its own |

Only the library `scripts/synth.tcl` reads is here. The LEF and track files that place and route needs (Phase 9) are added
with that phase.
