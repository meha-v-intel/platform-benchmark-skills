---
name: run-benchmark
description: "Run Intel DMR platform benchmarks. Use when: running benchmarks, measuring performance, validating platform, checking frequency, memory latency, memory bandwidth, AMX throughput, wakeup latency, core-to-core latency, turbo curve, NUMA, C-states, preflight checks. Invoke with a benchmark name or 'all'."
argument-hint: "[benchmark-name|all|preflight]"
disable-model-invocation: false
allowed-tools: Bash
---

# DMR Benchmark Runner

**Platform:** Intel Diamond Rapids (DMR), 1S×32C×1T, 30GB RAM, CentOS Stream 10
**Output dir:** `/tmp/benchmarks/<timestamp>/`

## Quick Reference

| `/run-benchmark $name` | What it runs |
|---|---|
| `preflight` | NUMA check + C-state check (always run first) |
| `max-freq` | Max single-core frequency (turbostat, ~12s) |
| `turbo-curve` | Frequency vs active-core-count sweep (~2 min) |
| `core-to-core` | Core-to-core cache coherency latency (~3 min) |
| `memory-latency` | DRAM latency via pointer-chasing (~2 min) |
| `memory-bandwidth` | Peak memory bandwidth via MLC (~3 min) |
| `memory-latency-bw` | Latency-bandwidth curve sweep (~40 min) |
| `amx` | AMX BF16 + INT8 throughput via oneDNN (~5 min) |
| `wakeup` | C6 wakeup latency via wult (~35 min) |
| `cpu` | preflight + max-freq + turbo-curve + core-to-core |
| `memory` | memory-latency + memory-bandwidth |
| `all` | All applicable single-node benchmarks |

## How to Run

**Step 1 — Always run preflight first**
```bash
/run-benchmark preflight
```
This confirms NUMA=1 and C-states are healthy before spending time on micro-benchmarks.

**Step 2 — Run requested benchmark**
```bash
/run-benchmark $ARGUMENTS
```

**Step 3 — Report results**
After execution, parse and report:
- Status (passed/failed/warning)
- KPI values with units
- Delta vs GNR baseline (with sign: +X% means DMR is better for higher-is-better metrics)
- Any platform-specific notes

## Dispatch Logic

Map `$ARGUMENTS` to the appropriate sub-skill:

| Argument | Sub-skill to invoke |
|---|---|
| `preflight` | See [preflight procedure](./references/preflight.md) |
| `max-freq` | See [CPU benchmark procedure](./references/cpu-benchmarks.md) |
| `turbo-curve` | See [CPU benchmark procedure](./references/cpu-benchmarks.md) |
| `core-to-core` | See [CPU benchmark procedure](./references/cpu-benchmarks.md) |
| `cpu` | Run preflight + max-freq + turbo-curve + core-to-core in sequence |
| `memory-latency` | See [memory benchmark procedure](./references/memory-benchmarks.md) |
| `memory-bandwidth` | See [memory benchmark procedure](./references/memory-benchmarks.md) |
| `memory-latency-bw` | See [memory benchmark procedure](./references/memory-benchmarks.md) |
| `memory` | Run memory-latency + memory-bandwidth |
| `amx` | See [AMX benchmark procedure](./references/amx-benchmark.md) |
| `wakeup` | See [wakeup latency procedure](./references/wakeup-benchmark.md) |
| `all` | Run all of the above in phase order |

If `$ARGUMENTS` is empty, ask the user which benchmark they want to run and show the table above.

## Pass/Fail Criteria (DMR)

| Benchmark | Pass Threshold | GNR Reference |
|---|---|---|
| NUMA nodes | == 1 | 6 (SNC3) |
| C-state driver | intel_idle | intel_idle |
| Max frequency | ≥ 3600 MHz | 3300 MHz |
| All-core turbo | > 0 MHz, curve monotonic | 3300 MHz |
| Core-to-core | ≤ 180 cycles intra-domain | 63–71 cycles |
| Memory latency | ≤ 139 ns (2 GiB working set) | 116 ns |
| Memory BW | ≥ 1454 GBps (MLC all-reads) | 158 GB/s (per-socket) |
| AMX BF16 | > GNR at iso-core | 12.6 TFLOPS (8-core) |
| AMX INT8 | > GNR at iso-core | 22.9 TOPS (8-core) |
| Wakeup latency | median ≤ 90 µs, max ≤ 260 µs | 1.59 µs median (wult) |

## Important Platform Notes

- **Do NOT measure idle cores with turbostat** — TSC stops in C6 substates (C6A/C6S/C6SP), causing exit code 253. Always measure **loaded cores**.
- **DMR C-states**: C6A/C6S/C6SP (50/70/110 µs exit latency) — different from GNR's C6/C6P. This is correct DMR behavior.
- **Single NUMA node**: DMR on this system has 1 NUMA node. Pass = 1. GNR had 6 (SNC3).
- **All installs use `dnf`**, not `apt-get` — CentOS Stream 10.

## Additional References
- [Preflight checks](./references/preflight.md)
- [CPU benchmarks](./references/cpu-benchmarks.md)
- [Memory benchmarks](./references/memory-benchmarks.md)
- [AMX benchmark](./references/amx-benchmark.md)
- [Wakeup latency benchmark](./references/wakeup-benchmark.md)
