# 03 — Microarchitecture

**IP:** `mlc_cache_controller`
**Document status:** Phase 0 — Baseline.
**Revision:** 0.1

---

## 1. Controller FSMs

Two FSM shapes exist in this design — not four — because L1-I, L1-D share one shape and L2, L3
share the other (FR-11, FR-17). Both are Mealy-ish: the hit path is combinational and does not
pass through a state transition at all; the FSM only exists to sequence a *miss*.

### 1.1 L1 (write-through, direct-mapped) — 4 states

```
        ┌──────┐  req & hit            ┌──────┐
   ┌───>│ IDLE │──────────────────────>│ IDLE │  (same-cycle response, no state change)
   │    └──┬───┘                       └──────┘
   │       │ req & miss
   │       v
   │  ┌───────────┐
   │  │ TAG_CHECK │  (combinational; miss detected same cycle as IDLE's req)
   │  └─────┬─────┘
   │        v
   │  ┌────────────┐   downstream (L2) response arrives
   │  │ ALLOC_FILL │──────────────────────────────┐
   │  └────────────┘                              v
   │                                        ┌─────────────┐
   └────────────────────────────────────────│ UPDATE_TAG  │
                                             └─────────────┘
```

No `EVICT_WRITEBACK` state exists here — direct consequence of write-through (FR-09/D-003): the
line being replaced is never dirty, so it is simply overwritten in `UPDATE_TAG`. `TAG_CHECK` is
drawn as a state for clarity but is implemented combinationally in the same cycle as `IDLE`
sees the request; the FSM registers only track "am I currently waiting on a fill."

| State | `req_ready` | Exit condition |
|---|---|---|
| `IDLE` | 1 | Hit: stay in `IDLE`. Miss: go to `ALLOC_FILL`. |
| `ALLOC_FILL` | 0 | L2 response valid: go to `UPDATE_TAG`. |
| `UPDATE_TAG` | 0 | One cycle to commit tag+valid+data: go to `IDLE`, re-present the original request as a hit. |

### 1.2 L2 / L3 (write-back, set-associative) — 5 states

```
   ┌──────┐  req & hit (any way)         ┌──────┐
   │ IDLE │─────────────────────────────>│ IDLE │
   └──┬───┘                              └──────┘
      │ req & miss (all ways)
      v
 ┌───────────┐
 │ TAG_CHECK │ ── select victim way via PLRU ──┐
 └───────────┘                                 │
                                     victim.dirty == 1        victim.dirty == 0
                                                │                       │
                                                v                       │
                                    ┌────────────────────┐              │
                                    │  EVICT_WRITEBACK    │              │
                                    │ (to adapter/AXI4)   │              │
                                    └──────────┬───────────┘              │
                                               │                        │
                                               └──────────┬─────────────┘
                                                          v
                                                 ┌────────────┐
                                                 │ ALLOC_FILL │
                                                 └──────┬─────┘
                                                        v
                                                 ┌─────────────┐
                                                 │ UPDATE_TAG  │──> IDLE
                                                 └─────────────┘
```

| State | `req_ready` | Exit condition |
|---|---|---|
| `IDLE` | 1 | Hit (any of N ways): stay in `IDLE`, update PLRU. Miss: go to `TAG_CHECK`. |
| `TAG_CHECK` | 0 | PLRU victim selected combinationally: dirty -> `EVICT_WRITEBACK`; clean -> `ALLOC_FILL`. |
| `EVICT_WRITEBACK` | 0 | Write-back accepted by adapter/AXI4 fill engine: go to `ALLOC_FILL`. |
| `ALLOC_FILL` | 0 | Fill response arrives (from adapter, for L2; from AXI4 fill engine, for L3): go to `UPDATE_TAG`. |
| `UPDATE_TAG` | 0 | Commit tag+valid+dirty(=0, since a fresh fill is clean)+data+PLRU: go to `IDLE`, re-present as a hit. |

**Why the FSM is drawn identically for L2 and L3.** They are the same controller module at
different elaboration parameters (FR-17); the only thing that differs is `N` (ways), the
PLRU tree width, and which module sits downstream of `EVICT_WRITEBACK`/`ALLOC_FILL` (the
adapter for L2, the AXI4 fill engine for L3).

---

## 2. Tree-PLRU: Algorithm and Worked Example

For `N` ways (`N` a power of 2), the tree has `N-1` one-bit nodes. Each bit answers "which
subtree currently holds the least-recently-used way": `0` = victim is in the left subtree,
`1` = victim is in the right subtree.

**Update rule (on every access — hit or fill, per FR-16):** walk the root-to-leaf path to the
accessed way. At every node on that path, set the bit to point *away* from the child just
traversed (the side just used becomes MRU, so the tree should prefer evicting from the *other*
side next).

**Victim-selection rule (on a miss, before the new line is known):** walk from the root,
following each node's bit (`0`->left, `1`->right) until a leaf is reached. That leaf is the
victim way. Selection does not itself modify the tree — the tree updates when the new line is
subsequently filled in (that fill is itself an access, per the update rule above), which is
exactly why FR-16 says "every access," not "every hit."

### 2.1 Worked example, N=4 (L2's shape, 3 bits: `b0`=root, `b1`=left child, `b2`=right child)

Topology: `b0` selects between the {way0,way1} subtree (left, under `b1`) and the {way2,way3}
subtree (right, under `b2`). `b1` selects way0 (`b1=0`) vs. way1 (`b1=1`). `b2` selects way2
(`b2=0`) vs. way3 (`b2=1`).

