# 04 — Interfaces

**IP:** `mlc_cache_controller`
**Document status:** Phase 0 — Baseline.
**Revision:** 0.1

---

## 1. CPU-Side Interface (custom valid/ready)

One instance of this interface per L1 controller (L1-I and L1-D each get their own — FR-11).

| Signal | Dir (from CPU) | Width | Description |
|---|---|---|---|
| `clk` | in | 1 | Single clock domain (CR-01) |
| `rst_n` | in | 1 | Active-low, async assert / sync deassert (CR-02) |
| `req_valid` | in | 1 | Request handshake, CPU -> L1 |
| `req_ready` | out | 1 | Request handshake, L1 -> CPU. Low for the entire miss duration (FR-05). |
| `req_addr` | in | `ADDR_W` (32) | Physical address |
| `req_we` | in | 1 | Write enable. **Tied 0 on the L1-I instance** (FR-10) |
| `req_wdata` | in | `DATA_W` (32) | Store data |
| `req_wstrb` | in | `DATA_W/8` (4) | Byte-enable for sub-word stores (FR-04) |
| `resp_valid` | out | 1 | Response handshake, L1 -> CPU. Same cycle as `req_valid` on a hit (PF-01) |
| `resp_ready` | in | 1 | Response handshake, CPU -> L1 |
| `resp_rdata` | out | `DATA_W` (32) | Load data |

**Hit timing (PF-01):**

```
clk       __|‾|__|‾|__|‾|__
req_valid ___/‾‾‾‾‾\________
req_ready ‾‾‾‾‾‾‾‾‾‾\________   (drops only if this same request misses)
resp_valid___/‾‾‾‾‾\________   <- same cycle as req_valid, on a hit
```

**Miss timing (schematic — exact cycle counts are per-configuration and are documented, not
fixed, per PF-02; see `03_microarchitecture.md` §1 for the state sequence):**

```
req_valid ___/‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\____
req_ready ‾‾‾‾‾‾‾‾‾‾\_______________________/‾‾‾‾
                    |<-- ALLOC_FILL, UPDATE_TAG -->|
resp_valid ________________________________/‾‾‾‾\__
```

---

## 2. Inter-Level Interfaces (L1<->L2, L2<->adapter<->L3)

Internal to the IP; not exposed at `mlc_cache_top`. Deliberately the **same signal shape** as
the CPU-side interface (`req_valid/ready/addr/we/wdata/wstrb`, `resp_valid/ready/rdata`, plus one
addition: `resp_line` — the full line-width fill payload, since a miss response carries an
entire line, not one word) so that every level-to-level boundary is uniform and `mlc_cache_top`
is pure structural wiring (see `02_architecture.md` §3, and Open Question OQ-1 in
`01_requirements.md`, which this choice resolves).

| Signal | Dir (upstream -> downstream) | Width | Description |
|---|---|---|---|
| `req_valid` / `req_ready` | fwd / back | 1 | Same handshake shape as CPU-side |
| `req_addr` | fwd | `ADDR_W` | Full physical address (the downstream level derives its own index/tag from this — §2 of `02_architecture.md`) |
| `req_we` | fwd | 1 | Set for a write-through forward (L1->L2 only) or a write-back (L2->adapter->L3, L3->AXI4) |
| `req_line` | fwd | downstream line width | For a write-back: the full evicted line's data + which-half select (L2->L3 path only, via the adapter) |
| `resp_valid` / `resp_ready` | back / fwd | 1 | Fill-response handshake |
| `resp_line` | back | downstream line width | The full fetched line |

At the L2<->L3 boundary specifically, `req_addr`/`resp_line` pass through `l2_l3_width_adapter`,
which changes the effective payload width (L2 line = 32 B in, L3 line = 64 B on the far side)
per `03_microarchitecture.md` §3 — the adapter is the only place this interface's width actually
changes; L1<->L2 carries the interface unmodified since both sides use a 32 B line (PM-02/PM-04
share the same default, though nothing prevents them from being parameterized independently for
a future exploration — the interface shape does not assume equality, only NR-06 enforces the
2:1 ratio specifically between L2 and L3).

---

## 3. Memory-Side Interface (AXI4, full)

One AXI4 master port, driven by `axi4_fill_engine`, exposed at `mlc_cache_top`.

| Channel | Signal | Width | Notes |
|---|---|---|---|
| Write address | `awaddr` | `ADDR_W` | Line-aligned always (FR-24) |
| | `awlen` | 8 | `L3_LINE_B/AXI_DATA_W - 1` (fixed per configuration) |
| | `awsize` | 3 | `log2(AXI_DATA_W/8)` (full bus width, fixed) |
| | `awburst` | 2 | `2'b01` (`INCR`), always |
| | `awvalid`/`awready` | 1 | Standard handshake |
| Write data | `wdata` | `AXI_DATA_W` | |
| | `wstrb` | `AXI_DATA_W/8` | All-ones always (whole-line writes only, FR-24) |
| | `wlast` | 1 | Asserted on the final beat of the burst |
| | `wvalid`/`wready` | 1 | Standard handshake |
| Write response | `bresp` | 2 | Latched to sticky `mem_err` on `SLVERR`/`DECERR` (FR-26) |
| | `bvalid`/`bready` | 1 | Standard handshake |
| Read address | `araddr` | `ADDR_W` | Line-aligned always |
| | `arlen` | 8 | Same derivation as `awlen` |
| | `arsize` | 3 | Same derivation as `awsize` |
| | `arburst` | 2 | `2'b01` (`INCR`), always |
| | `arvalid`/`arready` | 1 | Standard handshake |
| Read data | `rdata` | `AXI_DATA_W` | |
| | `rresp` | 2 | Latched to sticky `mem_err` on error |
| | `rlast` | 1 | Asserted on the final beat |
| | `rvalid`/`rready` | 1 | Standard handshake |

No `AWID`/`ARID`/`WID`/etc. — a single-outstanding-transaction master (consistent with the
blocking-miss decision, D-004) does not need transaction tagging; every burst completes before
the next is issued (Open Question OQ-3 in `01_requirements.md` revisits whether this remains
true if non-blocking misses are added in a later phase).

---

## 4. Parameter Reference

See `01_requirements.md` §7 for the full table (PM-01..PM-13). Every width in this document —
`ADDR_W`, `DATA_W`, line widths, `awlen`/`arlen` — is derived from those parameters at
elaboration, never hardcoded (PM-13).

---

## 5. Reset Behavior

Per CR-02..CR-04: `rst_n` low asynchronously clears every valid bit at every level and returns
every FSM to `IDLE`. `req_ready` is driven low throughout reset (a level cannot accept a request
into an array it hasn't finished invalidating) and high the cycle after `rst_n` deasserts,
matching CR-04. In-flight AXI4 transactions are not gracefully drained on reset — this is a
documented scope boundary (CR-04), not an oversight.

---

*Next document: `engineering_log.md`*
