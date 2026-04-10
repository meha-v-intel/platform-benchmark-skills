---
name: run-benchmark
description: "Run Intel DMR platform benchmarks. Use when: running benchmarks, measuring performance, validating platform, checking frequency, memory latency, memory bandwidth, AMX throughput, wakeup latency, core-to-core latency, turbo curve, NUMA, C-states, preflight checks. Invoke with a benchmark name or 'all'."
argument-hint: "[benchmark-name|all|preflight]"
disable-model-invocation: false
allowed-tools: Bash
---

# DMR Benchmark Runner

**Platform:** Intel Diamond Rapids (DMR), 1S×32C×1T, 30GB RAM, CentOS Stream 10
**Output dir:** `${BENCHMARK_OUTDIR:-/datafs/benchmarks}/<timestamp>-<type>/` (persistent; never `/tmp/`)

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

**Step 4 — Write mandatory output files**
Write both `deep_dive_report.md` and `tuning_recommendations.md` to `$OUTDIR/` on the remote machine. See **Mandatory Reports** below.

## Output Directory and Raw Data

**All raw data and reports MUST be written to a persistent directory on the remote machine.** Never use `/tmp/` — data is lost on reboot.

```bash
# Standard OUTDIR — set BENCHMARK_OUTDIR env var to override
OUTDIR=${BENCHMARK_OUTDIR:-/datafs/benchmarks}/$(date +%Y%m%dT%H%M)-${BENCH_TYPE:-benchmark}
mkdir -p $OUTDIR/{bench,emon,monitor,sysconfig}

# Capture sysconfig snapshot at the start of every benchmark run
lscpu                        > $OUTDIR/sysconfig/cpu_info.txt
numactl --hardware           > $OUTDIR/sysconfig/numa_topology.txt
dmidecode -t 17 2>/dev/null  > $OUTDIR/sysconfig/dimm_info.txt
cpupower frequency-info      > $OUTDIR/sysconfig/cpupower.txt 2>&1
rdmsr -a 0x34 2>/dev/null    > $OUTDIR/sysconfig/smi_baseline.txt
echo "Output dir: $OUTDIR"
```

**Expected output structure:**
```
$OUTDIR/
├── bench/          # raw benchmark logs (turbostat, MLC, wult, benchdnn, hft_rdtscp)
├── emon/           # perf stat .perf files — one per workload
├── monitor/        # turbostat during-run, RAPL energy, numastat pre/post, NIC baseline
├── sysconfig/      # cpu_info, numa_topology, dimm_info, cpupower, smi_baseline
├── deep_dive_report.md       ← REQUIRED after every run
└── tuning_recommendations.md ← REQUIRED after every run
```

## Mandatory Reports

**`deep_dive_report.md` and `tuning_recommendations.md` are REQUIRED after every benchmark run** — individual benchmark or full suite. Generate them even when all KPIs pass (the tuning report must then state: "No misses — all KPIs passed in this run.").

Write both files to `$OUTDIR/` on the remote machine using `cat > $OUTDIR/deep_dive_report.md << 'EOF'` so the data persists, not just printed to the console.

### deep_dive_report.md — Required Sections

1. **Platform Summary** — CPU model, socket × core × thread, NUMA topology, memory config, OS, kernel version, microcode, cpufreq governor
2. **Preflight Status** — NUMA node count, C-state driver, governor, turbo boost state, SMI baseline count, THP setting
3. **Monitoring Telemetry** — *(see template below)* — every monitoring tool run, its exact command, purpose, and the absolute path to its raw output file in `$OUTDIR`
4. **Benchmark Results** — per-KPI table: metric name, measured value + units, pass threshold, PASS/FAIL/WARN, delta vs GNR reference
5. **Key Findings** — numbered list; each finding MUST cite the raw data file it was derived from (e.g., `"IPC=1.4 from emon/BlackScholesDP_pr32.perf → memory-bound"`)
6. **Raw Data Files Index** — table of every file written to `$OUTDIR` with one-line description
7. **Overall Verdict** — PASS / CONDITIONAL / FAIL with one-sentence justification

#### Monitoring Telemetry Section Template

```markdown
## Monitoring Telemetry

### Tools Executed

| Tool | Command | Purpose | Raw Output File |
|---|---|---|---|
| `turbostat` | `turbostat --interval 1 --show Avg_MHz,Bzy_MHz,Busy%,PkgWatt,CorWatt,CoreTmp` | CPU frequency, package power (W), core temp (°C) during run | `$OUTDIR/monitor/turbostat.txt` |
| `perf stat -a` | `perf stat -a -e cycles,instructions,LLC-load-misses,mem_inst_retired.all_loads,cycle_activity.stalls_mem_any` | System-wide IPC, LLC miss rate, memory load rate, memory stall cycles | `$OUTDIR/emon/<workload>.perf` |
| `RAPL` | `perf stat -a -e power/energy-pkg/,power/energy-cores/,power/energy-dram/` | Package, core, and DRAM energy (Joules) per run | `$OUTDIR/monitor/rapl.txt` |
| `rdmsr 0x34` | `rdmsr -a 0x34` | SMI count — baseline before run and delta after | `$OUTDIR/sysconfig/smi_baseline.txt` |
| `numastat -c` | `numastat -c` | NUMA remote page access counts — pre and post run | `$OUTDIR/monitor/numastat_pre.txt`, `$OUTDIR/monitor/numastat_post.txt` |
| `dmidecode -t 17` | `dmidecode -t 17` | DIMM population, speed (MT/s), configured speed | `$OUTDIR/sysconfig/dimm_info.txt` |
| `cpupower frequency-info` | `cpupower frequency-info` | CPU governor, min/max frequency, boost state | `$OUTDIR/sysconfig/cpupower.txt` |
| `ethtool -S` | `ethtool -S <nic>` (HFT only) | NIC TX/RX drop counters — pre and post run | `$OUTDIR/monitor/nic_baseline.txt`, `$OUTDIR/monitor/nic_post.txt` |

### Metrics Observed

Fill in from raw data files after the run:

| Metric | Value | Threshold / Expected | Status |
|---|---|---|---|
| IPC (system-wide) | — | 2–4 (FP workloads); >1.5 (general) | — |
| LLC miss rate | — | <30% → compute-bound; >50% → memory-bound | — |
| Package power peak (W) | — | ≤ TDP | — |
| DRAM energy per run (J) | — | informational | — |
| Frequency min/max during run | — | <5% droop from max turbo | — |
| SMI count during test | — | 0 (hard HFT gate) | — |
| NUMA remote hits delta | — | 0 | — |
| Peak CoreTmp (°C) | — | <95°C | — |
```

### tuning_recommendations.md — Required Sections

1. **Header** — session ID, platform summary, date
2. **KPI Scorecard** — table: metric | measured | reference | gap | severity (Critical / High / Medium / Low / ✅ Pass)
3. **Per-Issue Recommendations** — for each non-passing KPI: Assessment, Root Cause, Fix (bash block), Expected Improvement after fix
4. **Priority Order** — table: priority | action | impact | effort
5. **Combined Implementation Sequence** — Phase 1 (immediate, <5 min), Phase 2 (same session), Phase 3 (next run) — each with predicted KPI outcomes after applying that phase

> If all KPIs pass: `tuning_recommendations.md` must still be generated. Set scorecard status to ✅ Pass for all rows and state "No misses — all KPIs met in this run."

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
