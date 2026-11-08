# Checking the explorer's model against the RTL

`docs/architecture_explorer.html` animates a JavaScript model of `mlc_cache_top` (default sizes) and `sim/axi_mem_model.sv`.
This folder shows that the model and the RTL agree.

```bash
docs/validate/run_replay.sh      # needs Icarus Verilog 12 and Python 3; about 10 s
```

What it does: each file in `vec/` is the CPU-port input stream and the memory stall pattern that the model used for one scenario
of the page, followed by what the model predicted for 32 outputs and unit states in every cycle. `replay_tb.sv` applies the inputs
to the real `mlc_cache_top` and the real `sim/axi_mem_model.sv`, prints the same 32 values, and `compare.py` checks them one by
one. The last result is in `result.txt`.

What is compared in every cycle: `i_req_ready`, `i_resp_valid`, `i_resp_rdata`, the same three on the data port, every AXI4 master
and slave signal that matters (`awvalid`, `awaddr`, `wvalid`, `wdata`, `wlast`, `bready`, `arvalid`, `araddr`, `rready`,
`arready`, `awready`, `wready`, `bvalid`, `rvalid`, `rdata`, `rlast`, `rresp`), `mem_err`, the FSM state of both L1s, L2, L3 and the
AXI4 engine, and the arbiter's `busy`, `owner` and `last`. Data fields are compared only while their valid is high.

Not covered: the reset sequence (the model starts after `reset_sync` has released the units), `aw_mode` 1 and 2 of the memory model,
an early or missing RLAST, error responses on the write channel, and stalls on AW and W. Lines that were never written are
undefined in the RTL and shown as zero by the model; they are never compared.

To record new vectors after changing the model (`docs/explorer_src/sim.js`), open the rebuilt page and run this in the browser
console, then put the downloaded files in `vec/`:

```js
for (const s of SIM.scenarios) {
  const n = SIM.length(s.id) + 12;
  const text = SIM.header(s.id) + '\n' + SIM.vectors(s.id, n).join('\n') + '\n';
  const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([text])); a.download = s.id + '.vec'; a.click();
}
```
