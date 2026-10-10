# 02 — System Architecture

**IP:** `mlc_cache_controller`
**Document status:** Phase 0 — Baseline.
**Revision:** 0.1

---

## 1. Scope Statement

Single CPU-side requester (or a test harness standing in for one). Three cache levels between
that requester and main memory. No cache coherency protocol exists in this design because there
is exactly one requester per hierarchy instance — coherency exists to keep multiple requesters'
views of memory consistent, which is not a problem this IP has (D-001). No virtual memory: every
address on the CPU-side port is a physical address (D-011).

```
                 ┌───────────────┐   ┌───────────────┐
   CPU fetch --->│  L1-I cache   │   │  L1-D cache   │<--- CPU load/store
                 │ (DM, WT, 1-way│   │ (DM, WT, 1-way│
                 │  4KiB/32B)    │   │  4KiB/32B)    │
                 └───────┬───────┘   └───────┬───────┘
                         │                   │
                         └─────────┬─────────┘
                                   v
                         ┌───────────────────┐
                         │    l1_l2_arbiter    │   round-robin, one L2 port
                         │ (routes responses)  │   shared by both L1s (D-033)
                         └─────────┬─────────┘
                                   v
                         ┌───────────────────┐
                         │       L2 cache      │
                         │ (4-way SA, WB, PLRU │
                         │   32KiB/32B line)   │
                         └─────────┬───────────┘
                                   v
                         ┌───────────────────┐
                         │ l2_l3_width_adapter │   32B <-> 64B line-size
                         │  (1 L3 line = 2 L2  │   adaptation (D-009)
                         │   line-sized beats) │
                         └─────────┬───────────┘
                                   v
                         ┌───────────────────┐
                         │       L3 cache      │
                         │ (8-way SA, WB, PLRU │
                         │  256KiB/64B line)   │
                         └─────────┬───────────┘
                                   v
                         ┌───────────────────┐
                         │   axi4_fill_engine  │
                         │  (AXI4 master, one  │
                         │  burst per line)    │
                         └─────────┬───────────┘
                                   v
                              AXI4 to memory
```

Both L1 instances present the same interface shape and share the *same* L2 instance (unified L2,
per the locked scope decision) through `l1_l2_arbiter` (D-033) — L2 has one upstream port and
does not know or care whether a request originated from L1-I or L1-D. The arbiter is the only
place that knows there are two requesters.

---

## 2. Address Partitioning

Every level splits the 32-bit physical address into **tag | index | offset**, each field
`$clog2`-derived from that level's capacity/line/ways parameters (NR-05). No two levels share an
index or offset width by coincidence — each is independently derived and then checked for
internal consistency (sets x ways x line == capacity) as an elaboration-time assertion.

### 2.1 L1 (4 KiB, 32 B line, direct-mapped)

```
lines = 4096 / 32       = 128
sets  = 128 / 1 (ways)  = 128
offset bits = log2(32)  = 5
index  bits = log2(128) = 7
tag    bits = 32 - 7 - 5 = 20

 31                12 11        5 4      0
┌─────────────────────┬───────────┬────────┐
│      tag (20)        │ index (7) │ off (5)│
└─────────────────────┴───────────┴────────┘
```

Per-line metadata: 1 valid bit, **no dirty bit** (write-through lines are never dirty — direct
consequence of FR-08/D-003). Tag-array storage per instance: 128 x (20+1) = 2,688 bits.

### 2.2 L2 (32 KiB, 32 B line, 4-way)

```
lines = 32768 / 32      = 1024
sets  = 1024 / 4 (ways) = 256
offset bits = log2(32)  = 5
index  bits = log2(256) = 8
tag    bits = 32 - 8 - 5 = 19

 31                13 12         5 4      0
┌─────────────────────┬────────────┬────────┐
│      tag (19)        │ index (8)  │ off (5)│
└─────────────────────┴────────────┴────────┘
```

Per-line metadata: valid + dirty = 2 bits. Tag-array storage: 256 sets x 4 ways x (19+2) = 21,504
bits. PLRU tree storage: 3 bits/set (N-1 for 4-way) x 256 sets = 768 bits.

### 2.3 L3 (256 KiB, 64 B line, 8-way)

```
lines = 262144 / 64     = 4096
sets  = 4096 / 8 (ways) = 512
offset bits = log2(64)  = 6
index  bits = log2(512) = 9
tag    bits = 32 - 9 - 6 = 17

 31                15 14         6 5      0
┌─────────────────────┬────────────┬────────┐
│      tag (17)        │ index (9)  │ off (6)│
└─────────────────────┴────────────┴────────┘
```

Per-line metadata: valid + dirty = 2 bits. Tag-array storage: 512 sets x 8 ways x (17+2) = 77,824
bits. PLRU tree storage: 7 bits/set (N-1 for 8-way) x 512 sets = 3,584 bits.

**Why L3's index sits at different bit positions than L2's, for the same physical address bits
6..14 vs 5..12.** This is expected and correct, not a bug to reconcile: each level indexes
independently off its *own* offset width, because each level's set is selected by "which line of
*this level's* size does this address fall into," not by any shared indexing scheme with the
level above. The adapter (§4) is precisely the component that bridges this difference — it does
not require the two levels to agree on indexing, only on which 2 L2 lines correspond to 1 L3
line.

---

## 3. Module List and Responsibilities

