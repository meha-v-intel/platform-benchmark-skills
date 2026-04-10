---
name: benchmark-wakeup
description: "Run DMR wakeup latency benchmark using Intel wult tool. Use when: measuring C-state wakeup latency, measuring interrupt latency, wult benchmark, C6 exit time, real-time latency, measuring how fast cores wake from sleep."
argument-hint: "[short|full]"
allowed-tools: Bash
---

# DMR Wakeup Latency Benchmark (wult)

Measures C6 core exit latency via Intel wult TDT (TSC Deadline Timer) backend.
Argument: `short` (~5 min, 100k datapoints) or `full` (default, ~35 min, 1M datapoints).

**Do NOT use cyclictest** — it measures OS scheduling latency, not C-state exit.
GNR reference (wult): median 1.59 µs, p90 1.96 µs, max 10.59 µs.

## Step 1 — Install wult (if not already present)
```bash
which wult 2>/dev/null || {
    sudo python3 -m venv /opt/wult-venv
    source /opt/wult-venv/bin/activate
    cd ~ && git clone https://github.com/intel/pepc.git && cd pepc && pip install . && cd ~
    git clone https://github.com/intel/stats-collect.git && cd stats-collect && pip install . && cd ~
    git clone https://github.com/intel/wult.git && cd wult && pip install . && cd ~
    deactivate
    sudo ln -s /opt/wult-venv/bin/wult /usr/local/bin/wult
    sudo ln -s /opt/wult-venv/bin/pepc /usr/local/bin/pepc
    for f in /opt/wult-venv/bin/stc-*; do sudo ln -sf "$f" /usr/local/bin/$(basename "$f"); done
    echo "wult installed"
}
```

## Step 2 — Deploy kernel driver (once per kernel)
```bash
sudo wult deploy
```

## Step 3 — Set up system
```bash
cpupower frequency-set -g performance
cpupower idle-info   # confirm C1E, C6 are available

# C6 residency MSR baseline — confirm core reaches C6 during idle
modprobe msr 2>/dev/null || true
echo "C6 residency MSR (0x3FC) on CPU0: $(rdmsr -p 0 0x3FC 2>/dev/null || echo unavailable)"

# Interrupt baseline — detect background interrupt noise before test
INTR_BEFORE=$(awk '/^CPU0/{print $2}' /proc/interrupts 2>/dev/null || grep "^  0:" /proc/interrupts | awk '{print $2}')
echo "Interrupt baseline (CPU0): ${INTR_BEFORE:-unavailable}"
```

## Step 4 — Choose a test CPU
```bash
lscpu -e=CPU,NODE,SOCKET   # pick a mostly idle logical CPU
# BKM example used CPU 10 on GNR; use CPU 1 on DMR (single-socket)
TEST_CPU=1
```

## Step 5 — Run benchmark
```bash
OUTDIR=/tmp/wakeup_latency_$(date +%Y%m%d_%H%M%S)

# Short test (~5 min, ~100k datapoints — BKM step 8)
sudo wult start tdt \
    --cpu $TEST_CPU \
    --time-limit 300 \
    --stats "" \
    --outdir ${OUTDIR}_short

# Full test (~35 min, 1M datapoints — BKM recommended)
sudo wult start tdt \
    --cpu $TEST_CPU \
    --datapoints 1000000 \
    --stats "" \
    --outdir ${OUTDIR}_full

wult calc ${OUTDIR}_short   # or ${OUTDIR}_full
```

## Step 6 — Parse and report
```python
import subprocess, re, sys

outdir = sys.argv[1] if len(sys.argv) > 1 else "/tmp/wakeup_latency_latest"

result = subprocess.run(['wult', 'calc', outdir], capture_output=True, text=True)
text = result.stdout + result.stderr

stats = {}
for metric in ['min', 'median', 'p90', 'p95', 'p99', 'max']:
    m = re.search(rf'{metric}[:\s]+(\d+\.?\d*)', text, re.IGNORECASE)
    if m:
        stats[metric] = float(m.group(1))

GNR = {'median': 1.59, 'p90': 1.96, 'max': 10.59}
PASS_THRESH = {'median': 90, 'max': 260}

print("WAKEUP LATENCY RESULTS")
print("=" * 50)
print(f"Tool: wult (TDT backend, C6 state, CPU{outdir})")
for m, v in stats.items():
    gnr_str = f"GNR: {GNR[m]} µs, " if m in GNR else ""
    thresh = PASS_THRESH.get(m)
    if thresh:
        status = "PASS" if v <= thresh else "FAIL"
        print(f"  {m:8}: {v:.2f} µs  ({gnr_str}threshold: ≤{thresh} µs) — {status}")
    else:
        gnr_note = f"  GNR: {GNR[m]} µs" if m in GNR else ""
        print(f"  {m:8}: {v:.2f} µs{gnr_note}")

# Post-run interrupt delta — detect background noise during test
import subprocess as sp
intr_after_raw = sp.run(['awk', '/^CPU0/{print $2}', '/proc/interrupts'],
                        capture_output=True, text=True).stdout.strip()
print(f"\nPost-run interrupt check: {intr_after_raw or 'unavailable'}")
print("  (compare to baseline captured in Step 3 — large delta = SMI/IRQ interference)")

# dmesg NMI/watchdog check
nmi = sp.run(['dmesg', '--level=warn,err,crit'], capture_output=True, text=True)
hits = [l for l in nmi.stdout.splitlines() if any(k in l.lower() for k in ['nmi','watchdog','rcu stall','hard lockup'])]
if hits:
    print(f"\nWARN: dmesg anomalies during test:")
    for h in hits[-5:]:
        print(f"  {h}")
else:
    print("dmesg: no NMI/watchdog/RCU stall anomalies detected")
```

## Pass Criteria
| Metric | Pass Threshold | GNR Reference (wult/TDT/C6) |
|---|---|---|
| median | ≤ 90 µs | 1.59 µs |
| max | ≤ 260 µs | 10.59 µs |

DMR C6 substates have lower exit latency than GNR → expect improvement.
