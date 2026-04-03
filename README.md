# Intel Platform Benchmark Skills for GitHub Copilot

GitHub Copilot skills for running Intel Xeon platform micro-benchmarks. Clone this repo and ask Copilot to run any benchmark — it knows the exact commands, tools, pass/fail criteria, and GNR baseline values.

All skills are validated against Intel BKM (Best Known Method) documents.

---

## How to use

1. Clone this repo into your project (or add it as a submodule)
2. Open the project in VS Code with GitHub Copilot Chat enabled
3. Ask Copilot in natural language:

```
run the preflight checks
run the CPU benchmarks
run the wakeup latency benchmark
what is the memory latency on this system?
```

Copilot automatically loads the relevant skill and runs the correct commands for your system.

---

## Skills

| Skill | What it runs | Typical runtime |
|---|---|---|
| `benchmark-preflight` | NUMA topology check + C-state enumeration | ~10s |
| `benchmark-cpu` | Max frequency, turbo curve, core-to-core latency | ~5 min |
| `benchmark-memory` | DRAM latency (multichase), bandwidth (PKB), latency-BW curve (MLC) | ~45 min |
| `benchmark-amx` | AMX BF16 + INT8 throughput via oneDNN benchdnn | ~5 min |
| `benchmark-wakeup` | C6 wakeup latency via Intel wult (TDT backend) | ~5–35 min |
| `run-benchmark` | Orchestrator — dispatches to any of the above | varies |

---

## Pass/fail criteria

| Benchmark | Metric | Pass threshold | GNR reference |
|---|---|---|---|
| NUMA check | Node count | = 1 (single domain) | 6 nodes (SNC3) |
| C-state check | cpuidle driver | intel_idle | intel_idle |
| Max frequency | Bzy_MHz | ≥ 3600 MHz | 3300 MHz |
| Core-to-core latency | Mean round-trip | ≤ 180 cycles | 63–71 cycles |
| Memory latency | 2 GiB working set | ≤ 139 ns | 116 ns |
| AMX BF16 (iso-core 8C) | Throughput | > 12.6 TFLOPS | 12.6 TFLOPS |
| AMX INT8 (iso-core 8C) | Throughput | > 22.9 TOPS | 22.9 TOPS |
| Wakeup latency | Median | ≤ 90 µs | 1.59 µs |
| Wakeup latency | Max | ≤ 260 µs | 10.59 µs |

---

## Prerequisites by benchmark

| Benchmark | Required tools |
|---|---|
| Preflight | `numactl` |
| CPU (max-freq, turbo) | `turbostat`, `cpupower` |
| CPU (core-to-core) | `cargo` + `git` (builds [nviennot/core-to-core-latency](https://github.com/nviennot/core-to-core-latency)) |
| Memory latency | `multichase` (via PKB or standalone build) |
| Memory bandwidth | PerfKitBenchmarker (PKB) |
| Memory lat-BW curve | Intel MLC v3.12 (download from Intel) |
| AMX | Intel oneDNN `benchdnn` (built from source or pre-built) |
| Wakeup | Intel `wult` v1.12+ (installed automatically by the skill) |

---

## Platform

These skills were developed and validated on:

- **Intel Diamond Rapids (DMR)** — 1S × 32C × 1T, single NUMA domain
- CentOS Stream 10, kernel 6.18.0 (BKC)
- GNR baselines from Intel Xeon 6985P-C (2S × 60C, SNC3, Ubuntu 24.04)

Skills adapt automatically to the system they run on. Core counts, NUMA topology, and tool paths are discovered at runtime, not hardcoded.

---

## Repository structure

```
.github/skills/
├── run-benchmark/              # Orchestrator skill
│   ├── SKILL.md
│   └── references/             # Detailed per-benchmark reference docs
│       ├── preflight.md
│       ├── cpu-benchmarks.md
│       ├── memory-benchmarks.md
│       ├── amx-benchmark.md
│       └── wakeup-benchmark.md
├── benchmark-preflight/
│   └── SKILL.md
├── benchmark-cpu/
│   ├── SKILL.md
│   └── scripts/
│       └── turbo_curve_imperia_final.sh   # BKM-provided script
├── benchmark-memory/
│   ├── SKILL.md
│   └── scripts/
│       └── run_mlc_lat_bw.sh              # BKM-provided MLC sweep script
├── benchmark-amx/
│   └── SKILL.md
└── benchmark-wakeup/
    └── SKILL.md
```

---

## BKM validation

Every command in these skills was validated line-by-line against Intel internal BKM documents:

- `NUMA_CHECK_BKM_NEW_BIOS`
- `C_STATE_CHECK_BKM_NEW_BIOS`
- `MAX_FREQ_TEST_BKM`
- `TURBO_CURVE_BKM`
- `CORE_TO_CORE_LATENCY_BKM_NEW_BIOS`
- `MEMORY_LATENCY_PKB_BKM_NEW_BIOS`
- `MEMORY_BANDWIDTH_PKB_BKM_NEW_BIOS`
- `MEMORY_LATENCY_BANDWIDTH_CURVE_BKM`
- `AMX_PERFORMANCE_BKM_NEW_BIOS_GNR`
- `WAKEUP_LATENCY_BKM_NEW_BIOS`