| Module | Responsibility | Does NOT do |
|---|---|---|
| `l1_icache_ctrl` / `l1_dcache_ctrl` | Direct-mapped write-through cache: tag compare, hit data return, write-through forwarding, miss request to L2 | No replacement policy (nothing to replace among 1 way); no write-back state |
| `l1_l2_arbiter` | Lets the two L1 controllers share L2's single upstream port: shows L2 one request at a time (round-robin on a tie), remembers which L1 owns an outstanding read, and routes the response and its `resp_ready` to that owner | No cache state, no addresses decoded, never changes a request; no register on the request or response path (what that costs in latency is not measured, PF-03) |
| `l2_cache_ctrl` | 4-way set-associative write-back cache: tag compare across ways, PLRU-based victim selection, dirty tracking, eviction write-back to the adapter | Does not know about L1's existence or count (a request looks the same regardless of which L1 instance issued it) |
| `l2_l3_width_adapter` | Splits one L3 line into 2 ordered L2-line beats on fill; merges 2 L2-line write-backs into one (possibly partial-dirty) L3 line update | No tag/valid/dirty state of its own — it is a sequencer/router, not a cache |
| `l3_cache_ctrl` | 8-way set-associative write-back cache, same controller design as L2 parameterized wider; drives the AXI4 fill engine on its own misses/evictions | Does not talk AXI4 directly (that is `axi4_fill_engine`'s job) |
| `axi4_fill_engine` | AXI4 master: converts a "fetch this line" / "write back this line" request into the correct fixed-length burst | No cache state; purely a protocol-shaping module |
| `plru_tree` | Parameterized N-way tree-PLRU: victim selection and per-access state update | Reused, unmodified, by both `l2_cache_ctrl` and `l3_cache_ctrl` at their respective `N` |
| `mlc_cache_top` | Structural integration only: instantiates and wires the above, synchronises the reset with `reset_sync`, and drives constants on the AXI4 sideband signals the engine does not use (D-034) | Contains no logic of its own — a reviewer verifying "is there hidden behavior in the top" can confirm it by inspection alone, and `scripts/check_top.py` (part of `make check`) rejects any logic of the kinds it knows (blocks, gates, operators, ternaries, parameter overrides) and any mis-wire it can see; D-034 lists what it cannot |

---

## 4. Data Flow

### 4.1 Read hit at L1

CPU issues `req_valid` with `req_we=0`. L1 tag-compares combinationally; on a hit, `resp_valid`
and `resp_rdata` are driven the same cycle (PF-01). L2/L3/AXI4 are not touched.

### 4.2 Read miss at L1, hit at L2

L1 drops `req_ready`, issues a line-fill request to L2 carrying the L1 line's address. L2
tag-compares its 4 ways; on a hit, L2 returns the full L2 line (which equals the L1 line size —
both are 32 B) to L1, which installs it (overwriting whatever was in that direct-mapped set,
per FR-09) and then re-services the original CPU request as a hit.

### 4.3 Read miss at L1 and L2, hit at L3

L2 misses, drops readiness, selects a victim way via PLRU, and if that way is dirty, hands the
victim line to the adapter for write-back before requesting the new line. The adapter — because
one L3 line is 2 L2 lines — must track *which half* of the corresponding L3 line this write-back
or fill touches, using the low bit of the L2-line address that lies above L2's own offset field
but below L3's offset field (i.e., address bit 5, since L2's offset is bits [4:0] and L3's offset
is bits [5:0] — this single bit is exactly "which half of the L3 line"). L3 tag-compares; on a
hit, returns the requested L2-sized half immediately (no need to also return the other half
unless it is separately requested).

### 4.4 Miss all the way to memory

L3 misses, selects a victim way via PLRU, writes back if dirty (one AXI4 `AW`/`W` burst via the
fill engine), then issues one AXI4 `AR` burst for the missing line. On completion, the line
installs into L3, splits into 2 halves for the adapter, and propagates up through L2 and L1
exactly as in §4.2/§4.3.

---

## 5. Why This Shape (Summary of Locked Tradeoffs)

Full reasoning for every decision below is in `engineering_log.md`; this table is the
navigational summary the requirements doc's Non-Objectives table already points to.

| Decision | Chosen | Rejected alternative | One-line why | Log |
|---|---|---|---|---|
| Coherency scope | Single-core, none | Multi-core MESI/MSI | Coherency's own verification matrix is a separate project | D-001 |
| Level count | 3 (L1/L2/L3) | 2 (L1/L2) | Differentiates from a simpler existing single-level design; gives 3 genuinely distinct tradeoff points | D-002 |
| L1 organization | Direct-mapped, write-through | Set-associative, write-back | Shortest critical path and shortest FSM at the level that must respond fastest | D-003 |
| Miss handling | Blocking | Non-blocking (MSHR) | Bounds verification complexity for v1; named as a future phase, not dropped | D-004 |
| L1 split | Separate I$/D$, unified L2/L3 | Unified L1 | Matches real front-ends; avoids duplicating L2/L3 for no reason | D-005 |
| Replacement policy (L2/L3) | Tree-PLRU | True LRU / random | O(log N) state and update cost vs O(N); realistic choice above 2-way | D-007 |
| Inclusion policy | NINE | Inclusive / Exclusive | Both exist to bound coherency traffic, which doesn't apply here | D-008 |
| L3 line size | 64 B (2x L2) | Same as L2 (32 B) | Amortizes AXI4 burst/DRAM-row overhead where it matters most (closest to memory) | D-009 |
| Interfaces | Custom valid/ready (CPU) + AXI4 (memory) | AXI4-Lite everywhere / custom everywhere | Keeps the hit path protocol-overhead-free; AXI4 bursts map naturally to line fills | D-010 |
| Address scope | Physical only, no MMU/TLB | Include address translation | Out of scope for a cache-controller project | D-011 |
| AXI4 transfer shape | Whole-line bursts only | Partial/narrow transfers | Small compliance surface; matches real LLC-to-memory behavior | D-012 |

---

*Next document: `03_microarchitecture.md`*
