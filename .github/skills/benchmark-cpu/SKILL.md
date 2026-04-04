---
name: benchmark-cpu
description: "Run DMR CPU micro-benchmarks: max frequency, turbo curve, core-to-core latency. Use when: measuring CPU frequency, checking turbo boost, measuring core-to-core cache latency, validating CPU performance, running frequency sweep, app server sizing, web server validation, compute node readiness, HPC validation, single-threaded performance, multi-threaded scaling, latency-sensitive workload, frequency-sensitive application."
argument-hint: "[max-freq|turbo-curve|core-to-core|all]"
allowed-tools: Bash
---

# DMR CPU Benchmarks

Runs: max frequency test, turbo curve sweep, core-to-core latency.
Argument: `$ARGUMENTS` — one of `max-freq`, `turbo-curve`, `core-to-core`, or `all` (default).

## Variables

| Variable | Description | Example |
|---|---|---|
| `$LAB_HOST` | SSH target alias from `~/.ssh/config` | `lab-target` |
| `$OUTPUT_DIR` | Remote results directory | `/tmp/benchmarks/2026-04-04/` |
| `$NPROC` | Core count discovered at runtime | `32` |
| `$WORK_DIR` | Home directory on remote machine | `/root` |

Set by the agent before invoking this skill. See `AGENT.md`.

## CRITICAL: DMR turbostat rule
**Never measure idle cores.** DMR's C6 substates (C6A/C6S/C6SP) stop the TSC, causing turbostat exit 253. Always pin a busy loop to the CPU being measured.

## Max Frequency Test (~12s)
```bash
sudo cpupower frequency-set -g performance
taskset -c 1 bash -c 'while :; do :; done' &
LOOP_PID=$!
sleep 1
ps -o pid,psr,comm -C bash   # confirm PSR=1
sudo turbostat --cpu 1 --interval 1
kill $LOOP_PID; wait $LOOP_PID 2>/dev/null
```
Parse: max `Bzy_MHz`. Pass ≥ 3600 MHz. GNR: 3300 MHz. DMR BKC expected: ~2799 MHz.

## Turbo Curve (~2 min, 31 steps)
**BKM script** (GNR reference, adapt LOAD_CORES for DMR's 31 cores): `scripts/turbo_curve_imperia_final.sh`

Use the adapter:
```python
import sys; sys.path.insert(0, '/root/benchmark_automation')
from pathlib import Path
from benchmarks.turbo_curve import TurboCurveAdapter
a = TurboCurveAdapter(Path('/tmp/turbo_curve'))
a.setup(); a.run()
r = a.collect_results()
print(r.status)
for k in r.kpis: print(f"  {k.name}={k.value:.0f} {k.unit}")
print("Curve:", r.metadata['curve'][:5], "...")
```
Pass: monotonically non-increasing curve, all-core turbo > 0. GNR: 3300 MHz all-core.

## Core-to-Core Latency (~3 min)
```bash
# System setup (BKM step 1)
sudo systemctl stop irqbalance
sudo systemctl stop unattended-upgrades
cpupower frequency-info   # confirm governor=performance, boost enabled

# Build if needed (BKM: git clone + cargo build)
ls ${WORK_DIR}/core-to-core-latency/target/release/core-to-core-latency 2>/dev/null || {
    which cargo || dnf install -y cargo rust
    cd ${WORK_DIR} && git clone https://github.com/nviennot/core-to-core-latency.git
    cd core-to-core-latency && cargo build --release
}
C2C=${WORK_DIR}/core-to-core-latency/target/release/core-to-core-latency

# Quick test (8 cores, ~30s)
sudo $C2C 500 20 --cores 0,1,2,3,4,5,6,7 --csv | tee /tmp/c2c_quick.csv

# Full 32-core matrix (~3 min) — BKM step 6: 1000 iterations, 300 samples
sudo $C2C 1000 300 --cores $(seq -s, 0 $((NPROC-1))) --csv | tee /tmp/c2c_full.csv
```
Parse max off-diagonal. Pass ≤ 180 cycles. GNR: 63–71 cycles intra-SNC.

## Report Format
```
CPU BENCHMARK RESULTS
=====================
Max Frequency : FAIL  — 2799 MHz (threshold: ≥3600 MHz, GNR: 3300 MHz, -15.2%)
Turbo Curve   : PASS  — 1-core: XXXX MHz, 31-core: XXXX MHz, spread: XXX MHz
Core-to-Core  : PASS  — max XX cycles (threshold: ≤180, GNR: 63-71 intra-SNC)
```
