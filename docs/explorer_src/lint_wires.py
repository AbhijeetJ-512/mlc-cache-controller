#!/usr/bin/env python3
"""lint_wires.py spec.py - report wires that pass through a block they do not start or end at, and text that does not fit its block."""
import importlib.util, sys
spec=importlib.util.spec_from_file_location("s",sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
boxes={k:(v['x'],v['y'],v['x']+v['w'],v['y']+v['h']) for k,v in m.NODES.items()}
for k,b in m.BARS.items():
    y=b.get('y',m.VIEW.get('barY',0)); h=b.get('h',m.VIEW.get('barH',0)); boxes[k]=(b['x'],y,b['x']+18,y+h)
bad=0
for e in m.EDGES:
    pts=e['pts']
    for a,b in zip(pts,pts[1:]):
        x0,x1=sorted((a[0],b[0])); y0,y1=sorted((a[1],b[1]))
        for k,(bx0,by0,bx1,by1) in boxes.items():
            if k in (e['from'],e['to']): continue
            if x1>bx0+1 and x0<bx1-1 and y1>by0+1 and y0<by1-1:
                print("%s (%s) crosses block %s"%(e['id'],e['label'],k)); bad+=1
    # endpoints should touch their own blocks
    for end,k in ((pts[0],e['from']),(pts[-1],e['to'])):
        bx0,by0,bx1,by1=boxes[k]
        if not (bx0-3<=end[0]<=bx1+3 and by0-3<=end[1]<=by1+3): print("%s endpoint %s is not on block %s"%(e['id'],end,k)); bad+=1
for k,n in m.NODES.items():
    lines=[n['t'],n['s']]+n['l']; 
    width=max(len(n['t'])*8.2,len(n['s'])*6.4,*(len(x)*5.9 for x in n['l']),0)+20
    need=19+15+14*len(n['l'])+6
    if width>n['w']: print("block %s text may overflow width (%d > %d)"%(k,width,n['w'])); bad+=1
    if need>n['h']: print("block %s text may overflow height (%d > %d)"%(k,need,n['h'])); bad+=1
print("lint: %d issue(s)"%bad)