| Event | `b0` | `b1` | `b2` | Victim if evicted now | Why |
|---|---|---|---|---|---|
| Reset | 0 | 0 | 0 | way0 | `b0=0`->left->`b1`; `b1=0`->way0 |
| Access way0 | 1 | 1 | 0 | way2 | way0's path is root->`b1`. Both flip away from the side taken: `b0`:=1 (right), `b1`:=1 (points at way0's sibling, way1). `b2` untouched. Reading: `b0=1`->right->`b2`; `b2=0`->way2 |
| Access way2 | 0 | 1 | 1 | way1 | way2's path is root->`b2`. Both flip away from the side taken: `b0`:=0 (left), `b2`:=1 (points at way2's sibling, way3). `b1` untouched (stays 1 from the previous row). Reading: `b0=0`->left->`b1`; `b1=1`->way1 |

After this sequence, way1 is correctly identified as the victim: it is one of the two ways never
accessed since reset (way1, way3), and the tree has narrowed to it specifically because the
way0 access already marked way1 as the preferred victim *within the left subtree*, and the root
currently favors the left subtree (since the right subtree, containing the just-accessed way2,
is now the MRU side). Way3 — the *other* untouched way — is not selected, because a single root
bit cannot simultaneously protect both never-accessed ways when they sit in different subtrees;
this is precisely the approximation PLRU makes in exchange for O(log N) state (the tradeoff
accepted in D-007), and why it is called *pseudo*-LRU rather than exact LRU.

### 2.2 N=8 (L3's shape, 7 bits)

Identical rule, one level deeper: root `b0` selects between the {way0..3} subtree and the
{way4..7} subtree; `b1`/`b2` are the second-level nodes for each half; `b3..b6` are the
third-level nodes directly above each pair of leaves. State size is `N-1` bits regardless of
depth, which is the entire point of choosing PLRU over true LRU (D-007): L3's replacement state
is 7 bits/set here, versus `ceil(log2(8!))` ~= 16 bits/set for an exact-ordering true-LRU
encoding at the same associativity — a measurable area claim to be confirmed in Phase 9 (AR-03).

---

## 3. Line-Size Adapter (`l2_l3_width_adapter`)

L3's line (64 B) covers exactly two L2 lines' worth of address space (32 B each). The adapter's
job is address translation between the two granularities, not data duplication: **an L2 request
is always answered with exactly the one 32 B half it addressed**, never both halves
unconditionally (this refines FR-19's "split into 2 ordered beats" — the two beats are the
adapter's two *addressable* halves, and a given request is routed to exactly one of them; both
halves are never pushed into L2 speculatively, consistent with the NINE inclusion decision, D-008
— L2 holds only what it explicitly asked for).

**Which half:** L2's offset is address bits `[4:0]`; L3's offset is address bits `[5:0]`. Bit
`[5]` is therefore exactly "which half of the containing L3 line this address falls in" — the
adapter uses this single bit as its half-select, requiring no additional state or lookup.

**Fill direction (L3 -> L2):** the adapter forwards the addressed 32 B half of the 64 B L3 line
(already fully present in the L3 array, whether it got there from a hit or a fresh AXI4 fetch)
back to the requesting L2.

**Write-back direction (L2 -> L3):** L3's data array is organized as two independently
write-enabled 32 B half-words per line (the same byte-enable concept used for CPU-side writes,
one granularity level up). An L2 write-back updates only the addressed half and sets the L3
line's dirty bit; it never requires the other half to also be dirty or present as a precondition
(FR-20).

---

## 4. AXI4 Fill Engine (`axi4_fill_engine`)

A minimal AXI4 master: it has exactly two jobs, both triggered by L3, each producing exactly one
fixed-length burst (FR-22/FR-23/FR-24).

| Trigger | AXI4 channels driven | Burst length | Burst type |
|---|---|---|---|
| L3 miss (need a line) | `AR` then `R` | `L3_LINE_B / AXI_DATA_W` beats | `INCR`, size = full bus width |
| L3 dirty-victim eviction | `AW`+`W` then `B` | `L3_LINE_B / AXI_DATA_W` beats | `INCR`, size = full bus width |

At the default parameters (`L3_LINE_B=64`, `AXI_DATA_W=32`), every burst is exactly 16 beats.
`ARADDR`/`AWADDR` is always line-aligned (the low `log2(L3_LINE_B)` = 6 bits are always zero),
because every request the fill engine ever issues originates from a full-line L3 miss or
eviction — there is no narrower or unaligned case to handle (FR-24), which is what keeps this
module small: it has no address-alignment logic to write because misalignment cannot occur by
construction.

---

## 5. Expected Critical Path (prediction, to be confirmed — TR-03)

The widest combinational hit path is expected at **L3**: an 8-way parallel tag compare, an
8-way effective-address-valid AND, and an 8:1 data-way mux, all combinational (PF-01 requires
same-cycle hit response at every level, including the most associative one). L2's 4-way version
of the same structure is expected to be faster; L1's direct-mapped path has no way-mux at all
(D-003) and is expected to be the fastest of the three. **This is a prediction, not a
measurement** — Phase 8 STA will confirm or correct it, and any discrepancy will be explained in
that phase's report rather than silently reconciled here.

---

*Next document: `04_interfaces.md`*
