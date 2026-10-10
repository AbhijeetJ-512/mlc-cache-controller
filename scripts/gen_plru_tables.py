#!/usr/bin/env python3
"""Generate the expected-victim tables for sim/tb_plru_ways.sv.

The model is deliberately written differently from the RTL. The RTL walks root to leaf with an
iterative bit path; this one recurses on way ranges [lo, hi), so a shared misreading of the
heap-index scheme would not be repeated here.

Tree-PLRU: each internal node holds one bit. 0 = the victim is in the left (lower) half, 1 = the
right (upper) half. Accessing way w sets every bit on its path to point AWAY from w.
Starting state is all zeros (the reset state).
"""
import sys

def victim(bits, lo, hi, node):
    if hi - lo == 1:
        return lo
    mid = (lo + hi) // 2
    if bits[node]:
        return victim(bits, mid, hi, 2 * node + 2)
    return victim(bits, lo, mid, 2 * node + 1)

def access(bits, way, lo, hi, node):
    if hi - lo == 1:
        return
    mid = (lo + hi) // 2
    if way < mid:
        bits[node] = 1            # accessed the left half, so point right
        access(bits, way, lo, mid, 2 * node + 1)
    else:
        bits[node] = 0            # accessed the right half, so point left
        access(bits, way, mid, hi, 2 * node + 2)

def run(ways, seq):
    bits = [0] * (ways - 1)
    for w in seq:
        access(bits, w, 0, ways, 0)
    return victim(bits, 0, ways, 0)

def main():
    # Facts checked by hand, independent of the code above.
    assert run(2, [0]) == 1 and run(2, [1]) == 0
    assert run(4, [0]) == 2 and run(4, [0, 2]) == 1          # the Phase 0 worked example
    assert run(8, list(range(8))) == 0                       # touched in order 0..7, the oldest is 0
    assert run(8, list(range(8)) + [0]) == 4

    out = []
    for ways in (2, 8):
        n = ways
        out.append(f"    // ---- WAYS = {ways}: expected victim after each access sequence of length 1 and 2 ----")
        for a in range(n):
            out.append(f"    exp{ways}_len1[{a}] = {run(ways, [a])};")
        for a in range(n):
            for b in range(n):
                out.append(f"    exp{ways}_len2[{a * n + b}] = {run(ways, [a, b])};")
    sys.stdout.write("\n".join(out) + "\n")

main()
