// Cycle model of mlc_cache_top (default sizes) + sim/axi_mem_model.sv. Each unit mirrors its RTL always_comb / always_ff:
//   l1a/l1c  = l1_cache_ctrl           wbEval/wbCommit = l2_cache_ctrl (L2 and, with other parameters, L3)
//   arbiter  = l1_l2_arbiter           adapter         = l2_l3_width_adapter (wiring)
//   engEval/engCommit = axi4_fill_engine     memOut/memCommit = axi_mem_model (aw_mode 0)
// eval(M) computes every combinational signal of one cycle from the registers; commit(M,R) is the clock edge.
const hx=(v,n=8)=>'0x'+(v>>>0).toString(16).padStart(n,'0');
const hs=v=>'0x'+(v>>>0).toString(16);
const memWord=k=>(0xC0DE0000+k)>>>0;                 // axi_mem_model: mem32(i) = 32'hC0DE_0000 + i
const MEMW=131072;
const Z=n=>new Array(n).fill(0);
function mergeBytes(line,base,wd,wstrb,nb){ const o=line.slice(); for(let b=0;b<nb;b++){ if((wstrb>>>b)&1){ const wi=base+(b>>2), sh=(b&3)*8; const src=(wd[b>>2]>>>sh)&0xff; o[wi]=(((o[wi]&~(0xff<<sh))|(src<<sh))>>>0); } } return o; }
// ---- L1 (l1_cache_ctrl): 4 KiB, 128 sets x 32 B, direct-mapped, write-through
function mkL1(){ return {state:0,valid:new Map(),tag:new Map(),data:new Map(),fwd:0,fwA:0,fwD:0,fwS:0,mA:0,mI:0,mT:0,mW:0,mIsW:0,mD:0,mS:0}; }
const l1line=(L,i)=>L.data.get(i)||Z(8);
function l1a(L,i){
  const idx=(i.ra>>>5)&127, tag=i.ra>>>12, ws=(i.ra>>>2)&7;
  const hit=!!L.valid.get(idx)&&L.tag.get(idx)===tag;
  const rdy=L.state===0&&!L.fwd&&(!i.rv||!hit||i.rr);
  const respv=L.state===2||(L.state===0&&i.rv&&rdy&&hit);
  const rdata=L.state===2?l1line(L,L.mI)[L.mW]:l1line(L,idx)[ws];
  let dv=0,da=0,dwe=0,dwd=0,dws=0;
  if(L.fwd){dv=1;da=L.fwA;dwe=1;dwd=L.fwD;dws=L.fwS;}
  else if(L.state===0&&i.rv&&rdy&&i.rwe&&hit){dv=1;da=i.ra;dwe=1;dwd=i.rd;dws=i.rs;}
  else if(L.state===1){dv=1;da=L.mA;dwe=0;}
  return {idx,tag,ws,hit,rdy,respv,rdata:respv?rdata>>>0:0,dnr:L.state===1,dv,da,dwe,dwd,dws,acc:L.state===0&&i.rv&&rdy};
}
function l1c(L,i,o,dn){
  if(L.fwd){ if(dn.rdy) L.fwd=0; }
  else if(L.state===0&&i.rv&&o.rdy&&i.rwe&&o.hit&&!dn.rdy){ L.fwd=1;L.fwA=i.ra;L.fwD=i.rd;L.fwS=i.rs; }
  switch(L.state){
    case 0: if(i.rv&&o.rdy){ if(o.hit){ if(i.rwe) L.data.set(o.idx,mergeBytes(l1line(L,o.idx),o.ws,[i.rd],i.rs,4)); }
            else { L.mA=i.ra;L.mI=o.idx;L.mT=o.tag;L.mW=o.ws;L.mIsW=i.rwe;L.mD=i.rd;L.mS=i.rs;L.state=1; } } break;
    case 1: if(dn.rv){ let ln=dn.line.slice(); if(L.mIsW) ln=mergeBytes(ln,L.mW,[L.mD],L.mS,4);
            L.tag.set(L.mI,L.mT);L.valid.set(L.mI,1);L.data.set(L.mI,ln);
            if(L.mIsW){L.fwd=1;L.fwA=L.mA;L.fwD=L.mD;L.fwS=L.mS;} L.state=2; } break;
    case 2: if(i.rr) L.state=0; break;
  }
}
// ---- L2 / L3 (l2_cache_ctrl): write-back, set-associative, tree PLRU
const P2={sets:256,ways:4,lb:32,lw:8,off:5,ib:8,wrB:4,wrw:1,wro:2,slots:8,lv:2,name:'L2'};
const P3={sets:512,ways:8,lb:64,lw:16,off:6,ib:9,wrB:32,wrw:8,wro:5,slots:2,lv:3,name:'L3'};
function mkWB(p){ return {p,state:0,valid:new Map(),tag:new Map(),dirty:new Map(),data:new Map(),plru:new Map(),mA:0,mI:0,mT:0,mS:0,mIsW:0,mD:[0],mWs:0,vWl:0,vT:0,vL:Z(p.lw)}; }
function plruVictim(W,s){ const st=W.plru.get(s)||0; let node=0,way=0; for(let l=0;l<W.p.lv;l++){ const b=(st>>node)&1; way=way*2+b; node=b?2*node+2:2*node+1; } return way; }
function plruNext(W,s,way){ let st=W.plru.get(s)||0,node=0; for(let l=0;l<W.p.lv;l++){ const dir=(way>>(W.p.lv-1-l))&1; st=dir?(st&~(1<<node)):(st|(1<<node)); node=dir?2*node+2:2*node+1; } W.plru.set(s,st); }
function victimWay(W,mI){ let all=true,low=-1; for(let w=0;w<W.p.ways;w++){ if(!W.valid.get(mI*W.p.ways+w)){ all=false; if(low<0) low=w; } } return all?plruVictim(W,mI):low; }
function wbEval(W,i){
  const p=W.p, idx=(i.ra>>>p.off)&(p.sets-1), tag=i.ra>>>(p.off+p.ib), slot=(i.ra>>>p.wro)&(p.slots-1);
  let hit=false,hw=0; for(let w=0;w<p.ways;w++){ const k=idx*p.ways+w; if(W.valid.get(k)&&W.tag.get(k)===tag){hit=true;hw=w;} }
  const hline=W.data.get(idx*p.ways+hw)||Z(p.lw);
  const rdy=W.state===0&&(!i.rv||!hit||i.rwe||i.rr);
  const hitAcc=W.state===0&&i.rv&&rdy&&hit;
  const respv=(W.state===4&&!W.mIsW)||(hitAcc&&!i.rwe);
  const rl=W.state===4?(W.data.get(W.mI*p.ways+W.vWl)||Z(p.lw)):hline;
  let dv=0,da=0,dwe=0,dl=Z(p.lw);
  if(W.state===2){dv=1;da=(((W.vT<<p.ib)|W.mI)<<p.off)>>>0;dwe=1;dl=W.vL;}
  else if(W.state===3){dv=1;da=W.mA;dwe=0;}
  return {idx,tag,slot,hit,hw,hline,rdy,hitAcc,respv,rl:respv?rl:Z(p.lw),dnr:W.state===3,dv,da,dwe,dl};
}
function wbCommit(W,i,o,dn){
  const p=W.p, st=W.state, commitFill=st===3&&dn.rv, commitWH=o.hitAcc&&i.rwe;
  if(o.hitAcc||commitFill) plruNext(W,commitFill?W.mI:o.idx,commitFill?W.vWl:o.hw);
  if(commitWH){ const k=o.idx*p.ways+o.hw; W.data.set(k,mergeBytes(o.hline,o.slot*p.wrw,i.rdw,i.rs,p.wrB)); W.dirty.set(k,1); }
  if(st===1){ const vw=victimWay(W,W.mI), k=W.mI*p.ways+vw; W.vWl=vw; W.vT=W.tag.get(k)||0; W.vL=(W.data.get(k)||Z(p.lw)).slice(); }
  if(commitFill){ const k=W.mI*p.ways+W.vWl; let ln=dn.line.slice(); if(W.mIsW) ln=mergeBytes(ln,W.mS*p.wrw,W.mD,W.mWs,p.wrB);
    W.tag.set(k,W.mT); W.data.set(k,ln); W.dirty.set(k,W.mIsW?1:0); W.valid.set(k,1); }
  switch(st){
    case 0: if(i.rv&&o.rdy&&!o.hit){ W.mA=((i.ra>>>p.off)<<p.off)>>>0; W.mI=o.idx; W.mT=o.tag; W.mS=o.slot; W.mIsW=i.rwe; W.mD=i.rdw.slice(); W.mWs=i.rs; W.state=1; } break;
    case 1: { const vw=victimWay(W,W.mI), k=W.mI*p.ways+vw; W.state=(W.valid.get(k)&&W.dirty.get(k))?2:3; } break;
    case 2: if(dn.rdy) W.state=3; break;
    case 3: if(dn.rv) W.state=4; break;
    case 4: if(W.mIsW||i.rr) W.state=0; break;
  }
}
// ---- AXI4 fill engine
function mkEng(){ return {st:0,addr:0,line:Z(16),beat:0,awd:0,wd:0,err:0}; }
function engOut(E){ const lb=E.beat===15; return {rdy:E.st===0,arv:E.st===1,rrdy:E.st===2,awv:E.st===4&&!E.awd,wv:E.st===4&&!E.wd,wdata:E.line[E.beat]>>>0,wlast:(E.st===4&&!E.wd&&lb)?1:0,bready:E.st===5,respv:E.st===3,rl:E.line,addr:E.addr}; }
function engCommit(E,rq,m,o){
  const a0=E.awd,w0=E.wd;
  switch(E.st){
    case 0: if(rq.rv){ E.addr=rq.ra; E.beat=0; E.awd=0; E.wd=0; if(rq.rwe){ E.line=rq.rl.slice(); E.st=4; } else E.st=1; } break;
    case 1: if(m.arready) E.st=2; break;
    case 2: if(m.rvalid){ E.line=E.line.slice(); E.line[E.beat]=m.rdata; if(m.rresp&2) E.err=1; if(m.rlast!==(E.beat===15?1:0)) E.err=1; if(E.beat===15) E.st=3; else E.beat++; } break;
    case 3: if(rq.rr) E.st=0; break;
    case 4: if(o.awv&&m.awready) E.awd=1; if(o.wv&&m.wready){ if(E.beat===15) E.wd=1; else E.beat++; } if(a0&&w0) E.st=5; break;
    case 5: if(m.bvalid){ if(m.bresp&2) E.err=1; E.st=0; } break;
  }
}
// ---- AXI4 memory model (axi_mem_model.sv, aw_mode 0, rlast_mode 0)
function mkMem(c){ return {c,rs:0,ra:0,rl:0,rb:0,rg:0,ws:0,wa:0,wl:0,wb:0,bc:0,m:new Map(),nr:0,nw:0,wrote:[]}; }
const mword=(Mm,byteAddr)=>{ const k=(byteAddr>>>2)%MEMW; return Mm.m.has(k)?Mm.m.get(k):memWord(k); };
function memOut(Mm,st){ const c=Mm.c;
  return {arready:Mm.rs===0&&!st.ar,rvalid:Mm.rs===1&&Mm.rg===0,rdata:mword(Mm,(Mm.ra+Mm.rb*4)>>>0),rresp:(c.rerr>=0&&Mm.rb===c.rerr)?2:c.frr,rlast:Mm.rb===Mm.rl?1:0,
    awready:Mm.ws===0&&!st.aw,wready:Mm.ws===1&&!st.w,bvalid:Mm.ws===2&&Mm.bc===0,bresp:c.fbr}; }
