# Preflight Checks Reference

## Benchmarks Covered
- NUMA Check
- C-State Check

## Prerequisites
```bash
dnf install -y numactl   # if not already installed
```

---

## 1. NUMA Check

### Purpose
Confirm this DMR system exposes a single NUMA domain. A result of >1 suggests SNC is enabled unexpectedly, which will inflate memory latency numbers and invalidate micro-benchmark comparisons.

### Commands
```bash
numactl --hardware
lscpu | grep -E "NUMA|Socket|Core|Thread|CPU\(s\)"
```

### Expected Output (DMR — PASS)
```
available: 1 nodes (0)
node 0 cpus: 0 1 2 3 ... 31
node 0 size: 31608 MB
node 0 free: XXXX MB
node distances:
node   0
  0:  10
```

### Pass Criteria
- `available: 1 nodes` → **PASS**
- `available: N nodes` where N > 1 → **FAIL** — check BIOS SNC setting

### GNR Reference (for comparison)
GNR Imperia had 6 NUMA nodes (SNC3), ~193 GB/node. DMR is single-domain — this is the expected improvement, not a misconfiguration.

---

## 2. C-State Check

### Purpose
Enumerate core idle states and confirm `intel_idle` driver is active. On DMR, expect new granular C6 substates (C6A/C6S/C6SP) — these are different from GNR and confirm new power management is active.

### Commands
```bash
cat /sys/devices/system/cpu/cpu0/cpuidle/state*/name
cat /sys/devices/system/cpu/cpu0/cpuidle/state*/latency
cat /sys/devices/system/cpu/cpuidle/current_driver
```

### Expected Output (DMR)
```
# Names:
POLL
C1
C1E
C6A
C6S
C6SP

# Exit latencies (µs):
0
1
2
50
70
110

# Driver:
intel_idle
```

### Pass Criteria
- Driver = `intel_idle` → **PASS**
- DMR C-states (C6A/C6S/C6SP) differ from GNR (C6/C6P) — this is **correct and expected**
- C6SP deepest exit latency = 110 µs (vs GNR C6P = 210 µs — 47.6% improvement)

### GNR Reference
```
POLL, C1, C1E, C6, C6P
Exit latencies: 1, 4, 170, 210 µs
```

---

## Reporting Format

After running both checks, report:
```
PREFLIGHT RESULTS
=================
NUMA Check     : PASS  — 1 node, 30.9 GiB, 32 cores, 1T/core
C-State Check  : PASS  — intel_idle, states: POLL/C1/C1E/C6A/C6S/C6SP
                         DMR deepest C6 exit: 110µs (vs GNR 210µs, -47.6%)
Preflight      : PASS — safe to proceed with micro-benchmarks
```
