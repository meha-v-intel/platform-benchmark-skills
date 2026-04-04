---
name: benchmark-preflight
description: "Run DMR platform preflight checks: NUMA check and C-state check. Use when: starting benchmarks, validating platform setup, checking NUMA topology, checking C-states, verifying intel_idle driver, pre-benchmark validation, checking if the platform is ready, system health check, first check before any workload, verify hardware configuration, is this machine ready to benchmark."
allowed-tools: Bash
---

# DMR Preflight Checks

Run both checks and report. Always run preflight before any micro-benchmark.

## Variables

| Variable | Description | Example |
|---|---|---|
| `$LAB_HOST` | SSH target alias from `~/.ssh/config` | `lab-target` |
| `$OUTPUT_DIR` | Remote results directory | `/tmp/benchmarks/2026-04-04/` |

Set by the agent before invoking this skill. See `AGENT.md`.

## Step 1 — Install numactl if missing
```bash
which numactl || dnf install -y numactl
```

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
Preflight   : PASS — safe to proceed / FAIL — investigate before continuing
```

See [full preflight reference](../.github/skills/run-benchmark/references/preflight.md) for detailed expected values.
