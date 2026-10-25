#!/usr/bin/env python3
"""mlc_cache_controller diagrams (dgm.py). Run: python3 docs/portfolio/diagrams/make_diagrams.py"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)   # dgm.py sits next to this file
from dgm import Diagram  # noqa: E402


def architecture():
    d = Diagram("mlc_cache_controller - hierarchy", 1060, 1250)
    d.legend = ("data", "ctrl")
    d.legend_pos = (840, 8)
    d.group("g", 60, 120, 700, 1010, "mlc_cache_top", label_pos="top")
    d.box("ci", 130, 40, 210, 60, "CPU fetch port", "io", sub="i_req_* / i_resp_*", size=12)
    d.box("cd", 520, 40, 210, 60, "CPU load / store port", "io", sub="d_req_* / d_resp_*", size=12)
    d.box("l1i", 130, 160, 210, 110, "L1-I cache", "block", sub="l1_icache_ctrl\nread only (req_we absent)", size=12)
    d.box("l1d", 520, 160, 210, 110, "L1-D cache", "block", sub="l1_dcache_ctrl\nstore hit: update + forward", size=12)
    d.box("arb", 280, 340, 300, 80, "l1_l2_arbiter", "ctrl", sub="round robin, one outstanding read", size=12)
    d.box("l2", 280, 480, 300, 120, "L2 cache", "accent", sub="l2_cache_ctrl + plru_tree\nunified, write-back", size=12)
    d.box("ad", 280, 660, 300, 90, "l2_l3_width_adapter", "ctrl", sub="32 B <-> 64 B line adaptation", size=12)
    d.box("l3", 280, 810, 300, 120, "L3 cache", "accent", sub="l3_cache_ctrl (= l2_cache_ctrl at L3 parameters)\nwrite-back", size=11)
    d.box("en", 280, 990, 300, 90, "axi4_fill_engine", "block", sub="AXI4 master, one burst per line", size=12)
    d.box("mem", 280, 1170, 300, 60, "AXI4 memory", "io", sub="m_axi_*", size=12)
    d.arrow("a1", "ci", "l1i", sside="b", dside="t", both=True)
    d.arrow("a2", "cd", "l1d", sside="b", dside="t", both=True)
    d.arrow("a3", "l1i", "arb", sside="b", dside="t", sf=0.5, df=0.2, both=True, via=[(235, 300), (340, 300)])
    d.arrow("a4", "l1d", "arb", sside="b", dside="t", sf=0.5, df=0.8, both=True, via=[(625, 300), (520, 300)])
    d.arrow("a5", "arb", "l2", sside="b", dside="t", both=True, label="word request, 32 B fill line", lpos=(530, 450))
    d.arrow("a6", "l2", "ad", sside="b", dside="t", both=True, label="32 B line (fill, write-back)", lpos=(530, 630))
    d.arrow("a7", "ad", "l3", sside="b", dside="t", both=True, label="request, 64 B response line", lpos=(530, 780))
    d.arrow("a8", "l3", "en", sside="b", dside="t", both=True, label="64 B line", lpos=(500, 960))
    d.arrow("a9", "en", "mem", sside="b", dside="t", both=True, label="AR/R or AW/W/B,\n16 beats x 32 bit", lpos=(540, 1155))
    d.text("e1", 375, 205, "word request / response", 10, color="#1f4e9c")
    # side notes
    d.box("n1", 780, 150, 250, 130, "L1 (two instances)", "note", sub="4 KiB, 32 B lines, direct mapped\nwrite-through, no dirty bit\ntag 20 | index 7 | offset 5\nreset_sync (in the top): asynchronous\nassert, synchronous de-assert", size=11)
    d.box("n2", 780, 325, 250, 110, "Arbiter", "note", sub="three state bits (busy, owner, last)\nroutes each response to its owner", size=12)
    d.box("n3", 780, 470, 250, 140, "L2", "note", sub="32 KiB, 32 B lines, 4-way\nwrite-back, tree PLRU\ntag 19 | index 8 | offset 5", size=12)
    d.box("n4", 780, 650, 250, 110, "Adapter", "note", sub="no clock, no state: address bit 5\nselects the 32 B half of the L3 line", size=12)
    d.box("n5", 780, 800, 250, 140, "L3", "note", sub="256 KiB default, 64 B lines, 8-way\nwrite-back, tree PLRU\ntag 17 | index 9 | offset 6", size=12)
    d.box("n6", 780, 980, 250, 110, "AXI4 fill engine", "note", sub="INCR, full-width beats\nline-aligned addresses by construction\nsticky mem_err", size=12)
    return d


def flowchart():
    d = Diagram("mlc_cache_controller - request and miss flow", 1420, 1540)
    d.legend = ("flow",)
    d.legend_pos = (1220, 8)
    cx = 430
    d.box("s", 250, 30, 360, 55, "CPU request at an L1", "term", sub="load, store or instruction fetch", size=12)
    d.box("d1", 250, 115, 360, 80, "L1 hit ?", "dec", sub="direct mapped: one tag compare", size=12)
    d.box("h1", 760, 120, 380, 70, "Respond from L1", "proc", sub="load: the word; store: update L1 and forward\nthe store to L2 (write-through, posted)", size=11)
    d.box("m1", 250, 225, 360, 70, "L1 ALLOC_FILL", "proc", sub="request the 32 B line from L2; the arbiter lets one\nrequester through and holds the other", size=11)
    d.box("d2", 250, 325, 360, 80, "L2 hit ?", "dec", sub="4 tag compares in parallel", size=12)
    d.box("h2", 760, 330, 380, 70, "L2 returns its 32 B line", "proc", sub="a store merges its bytes and sets the dirty bit;\nPLRU is updated", size=11)
    d.box("m2", 250, 435, 360, 70, "L2 TAG_CHECK", "proc", sub="victim: a free way first, else the PLRU choice", size=11)
    d.box("d3", 250, 535, 360, 80, "victim dirty ?", "dec", size=12)
    d.box("w2", 760, 540, 380, 70, "L2 EVICT_WRITEBACK", "proc", sub="the 32 B line goes to L3 through the adapter\nas one posted half-line write", size=11)
    d.box("m3", 250, 645, 360, 70, "L2 ALLOC_FILL", "proc", sub="request the line from L3 through the adapter", size=11)
    d.box("d4", 250, 745, 360, 80, "L3 hit ?", "dec", sub="8 tag compares in parallel", size=12)
    d.box("h3", 760, 750, 380, 70, "L3 returns its 64 B line", "proc", sub="the adapter keeps the 32 B half\nselected by address bit 5", size=11)
    d.box("m4", 250, 855, 360, 70, "L3 TAG_CHECK", "proc", sub="victim: a free way first, else the PLRU choice", size=11)
    d.box("d5", 250, 955, 360, 80, "victim dirty ?", "dec", size=12)
    d.box("w3", 760, 960, 380, 70, "AXI4 write burst", "sub", sub="16 beats x 32 bit, wait for the B response\n(the memory sees the write before the read)", size=11)
    d.box("m5", 250, 1065, 360, 70, "AXI4 read burst", "proc", sub="16 beats x 32 bit INCR into the L3 line", size=11)
    d.box("m6", 250, 1165, 360, 60, "L3 UPDATE_TAG", "proc", sub="tag, valid, data; clean", size=11)
    d.box("m7", 250, 1255, 360, 80, "Fill returns up the hierarchy", "proc", sub="L2 UPDATE_TAG, then L1 UPDATE_TAG:\ntag, valid, data written at each level", size=11)
    d.box("e", 250, 1365, 360, 55, "Response to the CPU", "term", sub="the request is then re-presented as a hit", size=12)
    for a, b in [("s", "d1"), ("d1", "m1"), ("m1", "d2"), ("d2", "m2"), ("m2", "d3"), ("d3", "m3"), ("m3", "d4"), ("d4", "m4"), ("m4", "d5"), ("d5", "m5"), ("m5", "m6"), ("m6", "m7"), ("m7", "e")]:
        n = d.node(a)
        no = a in ("d1", "d2", "d4")
        d.arrow("e_" + a, a, b, kind="flow", sside="b", dside="t", label=("no" if no else ("no" if a == "d3" or a == "d5" else "")), lpos=(cx + 16, (n.y + n.h + d.node(b).y) / 2) if (no or a in ("d3", "d5")) else None)
    for dec, side in (("d1", "h1"), ("d2", "h2"), ("d4", "h3")):
        n = d.node(dec)
        d.arrow("y_" + dec, dec, side, kind="flow", sside="r", dside="l", label="yes", lpos=((n.x + n.w + d.node(side).x) / 2 + 0, n.y + n.h / 2 - 12))
    d.arrow("y_d3", "d3", "w2", kind="flow", sside="r", dside="l", label="yes", lpos=(685, 572))
    d.arrow("y_d5", "d5", "w3", kind="flow", sside="r", dside="l", label="yes", lpos=(685, 992))
    d.arrow("j_w2", "w2", "m3", kind="flow", sside="b", dside="r", sf=0.5, df=0.5, via=[(950, 680)])
    d.arrow("j_w3", "w3", "m5", kind="flow", sside="b", dside="r", sf=0.5, df=0.5, via=[(950, 1100)])
    # hits that return data go to the fill-return node
    d.arrow("r_h3", "h3", "m7", kind="flow", sside="r", dside="r", sf=0.5, df=0.5, via=[(1190, 785), (1190, 1295)][:0] or [(1180, 785), (1180, 1295)])
    d.arrow("r_h2", "h2", "m7", kind="flow", sside="r", dside="r", sf=0.5, df=0.2, via=[(1215, 365), (1215, 1271)])
    d.text("n", 250, 1445, "Not drawn: a store that misses L1 is allocated (fill, merge), then forwarded to L2 as a write-through; writes to L2 and L3 are posted\n(no response); the L1 controller has a one-entry skid that holds a write forward if L2 is not ready. A hit completes in the cycle it is\naccepted at every level, so the CPU must not derive resp_ready from resp_valid.", 11, italic=True)
    return d


def fsm():
    d = Diagram("mlc_cache_controller - controller state machines", 1320, 820)
    d.legend = ("flow",)
    d.legend_pos = (1120, 8)
    d.group("g1", 20, 50, 560, 680, "L1 (write-through, direct mapped): 3 states, TAG_CHECK is combinational", label_pos="bottom")
    d.box("i1", 60, 100, 200, 80, "IDLE", "fsm", sub="req_ready = 1 (no pending forward)", size=13)
    d.box("a1", 60, 300, 200, 80, "ALLOC_FILL", "fsm", sub="req_ready = 0; the fill request is\nheld until the response arrives", size=12)
    d.box("u1", 60, 500, 200, 80, "UPDATE_TAG", "fsm", sub="commit tag, valid, data;\nresponse waits for resp_ready", size=12)
    d.arrow("t1", "i1", "a1", kind="flow", sside="b", dside="t", sf=0.3, df=0.3, label="request misses", lpos=(150, 240))
    d.arrow("t2", "a1", "u1", kind="flow", sside="b", dside="t", sf=0.3, df=0.3, label="L2 response valid", lpos=(150, 440))
    d.arrow("t3", "u1", "i1", kind="flow", sside="r", dside="r", sf=0.5, df=0.5, via=[(340, 540), (340, 140)], label="resp_ready: the original\nrequest now hits", lpos=(340, 340))
    d.arrow("t4", "i1", "i1", kind="flow", sside="t", dside="t", sf=0.25, df=0.75, via=[(110, 78), (210, 78)], label="hit: same-cycle response", lpos=(160, 66))
    d.text("f1", 40, 625, "No EVICT state exists: write-through lines are never dirty, so a line is simply overwritten.\nA store hit updates the L1 array and is forwarded to L2 (a one-entry skid holds the\nforward if L2 is not ready); a store miss is allocated, merged and then forwarded.", 11, italic=True)
    d.group("g2", 620, 50, 680, 680, "L2 and L3 (write-back, set associative): the same controller, 5 states", label_pos="bottom")
    d.box("i2", 680, 100, 200, 70, "IDLE", "fsm", sub="req_ready = 1", size=13)
    d.box("t2b", 1000, 100, 230, 70, "TAG_CHECK", "fsm", sub="victim: free way, else PLRU", size=13)
    d.box("e2", 1000, 270, 230, 70, "EVICT_WRITEBACK", "fsm", sub="dirty victim goes downstream", size=12)
    d.box("f2", 1000, 420, 230, 70, "ALLOC_FILL", "fsm", sub="request the line downstream", size=13)
    d.box("u2", 680, 420, 200, 70, "UPDATE_TAG", "fsm", sub="tag, data, dirty (= store), PLRU", size=12)
    d.arrow("s1", "i2", "t2b", kind="flow", sside="r", dside="l", label="miss", lpos=(940, 112))
    d.arrow("s2", "t2b", "e2", kind="flow", sside="b", dside="t", label="victim valid\nand dirty", lpos=(1115, 215))
    d.arrow("s3", "t2b", "f2", kind="flow", sside="r", dside="r", sf=0.5, df=0.3, via=[(1270, 135), (1270, 441)], label="clean", lpos=(1270, 290))
    d.arrow("s4", "e2", "f2", kind="flow", sside="b", dside="t", label="write-back accepted", lpos=(1115, 385))
    d.arrow("s5", "f2", "u2", kind="flow", sside="l", dside="r", label="fill response", lpos=(940, 432))
    d.arrow("s6", "u2", "i2", kind="flow", sside="t", dside="b", label="done (a read waits for resp_ready)", lpos=(780, 300))
    d.arrow("s7", "i2", "i2", kind="flow", sside="t", dside="t", sf=0.2, df=0.8, via=[(720, 78), (840, 78)], label="hit (any way): same-cycle\nread response, PLRU update", lpos=(780, 66))
    d.text("f2t", 640, 520, "Writes are posted: a store hit or a write-allocated miss returns to IDLE without a response.\nL2 and L3 differ only in parameters (ways, line size, write width) and in what sits downstream:\nthe adapter for L2, the AXI4 fill engine for L3. A free (invalid) way is always used before\nthe PLRU choice evicts a live line. Misses are blocking: one outstanding miss per level.", 11, italic=True)
    return d


if __name__ == "__main__":
    for n, f in (("mlc_architecture", architecture), ("mlc_flowchart", flowchart), ("mlc_fsm", fsm)):
        print(n, "overflow:", f().export_all(HERE, n))