function memCommit(Mm,e,m){ const c=Mm.c;
  if(Mm.rs===0){ if(e.arv&&m.arready){ Mm.ra=e.addr; Mm.rl=15; Mm.rb=0; Mm.rg=c.first?c.gap:0; Mm.rs=1; Mm.nr++; } }
  else { if(Mm.rg!==0) Mm.rg--; else if(e.rrdy){ if(Mm.rb===Mm.rl) Mm.rs=0; else { Mm.rb++; Mm.rg=c.gap; } } }
  if(Mm.ws===0){ if(e.awv&&m.awready){ Mm.wa=e.addr; Mm.wl=15; Mm.wb=0; Mm.ws=1; Mm.nw++; } }
  else if(Mm.ws===1){ if(e.wv&&m.wready){ const k=((Mm.wa+Mm.wb*4)>>>2)%MEMW; Mm.m.set(k,e.wdata>>>0); if(e.wlast||Mm.wb===Mm.wl){ Mm.ws=2; Mm.bc=c.bdel; Mm.wrote.push(Mm.wa); } else Mm.wb++; } }
  else if(Mm.ws===2){ if(Mm.bc!==0) Mm.bc--; else if(e.bready) Mm.ws=0; }
}
// ---- CPU port driver (valid held until accepted; d = cycles to wait before raising)
function mkCpu(ops){ const x={q:ops.map((o,i)=>({...o,pi:i})),sig:0,cur:null,cnt:-1}; armc(x); return x; }
function armc(x){ if(!x.q.length){x.sig=0;x.cur=null;x.cnt=-1;return;} x.cur=x.q.shift(); x.cnt=x.cur.d||0; x.sig=x.cnt===0?1:0; }
function cpuEdge(x,acc){ if(x.sig&&acc){ x.sig=0; armc(x); } else if(x.cnt>0){ x.cnt--; if(x.cnt===0) x.sig=1; } }
const inWin=(w,c)=>(w||[]).some(([a,b])=>c>=a&&c<b);

