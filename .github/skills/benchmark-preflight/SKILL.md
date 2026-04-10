---
name: benchmark-preflight
description: "Run DMR platform preflight checks: NUMA check and C-state check. Use when: starting benchmarks, validating platform setup, checking NUMA topology, checking C-states, verifying intel_idle driver, pre-benchmark validation."
allowed-tools: Bash
---

# DMR Preflight Checks

Run both checks and report. Always run preflight before any micro-benchmark.

## Step 1 — Install numactl if missing
```bash
which numactl || dnf install -y numactl
```

## Step 1.5 — Baseline Snapshot

```bash
# SMI baseline — reference point for HFT gate and anomaly detection
which rdmsr 2>/dev/null || dnf install -y msr-tools
modprobe msr 2>/dev/null || true
SMI_BASELINE=$(rdmsr -a 0x34 2>/dev/null | head -1)
echo "SMI baseline: ${SMI_BASELINE:-unavailable}"

# CPU governor and boost state
cpupower frequency-info | grep -E "governor|boost|current CPU frequency"

# Turbostat idle snapshot — confirm boost enabled, C-states active, baseline power
which turbostat 2>/dev/null || dnf install -y kernel-tools
turbostat --interval 2 --num_iterations 1 --Summary 2>/dev/null \
    | grep -E "Avg_MHz|Bzy_MHz|Busy%|Pkg%pc6|PkgWatt" \
    || echo "turbostat: unavailable — install kernel-tools"
```

**Pass**: governor = `performance`, boost = `enabled`.
**Fail**: `powersave` governor or boost disabled will invalidate all frequency and throughput benchmarks — fix before proceeding.

## Step 2 — NUMA Check
```bash
numactl --hardware
lscpu | grep -E "NUMA|Socket|Core|Thread|CPU\(s\)"
numactl --hardware | grep -E "node [0-9]+ size"
numactl --distance
```

**Pass**: `available: 1 nodes` — DMR is single-domain.
**Fail**: >1 node means SNC is enabled in BIOS — check platform config.

## Step 3 — C-State Check
```bash
cat /sys/devices/system/cpu/cpu0/cpuidle/state*/name
cat /sys/devices/system/cpu/cpu0/cpuidle/state*/desc
cat /sys/devices/system/cpu/cpu0/cpuidle/state*/latency
cat /sys/devices/system/cpu/cpu0/cpuidle/state*/power
cat /sys/devices/system/cpu/cpuidle/current_driver
dmesg | grep -i cpuidle
dmesg | grep -i c-state
```

**Pass**: driver = `intel_idle`.
**DMR C-states** (C6A/C6S/C6SP at 50/70/110 µs) are different from GNR (C6/C6P at 170/210 µs) — this is **correct and expected behavior**, not a failure.

## Step 4 — Report

Report as:
```
PREFLIGHT RESULTS
=================
NUMA Check  : PASS/FAIL  — N nodes, X GiB, 32 cores, 1T/core
C-State     : PASS/FAIL  — driver: intel_idle, states: [list]
              DMR deepest C6 exit: 110µs (vs GNR 210µs, -47.6%)
Governor    : PASS/FAIL  — performance / [actual governor]
Boost       : PASS/FAIL  — enabled / disabled
Baseline    : SMI=N, idle PkgWatt=X W, Bzy_MHz=Y
Preflight   : PASS — safe to proceed / FAIL — investigate before continuing
```

See [full preflight reference](../.github/skills/run-benchmark/references/preflight.md) for detailed expected values.
