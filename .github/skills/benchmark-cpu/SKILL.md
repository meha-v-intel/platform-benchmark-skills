---
name: benchmark-cpu
description: "Run DMR CPU micro-benchmarks: max frequency, turbo curve, core-to-core latency. Use when: measuring CPU frequency, checking turbo boost, measuring core-to-core cache latency, validating CPU performance, running frequency sweep."
argument-hint: "[max-freq|turbo-curve|core-to-core|all]"
allowed-tools: Bash
---

# DMR CPU Benchmarks

Runs: max frequency test, turbo curve sweep, core-to-core latency.
Argument: `$ARGUMENTS` — one of `max-freq`, `turbo-curve`, `core-to-core`, or `all` (default).

## CRITICAL: DMR turbostat rule
**Never measure idle cores.** DMR's C6 substates (C6A/C6S/C6SP) stop the TSC, causing turbostat exit 253. Always pin a busy loop to the CPU being measured.

## Pre-run Baseline
```bash
# Actual P-state ratio (IA32_PERF_CTL MSR) and HWP mode
modprobe msr 2>/dev/null || true
echo "Current P-state ratio (MSR 0x198): $(rdmsr -f 15:8 0x198 2>/dev/null | head -1 || echo unavailable)"
echo "HWP enabled (MSR 0x770 bit 0): $(rdmsr -f 0:0 0x770 2>/dev/null | head -1 || echo unavailable)"

# Thermal baseline — headroom to throttle point
paste \
    <(cat /sys/class/thermal/thermal_zone*/type 2>/dev/null) \
    <(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | awk '{printf "%.1f°C\n", $1/1000}') \
    2>/dev/null || echo "thermal sysfs: unavailable"
```

## Max Frequency Test (~12s)
```bash
sudo cpupower frequency-set -g performance
taskset -c 1 bash -c 'while :; do :; done' &
LOOP_PID=$!
sleep 1
ps -o pid,psr,comm -C bash   # confirm PSR=1

# Monitor frequency AND package power during the busy loop
sudo turbostat --cpu 1 --interval 1 --show \
    Avg_MHz,Bzy_MHz,Busy%,PkgWatt,CorWatt,CoreTmp,PkgTmp 2>/dev/null \
    | tee /tmp/cpu_maxfreq_turbostat.txt
kill $LOOP_PID; wait $LOOP_PID 2>/dev/null

# Post-run thermal margin check
MAX_TEMP=$(awk 'NR>1 && $6~/[0-9]/{if($6>m)m=$6} END{print m+0}' /tmp/cpu_maxfreq_turbostat.txt)
echo "Peak CoreTmp during test: ${MAX_TEMP}°C  (throttle typically at 105°C — margin: $((105-MAX_TEMP))°C)"
```
Parse: max `Bzy_MHz`. Pass ≥ 3600 MHz. GNR: 3300 MHz. DMR BKC expected: ~2799 MHz.
Flag if `PkgWatt` shows sustained drop mid-test (power throttle) or `CoreTmp` > 95°C (thermal throttle).

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
ls /root/core-to-core-latency/target/release/core-to-core-latency 2>/dev/null || {
    which cargo || dnf install -y cargo rust
    cd /root && git clone https://github.com/nviennot/core-to-core-latency.git
    cd core-to-core-latency && cargo build --release
}
C2C=/root/core-to-core-latency/target/release/core-to-core-latency

# Quick test (8 cores, ~30s)
sudo $C2C 500 20 --cores 0,1,2,3,4,5,6,7 --csv | tee /tmp/c2c_quick.csv

# Full 32-core matrix (~3 min) — BKM step 6: 1000 iterations, 300 samples
sudo $C2C 1000 300 --cores $(seq -s, 0 31) --csv | tee /tmp/c2c_full.csv
```
Parse max off-diagonal. Pass ≤ 180 cycles. GNR: 63–71 cycles intra-SNC.

## Report Format
```
CPU BENCHMARK RESULTS
=====================
Max Frequency : FAIL  — 2799 MHz (threshold: ≥3600 MHz, GNR: 3300 MHz, -15.2%)
  PkgWatt peak: XX W | CoreTmp peak: XX°C (margin: XX°C to throttle)
  P-state MSR: 0xXX | HWP: enabled/disabled
Turbo Curve   : PASS  — 1-core: XXXX MHz, 31-core: XXXX MHz, spread: XXX MHz
Core-to-Core  : PASS  — max XX cycles (threshold: ≤180, GNR: 63-71 intra-SNC)
Thermal       : PASS/WARN — peak XX°C, XX°C headroom  [WARN if < 10°C margin]
```
