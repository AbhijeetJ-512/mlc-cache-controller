#!/usr/bin/env python3
"""compare.py vec out - compare the RTL's per-cycle outputs with the explorer model's prediction (fields 12..43 of each vec line)."""
import sys
NAMES="i_req_ready i_resp_valid i_resp_rdata d_req_ready d_resp_valid d_resp_rdata awvalid awaddr wvalid wdata wlast bready arvalid araddr rready mem_err arready awready wready bvalid rvalid rdata rlast rresp st_l1i st_l1d st_l2 st_l3 st_eng arb_busy arb_owner arb_last".split()
vec=[l.split() for l in open(sys.argv[1]).read().splitlines()[1:] if l.strip()]
out=[l.split() for l in open(sys.argv[2]).read().splitlines() if l.strip()]
n=len(out); bad=0; fields=0
if n!=len(vec): print("length mismatch: vec %d, out %d"%(len(vec),n)); bad+=1
for c,(v,o) in enumerate(zip(vec,out),1):
    exp=v[12:44]
    for name,e,g in zip(NAMES,exp,o):
        fields+=1
        try: same=int(e,16)==int(g,16)
        except ValueError: same=False
        if not same:
            bad+=1
            if bad<=8: print("cycle %d %s: model %s, RTL %s"%(c,name,e,g))
print("%d cycles, %d fields compared, %d mismatches"%(n,fields,bad)); sys.exit(1 if bad else 0)
