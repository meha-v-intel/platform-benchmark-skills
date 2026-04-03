# Wakeup Latency Benchmark Reference

## Purpose
Measure C-state exit (wakeup) latency using Intel wult tool via TSC Deadline Timer (TDT) backend.

**Tool correction vs framework doc**: Use `wult`, NOT `cyclictest`.
- `wult` measures C-state exit latency directly (what the BKM uses)
- `cyclictest` measures OS scheduling latency — completely different metric, ~100x larger numbers
- GNR BKM measured: median 1.59 µs, p90 1.96 µs, max 10.59 µs (wult)
- Framework doc incorrectly cited: median ~88 µs (cyclictest) — do not use this as reference

---

## Install wult (if not already present)

```bash
# Check first
which wult 2>/dev/null && wult --version && exit 0

# Install into venv (avoids system Python conflicts)
python3 -m venv /opt/wult-venv
source /opt/wult-venv/bin/activate

# Install in order (dependency chain matters)
pip install git+https://github.com/intel/pepc.git
pip install git+https://github.com/intel/stats-collect.git
pip install git+https://github.com/intel/wult.git
deactivate

# Expose binaries system-wide
ln -sf /opt/wult-venv/bin/wult /usr/local/bin/wult
for f in /opt/wult-venv/bin/stc-*; do
    ln -sf "$f" /usr/local/bin/$(basename "$f")
done

# Deploy kernel driver (once per kernel boot)
wult deploy
```

### Verify
```bash
wult --version
wult deploy   # re-run if kernel was updated
```

---

## Prerequisites
```bash
# C-states must be enabled
cpupower frequency-set -g performance
cpupower idle-info   # confirm C1E, C6 are available

# Confirm C6 substates visible (DMR-specific)
cat /sys/devices/system/cpu/cpu0/cpuidle/state*/name
# Expected: POLL C1 C1E C6A C6S C6SP
```

---

## Run: Short validation test (~5 min, ~100k datapoints)

```bash
# Pick a quiet CPU (not CPU 0 which handles interrupts)
TEST_CPU=1
mkdir -p /tmp/wakeup_latency_short

sudo wult start tdt \
    --cpu $TEST_CPU \
    --time-limit 300 \
    --stats "" \
    --outdir /tmp/wakeup_latency_short

# Calculate results
wult calc /tmp/wakeup_latency_short
```

---

## Run: Full test (~35 min, 1M datapoints — recommended for final results)

```bash
TEST_CPU=1
mkdir -p /tmp/wakeup_latency_full

sudo wult start tdt \
    --cpu $TEST_CPU \
    --datapoints 1000000 \
    --stats "" \
    --outdir /tmp/wakeup_latency_full

wult calc /tmp/wakeup_latency_full
```

---

## Read Results
```bash
# Summary statistics
wult calc /tmp/wakeup_latency_full

# Key metrics to extract from output:
# WakeLatency: min, median, p90, p95, p99, max  (in microseconds)
```

### Parse from calc output
```python
import subprocess, re

result = subprocess.run(
    ['wult', 'calc', '/tmp/wakeup_latency_full'],
    capture_output=True, text=True
)
text = result.stdout + result.stderr

# Extract WakeLatency stats
stats = {}
for metric in ['min', 'median', 'p90', 'p95', 'p99', 'max']:
    m = re.search(rf'WakeLatency.*?{metric}.*?(\d+\.?\d*)\s*us', text, re.IGNORECASE | re.DOTALL)
    if m:
        stats[metric] = float(m.group(1))

print(f"WakeLatency: {stats}")
median = stats.get('median', 999)
maxval = stats.get('max', 999)
passed = median <= 90 and maxval <= 260
print(f"Pass (median≤90µs AND max≤260µs): {passed}")
```

---

## Pass Criteria

| Metric | Pass Threshold | GNR Reference (wult) |
|---|---|---|
| median | ≤ 90 µs | 1.59 µs |
| max | ≤ 260 µs | 10.59 µs |

> Note: Pass thresholds (90/260 µs) are conservative values from IPS-00946791 spec. GNR and DMR should both be well under these thresholds. The comparison of DMR vs GNR is the meaningful signal.

---

## Notes

- Use **same timer backend** (TDT) as GNR BKM for valid comparison
- Use `--stats ""` to disable statistics collection (avoids extra overhead)
- Short test (100k datapoints) is sufficient for median/p90; long test improves p99/max confidence
- DMR C6 substates (C6A/C6S/C6SP) have lower exit latencies than GNR (C6/C6P) → expect better numbers
- If `wult deploy` fails: check kernel version compatibility with `wult --version`

---

## Reporting Format

```
WAKEUP LATENCY RESULTS
======================
Tool: wult (TDT backend, C6 state, CPU1)
Datapoints: 1,000,000

WakeLatency:
  min    : X.XX µs
  median : X.XX µs  (threshold: ≤90 µs, GNR: 1.59 µs) — PASS/FAIL
  p90    : X.XX µs  (GNR: 1.96 µs)
  p95    : X.XX µs
  p99    : X.XX µs  (GNR: 1.96 µs)
  max    : X.XX µs  (threshold: ≤260 µs, GNR: 10.59 µs) — PASS/FAIL

Status : PASS/FAIL
```