const A=(base,n)=>Array.from({length:n},(_,i)=>base+4*i);
const SC=[
 {id:'fetch',name:'Fetch: miss, hits, L3 half',desc:'Cold instruction fetch: a miss through L1, L2 and L3 fills one 64 B line over AXI4, then seven back-to-back hits. The next 32 B (address 0x60020) misses L1 and L2 but hits L3: no memory traffic.',
  i:[0x60000,...A(0x60004,7),0x60020,0x60024,0x60000].map(a=>({a})),d:[],mem:{gap:0,first:0,bdel:0,rerr:-1,frr:0,fbr:0}},
 {id:'loadstore',name:'Loads and stores',desc:'A load miss, a store hit (write-through to L2, dirty there), a load of the stored word, then a store to a cold line (L1 fills, merges the store, forwards it from the skid register).',
  i:[],d:[{k:'L',a:0x1000},{k:'S',a:0x1004,v:0xA5A5A5A5,s:15},{k:'L',a:0x1004},{k:'S',a:0x2008,v:0x0000BEEF,s:3},{k:'L',a:0x2008}],mem:{gap:0,first:0,bdel:0,rerr:-1,frr:0,fbr:0}},
 {id:'both',name:'Instruction and data together',desc:'L1-I and L1-D both miss in the same cycle. The arbiter picks L1-I first after reset, marks itself busy until that read is answered, then serves L1-D.',
  i:[{a:0x60000},{a:0x60004}],d:[{k:'L',a:0x0},{k:'L',a:0x4}],mem:{gap:0,first:0,bdel:0,rerr:-1,frr:0,fbr:0}},
 {id:'conflict',name:'L1 conflict, L2 hit',desc:'Two lines that map to the same direct-mapped L1 set: the second replaces the first (no write-back, L1 is write-through). Loading the first again misses L1 but hits L2, which is much faster than the cold miss.',
  i:[],d:[{k:'L',a:0x0},{k:'L',a:0x1000},{k:'L',a:0x0}],mem:{gap:0,first:0,bdel:0,rerr:-1,frr:0,fbr:0}},
 {id:'evl2',name:'L2 eviction of a dirty line',desc:'Five stores to lines that share one L2 set (4 ways). The fifth store finds the set full of dirty lines: L2 writes the PLRU victim back to L3 through the adapter before it fills. The final load of the first line is then served from L3 with the written-back data.',
  i:[],d:[0,1,2,3,4].map(k=>({k:'S',a:k*0x2000,v:0x11110000+k,s:15})).concat([{k:'L',a:0x0}]),mem:{gap:0,first:0,bdel:0,rerr:-1,frr:0,fbr:0}},
 {id:'evl3',name:'L3 eviction to memory (long)',desc:'Nine stores to lines that share one L3 set (8 ways) and one L2 set. L2 write-backs make L3 lines dirty; when the ninth line misses in a full L3 set, a dirty victim is written to memory as one AXI4 write burst. This scenario is long; use a higher speed.',
  i:[],d:[0,1,2,3,4,5,6,7,8].map(k=>({k:'S',a:k*0x8000,v:0x22220000+k,s:15})),mem:{gap:0,first:0,bdel:0,rerr:-1,frr:0,fbr:0}},
 {id:'slow',name:'Slow memory',desc:'AR stalled for several cycles, a gap before and between R beats, and a delayed write response. Nothing above the engine changes; the L1 request just stays held.',
  i:[],d:[{k:'L',a:0x3000},{k:'S',a:0x3004,v:0xCAFE0001,s:15},{k:'L',a:0x3004}],mem:{gap:2,first:1,bdel:3,rerr:-1,frr:0,fbr:0,stall:{ar:[[6,12]],aw:[],w:[]}}},
 {id:'memerr',name:'AXI4 error response',desc:'The memory answers beat 5 of a read burst with SLVERR. The engine sets the sticky mem_err, still collects the line and answers, so the load completes with correct data.',
  i:[],d:[{k:'L',a:0x4000},{k:'L',a:0x4020}],mem:{gap:0,first:0,bdel:0,rerr:5,frr:0,fbr:0}},
 {id:'cpubp',name:'CPU back-pressure',desc:'The CPU holds d_resp_ready low for a while. The L1 waits in UPDATE_TAG with the response and the data held, and the following hits wait because a hit is only accepted when the CPU can take its answer.',
  i:[],d:[{k:'L',a:0x5000},{k:'L',a:0x5004},{k:'L',a:0x5008}],drdy:[[20,50]],mem:{gap:0,first:0,bdel:0,rerr:-1,frr:0,fbr:0}},
];
function ref(M,a){ const k=(a>>>2)%MEMW; return M.ref.has(k)?M.ref.get(k):memWord(k); }
const SIM={
  scenarios:SC.map(s=>({id:s.id,name:s.name,desc:s.desc})),options:[],
  chartTitle:'Request timeline',rowLabel:'request',chartWindow:70,maxCycles:900,preroll:3,
  chartHint:'one row per CPU request · M miss accepted, H hit, L1/L2/L3/AR/R/WR/B = where the fill is being served · hatched = waiting',
  reset(id){
    const s=SC.find(x=>x.id===id)||SC[0], c=s.mem;
    return {sc:s,l1i:mkL1(),l1d:mkL1(),arb:{busy:0,owner:0,last:1},l2:mkWB(P2),l3:mkWB(P3),eng:mkEng(),mem:mkMem(c),
      ci:mkCpu(s.i.map(o=>({...o,k:'F'}))),cd:mkCpu(s.d),pend:{I:[],D:[]},tx:{I:null,D:null},ref:new Map(),txns:[],
      plan:[...s.i.map((o,i)=>({p:'I',k:'F',a:o.a,tx:null})),...s.d.map((o,i)=>({p:'D',k:o.k,a:o.a,v:o.v,tx:null}))],
      n:{done:0,hit:0,miss:0},prev:{l2:0,l3:0}};
  },
  eval(M){
    const cyc=M.cyc, sc=M.sc, ev=[], act=new Set(), AD=(...x)=>x.forEach(i=>act.add(i));
    const ci={rv:M.ci.sig,ra:M.ci.cur?M.ci.cur.a:0,rwe:0,rd:0,rs:0,rr:inWin(sc.irdy,cyc)?0:1};
    const cu=M.cd.cur, cd={rv:M.cd.sig,ra:cu?cu.a:0,rwe:cu&&cu.k==='S'?1:0,rd:cu&&cu.k==='S'?cu.v>>>0:0,rs:cu&&cu.k==='S'?cu.s:0,rr:inWin(sc.drdy,cyc)?0:1};
    const o1=l1a(M.l1i,ci), o2=l1a(M.l1d,cd);
    // arbiter
    const Ar=M.arb, u0={rv:o1.dv,ra:o1.da,we:o1.dwe,wd:o1.dwd,ws:o1.dws}, u1={rv:o2.dv,ra:o2.da,we:o2.dwe,wd:o2.dwd,ws:o2.dws};
    const sel=(u0.rv&&u1.rv)?(Ar.last?0:1):(u1.rv?1:0), sv=sel?u1.rv:u0.rv, us=sel?u1:u0;
    const l2v=sv&&!Ar.busy, respTo=Ar.busy?Ar.owner:sel, l2rr=respTo?o2.dnr:o1.dnr;
    const i2={rv:l2v,ra:us.ra,rwe:us.we,rdw:[us.wd>>>0],rs:us.ws,rr:l2rr};
    const o3=wbEval(M.l2,i2);
    const u0rdy=!sel&&!Ar.busy&&o3.rdy, u1rdy=sel&&!Ar.busy&&o3.rdy, u0rv=o3.respv&&!respTo, u1rv=o3.respv&&respTo, accept=l2v&&o3.rdy;
    // adapter (wiring) and L3
    const half=(o3.da>>>5)&1;
    const i3={rv:o3.dv,ra:o3.da,rwe:o3.dwe,rdw:o3.dl,rs:0xFFFFFFFF,rr:o3.dnr};
    const o4=wbEval(M.l3,i3);
    const l2line=half?o4.rl.slice(8,16):o4.rl.slice(0,8);
    // engine and memory
    const oe=engOut(M.eng);
    const st={ar:inWin(sc.mem.stall&&sc.mem.stall.ar,cyc),aw:inWin(sc.mem.stall&&sc.mem.stall.aw,cyc),w:inWin(sc.mem.stall&&sc.mem.stall.w,cyc)};
    const om=memOut(M.mem,st);
    // ----- bookkeeping: CPU responses, transactions
    const portInfo=[['I',M.l1i,o1,ci,u0rdy,u0rv],['D',M.l1d,o2,cd,u1rdy,u1rv]];
    const deepT=()=>{ const E=M.eng,W3=M.l3,W2=M.l2;
      if(E.st!==0){ const nm=['','AR','R','RS','WR','B'][E.st]; const wait=(E.st===1&&!om.arready)||(E.st===2&&!om.rvalid)||(E.st===5&&!om.bvalid)||(E.st===3&&!o4.dnr)||(E.st===4&&(!om.awready&&!E.awd)); return {t:nm,col:'--b4',cls:wait?'st':'',txt:['','AXI4: AR presented'+(om.arready?'':', waiting for ARREADY'),'AXI4: collecting R beats (beat '+(E.beat+1)+'/16)'+(om.rvalid?'':', waiting for RVALID'),'engine answers L3 with the line','AXI4: write burst (AW + 16 W beats)','AXI4: waiting for the B response'][E.st]}; }
      if(W3.state!==0){ const nm=['','L3t','L3e','L3f','L3u'][W3.state]; return {t:nm,col:'--b3',cls:(W3.state===2&&!oe.rdy)||(W3.state===3)&&!oe.respv?'st':'',txt:['','L3: TAG_CHECK (victim choice)','L3: EVICT_WRITEBACK of a dirty 64 B line','L3: ALLOC_FILL, waiting for the line from memory','L3: UPDATE_TAG'][W3.state]}; }
      if(W2.state!==0){ const nm=['','L2t','L2e','L2f','L2u'][W2.state]; return {t:nm,col:'--b2',cls:(W2.state===3&&!o4.respv)||(W2.state===2&&!o4.rdy)?'st':'',txt:['','L2: TAG_CHECK (victim choice)','L2: EVICT_WRITEBACK of a dirty line to L3','L2: ALLOC_FILL, waiting for the line from L3','L2: UPDATE_TAG'][W2.state]}; }
      return {t:'L1',col:'--b1',cls:'',txt:'L1 waits: its fill read is being passed down'}; };
    const note=(tx,col,t,txt)=>{ const last=tx.notes[tx.notes.length-1]; if(!last||last.txt!==txt) tx.notes.push({c:cyc,t,col,txt}); };
    for(const [P,L,o,ci_,urdy,urv] of portInfo){
      const cpu=P==='I'?M.ci:M.cd, q=M.pend[P];
      if(o.acc){ const op=cpu.cur, pl=M.plan.find(x=>x.p===P&&!x.tx&&x.a===op.a&&x.k===op.k);
        const label=(P==='I'?'I fetch ':'D '+(op.k==='S'?'store ':'load '))+hs(op.a)+(op.k==='S'?' ← '+hx(op.v):'');
        const t={id:M.txns.length,label,color:'var(--t'+(M.txns.length%8)+')',cells:{},notes:[],status:'in flight',port:P,op};
        M.txns.push(t); if(pl) pl.tx=t.id;
        let expect=null; if(op.k==='S'){ const k=(op.a>>>2)%MEMW; M.ref.set(k,mergeBytes([ref(M,op.a)],0,[op.v>>>0],op.s,4)[0]); } else expect=ref(M,op.a);
        q.push({t,expect,op}); M.tx[P]=t;
        if(o.hit){ M.n.hit++; t.cells[cyc]={t:'H',col:'--b1',title:'hit, answered in the accept cycle'}; note(t,'--b1','H',(op.k==='S'?'store':'load')+' hit in L1, answered in its accept cycle'+(op.k==='S'?'; forwarded to L2 as a write':'')); ev.push(['ret',`${P==='I'?'L1-I':'L1-D'} ${op.k==='S'?'store':op.k==='F'?'fetch':'load'} hit ${hs(op.a)}`]); }
        else { M.n.miss++; t.cells[cyc]={t:'M',col:'--b1',title:'miss accepted'}; note(t,'--b1','M','miss: request latched, fill read raised, L1 enters ALLOC_FILL'); ev.push(['ctl',`${P==='I'?'L1-I':'L1-D'} ${op.k==='S'?'store':op.k==='F'?'fetch':'load'} miss ${hs(op.a)} → ALLOC_FILL`]); }
      } else if(L.state===1&&M.tx[P]){ const t=M.tx[P]; const queued=M.arb.busy&&M.arb.owner!==(P==='I'?0:1);
        const d=queued?{t:'q',col:'--b1',cls:'st',txt:'queued: the other L1 owns the L2 port'}:deepT();
        t.cells[cyc]={t:d.t,col:d.col,cls:d.cls,title:d.txt}; note(t,d.col,d.t,d.txt); }
      else if(L.state===2&&M.tx[P]){ const t=M.tx[P]; t.cells[cyc]={t:'U',col:'--b1',cls:ci_.rr?'':'st',title:'UPDATE_TAG'}; note(t,'--b1','U','UPDATE_TAG: line written, answering the CPU'+(ci_.rr?'':' (waiting for resp_ready)')); }
      if(o.respv&&ci_.rr){ const e=q.shift(); if(e){ const t=e.t; t.status='complete'; M.n.done++;
        let msg=`${P==='I'?'L1-I':'L1-D'} response ${hs(e.op.a)}`; if(e.op.k!=='S'){ const ok=(o.rdata>>>0)===(e.expect>>>0); msg+=` = ${hx(o.rdata)} ${ok?'(matches the reference)':'MISMATCH, expected '+hx(e.expect)}`; if(!ok) ev.push(['trap',msg]); else ev.push(['ret',msg]); t.status=ok?'complete, matches reference':'MISMATCH'; }
        else ev.push(['ret',msg+' (store acknowledged)']);
        if(L.state===2||o.hit) { note(t,'--b1','✓',e.op.k==='S'?'store acknowledged':'answered with '+hx(o.rdata)); }
        if(M.tx[P]===t&&q.length===0) M.tx[P]=null; } }
    }
    // ----- events for the lower levels
    if(i2.rv&&o3.rdy){ const w=sel?'L1-D':'L1-I'; if(i2.rwe) ev.push(['mem',`${w} store ${hs(i2.ra)} accepted by L2 (${o3.hit?'write hit, line dirty':'write miss: allocate'})`]); else ev.push(['ctl',`${w} read ${hs(i2.ra)} accepted by L2: ${o3.hit?'hit, answered at once':'miss, arbiter busy, owner '+w}`]); }
    for(const [W,nm,o] of [[M.l2,'L2',o3],[M.l3,'L3',o4]]){
      if(W.state===1){ const vw=victimWay(W,W.mI), k=W.mI*W.p.ways+vw, full=Array.from({length:W.p.ways},(_,w)=>W.valid.get(W.mI*W.p.ways+w)).every(Boolean);
        ev.push(['fwd',`${nm} TAG_CHECK set ${W.mI}: ${full?'set full, PLRU victim way '+vw:'free way '+vw}${W.valid.get(k)&&W.dirty.get(k)?', victim dirty → EVICT_WRITEBACK':W.valid.get(k)?', victim clean':''}`]); }
      if(W.state===2&&o.dv) ev.push(['fwd',`${nm} EVICT_WRITEBACK ${hs(o.da)} ${nm==='L2'?'(32 B line to L3, one half-line write)':'(64 B line to the AXI4 engine)'}`]);
      if(W.state===3&&(nm==='L2'?o4.respv:oe.respv)) ev.push(['data',`${nm} fill data arrived for ${hs(W.mA)}`]);
    }
    if(i3.rv&&o4.rdy){ if(i3.rwe) ev.push(['mem',`L3 accepts the L2 write-back ${hs(i3.ra)}: ${o4.hit?'write hit, half merged, dirty':'write miss: allocate'}`]); else if(o4.hit) ev.push(['data',`L3 hit ${hs(i3.ra)} (half ${half}): answered at once, no AXI4 traffic`]); }
    if(M.eng.st===0&&o4.dv){ ev.push(['mem',`AXI4 engine takes a ${o4.dwe?'write':'read'} of the 64 B line ${hs(o4.da)}`]); }
    if(oe.arv&&om.arready) ev.push(['mem',`AXI4 AR ${hs(oe.addr)}, 16 beats`]);
    if(M.eng.st===2&&om.rvalid&&(M.eng.beat===0||M.eng.beat===15)) ev.push(['mem',`AXI4 R beat ${M.eng.beat+1}/16${M.eng.beat===15?' (RLAST)':''}`]);
    if(oe.awv&&om.awready) ev.push(['mem',`AXI4 AW ${hs(oe.addr)}, 16 beats`]);
    if(oe.wv&&om.wready&&(M.eng.beat===0||M.eng.beat===15)) ev.push(['mem',`AXI4 W beat ${M.eng.beat+1}/16${oe.wlast?' (WLAST)':''}`]);
    if(M.eng.st===5&&om.bvalid) ev.push(['mem',`AXI4 B response ${om.bresp===2?'SLVERR':'OKAY'}: write burst done`]);
    if(M.eng.st===2&&om.rvalid&&((om.rresp&2)||om.rlast!==(M.eng.beat===15?1:0))) ev.push(['trap',`mem_err ← 1: ${om.rresp&2?'SLVERR on read beat '+(M.eng.beat+1):'RLAST mismatch'}`]);
    if(M.eng.st===5&&om.bvalid&&(om.bresp&2)) ev.push(['trap','mem_err ← 1: SLVERR on the write response']);
    if(Ar.busy&&o3.respv&&l2rr) ev.push(['ctl',`arbiter: response to ${Ar.owner?'L1-D':'L1-I'}, busy clears`]);
    if(M.l1d.fwd) ev.push(['ctl','L1-D skid register drives the pending store downstream']);
    // ----- active wires
    if(ci.rv) AD('E01'); if(o1.respv||ci.rv) AD('E02'); if(cd.rv) AD('E03'); if(o2.respv||cd.rv) AD('E04');
    if(o1.respv&&ci.rr) AD('E05'); if(o2.respv&&cd.rr&&cu&&cu.k!=='S') AD('E06');
    if(o1.dv||o1.dnr) AD('E07'); if(u0rv||(o1.dv&&u0rdy)) AD('E08'); if(o2.dv||o2.dnr) AD('E09'); if(u1rv||(o2.dv&&u1rdy)) AD('E10');
    if(M.l1d.fwd) AD('E11'); if((M.l1d.state===0&&cd.rv&&o2.rdy&&cd.rwe&&o2.hit&&!u1rdy)||(M.l1d.state===1&&M.l1d.mIsW&&u1rv)) AD('E12');
    if(l2v) AD('E13'); if((l2v&&o3.rdy)||o3.respv) AD('E14');
    if(u1rv) AD('E15'); if(u0rv) AD('E16');
    if(o3.hitAcc||(M.l2.state===3&&o4.respv)) AD('E17'); if(M.l2.state===1) AD('E18');
    if(o3.dv) AD('E19'); if(o4.respv||(o3.dv&&o4.rdy)) AD('E20');
    if(i3.rv) AD('E21'); if(o4.respv||(i3.rv&&o4.rdy)) AD('E22');
    if(o4.hitAcc||(M.l3.state===3&&oe.respv)) AD('E23'); if(M.l3.state===1) AD('E24');
    if(o4.dv||o4.dnr) AD('E25'); if(oe.respv||(o4.dv&&oe.rdy)) AD('E26');
    if(oe.arv||oe.awv||oe.wv||oe.bready||oe.rrdy) AD('E27'); if((oe.arv&&om.arready)||(oe.rrdy&&om.rvalid)||(oe.awv&&om.awready)||(oe.wv&&om.wready)||(oe.bready&&om.bvalid)) AD('E28');
    if((M.eng.st===2&&om.rvalid&&((om.rresp&2)||om.rlast!==(M.eng.beat===15?1:0)))||(M.eng.st===5&&om.bvalid&&(om.bresp&2))) AD('E29');
    if(M.l1d.state!==0||cd.rv) AD('E30'); if(Ar.busy||l2v) AD('E31'); if(M.l2.state!==0||o3.hitAcc) AD('E32'); if(M.l3.state!==0||o4.hitAcc) AD('E33'); if(M.eng.st!==0) AD('E34');
    // ----- done?
    const idle=M.l1i.state===0&&M.l1d.state===0&&!M.l1i.fwd&&!M.l1d.fwd&&M.l2.state===0&&M.l3.state===0&&M.eng.st===0&&!Ar.busy&&M.mem.rs===0&&M.mem.ws===0;
    const allIn=M.ci.cur===null&&M.cd.cur===null&&M.pend.I.length===0&&M.pend.D.length===0;
    const doneNow=allIn&&idle&&M.txns.length>0&&!o1.acc&&!o2.acc;
    // ----- display
    const S1=['IDLE','ALLOC_FILL','UPDATE_TAG'], S2=['IDLE','TAG_CHECK','EVICT_WRITEBACK','ALLOC_FILL','UPDATE_TAG'], SE=['IDLE','AR','R','RESP','WR','B'];
    const marks={}; if(M.l1i.state===1) marks.l1i='stalled'; if(M.l1d.state===1) marks.l1d='stalled'; if(Ar.busy) marks.arb='live'; if(M.eng.st!==0) marks.eng='live'; if(M.eng.err) marks.merr='trapped';
    if(M.l2.state===2) marks.l2='stalled'; if(M.l3.state===2) marks.l3='stalled';
    const vals={l1i:S1[M.l1i.state],l1d:S1[M.l1d.state],arb:Ar.busy?'busy · owner '+(Ar.owner?'D':'I'):'idle',l2:S2[M.l2.state],l3:S2[M.l3.state],eng:SE[M.eng.st]+(M.eng.st===2||M.eng.st===4?' '+(M.eng.beat+1):''),skid:M.l1d.fwd?'pending':''};
    const occ={C:[ci.rv?'I '+hs(ci.ra):'',cd.rv?'D '+(cd.rwe?'st ':'ld ')+hs(cd.ra):''].filter(Boolean).join(' · ')||'idle',
      L1:'I '+S1[M.l1i.state]+' · D '+S1[M.l1d.state],L2:(Ar.busy?'busy ':'')+'L2 '+S2[M.l2.state],L3:'L3 '+S2[M.l3.state],M:'engine '+SE[M.eng.st]};
    const chips=[['i_resp_valid',o1.respv,'data'],['d_resp_valid',o2.respv,'data'],['skid pending',M.l1d.fwd,'ctl'],['arb busy',Ar.busy,'ctl'],['L2 evict',M.l2.state===2,'fwd'],['L3 evict',M.l3.state===2,'fwd'],['ARVALID',oe.arv,'mem'],['AWVALID',oe.awv,'mem'],['WVALID',oe.wv,'mem'],['RVALID',om.rvalid,'mem'],['BVALID',om.bvalid,'mem'],['mem_err',M.eng.err,'trap']];
    // replay vector: inputs, then expected outputs (see validate/replay_tb.sv)
    const b=x=>x?1:0, q=(c,v)=>c?v>>>0:0;
    const vec=[b(ci.rv),ci.ra>>>0,ci.rr,b(cd.rv),cd.ra>>>0,cd.rwe,cd.rd>>>0,cd.rs,cd.rr,b(st.ar),b(st.aw),b(st.w),
      b(o1.rdy),b(o1.respv),q(o1.respv,o1.rdata),b(o2.rdy),b(o2.respv),q(o2.respv,o2.rdata),
      b(oe.awv),q(oe.awv,oe.addr),b(oe.wv),q(oe.wv,oe.wdata),b(oe.wlast),b(oe.bready),b(oe.arv),q(oe.arv,oe.addr),b(oe.rrdy),M.eng.err,
      b(om.arready),b(om.awready),b(om.wready),b(om.bvalid),b(om.rvalid),q(om.rvalid,om.rdata),q(om.rvalid,om.rlast),q(om.rvalid,om.rresp),
      M.l1i.state,M.l1d.state,M.l2.state,M.l3.state,M.eng.st,Ar.busy,Ar.owner,Ar.last];
    return {act:[...act],marks,vals,occ,chips,events:ev,done:doneNow,doneText:'all requests answered and every unit is idle',vec,
      u:{ci,cd,o1,o2,u0rdy,u1rdy,u0rv,u1rv,sel,accept,o3,i2,o4,i3,l2line,oe,om,l2v,respTo,l2rr}};
  },
  commit(M,R){
    const u=R.u, A_=M.arb;
    l1c(M.l1i,u.ci,u.o1,{rdy:u.u0rdy,rv:u.u0rv,line:u.o3.rl});
    l1c(M.l1d,u.cd,u.o2,{rdy:u.u1rdy,rv:u.u1rv,line:u.o3.rl});
    if(u.accept) A_.last=u.sel;
    if(u.accept&&!u.i2.rwe&&!u.o3.respv){ A_.busy=1; A_.owner=u.sel; } else if(A_.busy&&u.o3.respv&&u.l2rr) A_.busy=0;
    wbCommit(M.l2,u.i2,u.o3,{rdy:u.o4.rdy,rv:u.o4.respv,line:u.l2line});
    wbCommit(M.l3,u.i3,u.o4,{rdy:u.oe.rdy,rv:u.oe.respv,line:u.oe.rl});
    const rq={rv:u.o4.dv,ra:u.o4.da,rwe:u.o4.dwe,rl:u.o4.dl,rr:u.o4.dnr};
    engCommit(M.eng,rq,u.om,u.oe);
    memCommit(M.mem,u.oe,u.om);
    cpuEdge(M.ci,u.o1.acc); cpuEdge(M.cd,u.o2.acc);
  },
  stats(M){ return [['requests done',M.n.done+' / '+M.plan.length],['L1 hit / miss',M.n.hit+' / '+M.n.miss],['AXI4 R / W bursts',M.mem.nr+' / '+M.mem.nw]]; },
  listing(M){ return M.plan.map(p=>{ const t=p.tx!=null?M.txns[p.tx]:null;
    const lbl=(p.p==='I'?'I fetch ':p.k==='S'?'D store ':'D load  ')+hs(p.a)+(p.k==='S'?' ← '+hx(p.v):'');
    return {tx:t?t.id:null,badge:p.p==='I'?'I':p.k==='S'?'S':'L',badgeCol:p.p==='I'?'--b0':p.k==='S'?'--b2':'--b1',html:`${lbl} <span class="cm">${t?'# '+t.status:'# pending'}</span>`}; }); },
  stateHTML(M){
    const reg=(r,v,cls)=>`<div class="reg${cls?' '+cls:''}"><span class="r">${r}</span><span class="v">${v}</span></div>`;
    const l1l=(L)=>[...L.valid.keys()].sort((a,b)=>a-b).map(i=>reg('set '+i,hs(((L.tag.get(i)<<12)|(i<<5))>>>0)));
    const wbl=(W)=>{ const o=[]; for(const [k,v] of [...W.valid.entries()].sort((a,b)=>a[0]-b[0])){ if(!v) continue; const s=Math.floor(k/W.p.ways),w=k%W.p.ways; const a=((W.tag.get(k)<<(W.p.off+W.p.ib))|(s<<W.p.off))>>>0; const d=!!W.dirty.get(k); o.push(reg('s'+s+' w'+w,hs(a)+(d?' · dirty':''),d?'hot':'')); } return o; };
    const sec=(t,items)=>`<div class="small muted">${t}</div><div class="regs">${items.length?items.slice(0,24).join('')+(items.length>24?`<span class="small muted">+${items.length-24} more</span>`:''):'<span class="small muted">empty</span>'}</div>`;
    return sec('L1-I lines (set → line address)',l1l(M.l1i))+sec('L1-D lines',l1l(M.l1d))+sec('L2 lines (set, way → line address)',wbl(M.l2))+sec('L3 lines',wbl(M.l3))+
      sec('AXI4 memory: write bursts seen',M.mem.wrote.map((a,i)=>reg('AW #'+(i+1),hs(a))))+
      '<div class="regs">'+reg('mem_err',String(M.eng.err))+reg('arbiter last',String(M.arb.last))+reg('AXI R / W',M.mem.nr+' / '+M.mem.nw)+'</div>';
  },
  // ---- replay vectors for validate/: inputs and expected outputs, one line per cycle, plus a header with the memory constants
  header(id){ const c=(SC.find(x=>x.id===id)||SC[0]).mem; return [c.gap,c.first,c.bdel,c.rerr<0?0xFFFF:c.rerr,c.frr,c.fbr].join(' '); },
  vectors(id,n){ const M=SIM.reset(id), out=[]; for(let c=1;c<=n;c++){ M.cyc=c; const R=SIM.eval(M); out.push(R.vec.map(v=>(v>>>0).toString(16)).join(' ')); SIM.commit(M,R); } return out; },
  length(id){ const M=SIM.reset(id); for(let c=1;c<=2000;c++){ M.cyc=c; const R=SIM.eval(M); if(R.done) return c; SIM.commit(M,R); } return -1; },
};
