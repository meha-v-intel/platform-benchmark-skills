# CPU Benchmarks Reference

## Benchmarks Covered
- Max Frequency Test
- Turbo Curve
- Core-to-Core Latency

---

## CRITICAL: turbostat Idle-Core Limitation on DMR

**DMR uses C6A/C6S/C6SP substates. When a core is idle, its TSC stops.**
turbostat detects this and exits with code 253 and error:
```
turbostat: Insanely slow TSC rate, TSC stops in idle?
```

**Rule: Always measure a LOADED core, never an idle observer core.**

This differs from the GNR BKM which tried to use CPU0 as an idle observer. On DMR, use the loaded core itself for frequency measurement.

---

## 1. Max Frequency Test

### Purpose
Measure sustained single-core frequency under 100% load. Pass ≥ 3600 MHz.
Note: DMR BKC platform currently measures ~2799 MHz (pre-production silicon — expected).

### Prerequisites
```bash
which turbostat   # should be /usr/bin/turbostat
which taskset     # should be /usr/bin/taskset
```

### Commands
```bash
# Pin busy loop to CPU 1
taskset -c 1 bash -c 'while :; do :; done' &
LOOP_PID=$!
sleep 1

# Measure the LOADED core (CPU 1)
turbostat --cpu 1 --interval 1 --num_iterations 10 \
    --show Busy%,Bzy_MHz,CoreTmp --quiet

kill $LOOP_PID; wait $LOOP_PID 2>/dev/null
```

### Expected Output
```
Busy%   Bzy_MHz CoreTmp
100.00  2799    57
100.00  2798    57
...
```

### Pass Criteria
- `Bzy_MHz >= 3600` → **PASS**
- DMR BKC measures ~2799 MHz → **FAIL** (expected on pre-production silicon)
- `Busy% = 100` confirms core is fully loaded
- Temperature should be stable (not rising each second = not throttling)

### GNR Reference: 3300 MHz

---

## 2. Turbo Curve

### Purpose
Measure frequency at each active-core count from 1 to 31. Shows the three-tier turbo structure of DMR.

### DMR Expected Shape (measured)
- **Cores 1–20**: ~2780–2799 MHz (high-turbo tier, flat)
- **Cores 21–24**: ~2550–2680 MHz (mid-turbo tier, step down)
- **Cores 25–31**: ~2195–2293 MHz (base turbo tier)
- **Spread**: ~601 MHz from 1-core to 31-core

### Commands
```bash
# Run the sweep (takes ~2 min for 31 cores × ~4s each)
python3 /root/benchmark_automation/benchmarks/turbo_curve.py 2>/dev/null || \
python3 -c "
import subprocess, time, re

def read_freq(cpu, iters=2):
    r = subprocess.run(
        ['turbostat','--cpu',str(cpu),'--interval','1',
         '--num_iterations',str(iters),'--show','Bzy_MHz','--quiet'],
        capture_output=True, text=True)
    vals = [float(x) for x in re.findall(r'^\d+', r.stdout, re.MULTILINE)]
    return sum(vals)/len(vals) if vals else 0.0

print('active_cores,bzy_mhz')
procs = []
for n in range(1, 32):
    p = subprocess.Popen(['taskset','-c',str(n),'bash','-c','while :; do :; done'])
    procs.append(p)
    time.sleep(2)
    freq = read_freq(cpu=1)
    print(f'{n},{freq:.0f}', flush=True)

for p in procs: p.kill()
for p in procs: p.wait()
"
```

### Using the adapter (preferred)
```python
from pathlib import Path
from benchmarks.turbo_curve import TurboCurveAdapter

adapter = TurboCurveAdapter(Path('/tmp/turbo_curve'))
adapter.setup()
adapter.run()
result = adapter.collect_results()
print(result.status, result.kpis)
```

### Pass Criteria
- Curve is monotonically non-increasing (allow ±50 MHz noise)
- All-core turbo > 0 MHz
- **GNR reference**: 3300 MHz all-core

---

## 3. Core-to-Core Latency

### Purpose
Measure cache-line ping-pong round-trip latency (cycles) between every pair of cores. Pass ≤ 180 cycles.

### Install
```bash
# Download pre-built Rust binary (distro-independent)
wget -q https://github.com/nviennot/core-to-core-latency/releases/latest/download/core-to-core-latency-x86_64 \
    -O /usr/local/bin/core-to-core-latency
chmod +x /usr/local/bin/core-to-core-latency
```

### Commands

**Quick smoke test (~30 sec):**
```bash
core-to-core-latency 300 10 --cores 0,1,2,3,4,5,6,7 --csv \
    | tee /tmp/c2c_quick.csv
```

**Full 32-core matrix (~3 min):**
```bash
ALL_CORES=$(seq -s, 0 31)
core-to-core-latency 500 20 --cores $ALL_CORES --csv \
    | tee /tmp/c2c_full.csv
```

### Interpreting CSV Output
```
     0    1    2    3  ...
0    0   65   68   70
1   65    0   64   67
2   68   64    0   65
...
```
- Diagonal = 0 (self)
- Off-diagonal = round-trip latency in cycles
- DMR has 1 NUMA node → expect **uniform low latency** across all 32 cores (no cross-NUMA block pattern)
- GNR SNC3 showed 6 diagonal blocks at ~63–71 cycles; cross-block was higher

### Pass Criteria
- Max off-diagonal value ≤ 180 cycles → **PASS**
- DMR with 1 NUMA node should show a uniform matrix (~60–90 cycles expected)

### Parse Result
```python
import pandas as pd
df = pd.read_csv('/tmp/c2c_full.csv', index_col=0)
max_latency = df.values[df.values > 0].max()
print(f"Max core-to-core latency: {max_latency:.0f} cycles")
print(f"Pass (≤180): {max_latency <= 180}")
```

---

## Reporting Format

```
CPU BENCHMARK RESULTS
=====================
Max Frequency  : FAIL  — 2799 MHz max, 2798 MHz avg (threshold: 3600 MHz, GNR: 3300 MHz, delta: -15.2%)
                         Note: expected on DMR BKC pre-production silicon
Turbo Curve    : PASS  — 1-core: 2799 MHz, 31-core: 2198 MHz, spread: 601 MHz
                         3-tier shape: high(1-20)→mid(21-24)→base(25-31)
Core-to-Core   : PASS  — max X cycles (threshold: 180 cycles, GNR: 63-71 cycles intra-SNC)
```
