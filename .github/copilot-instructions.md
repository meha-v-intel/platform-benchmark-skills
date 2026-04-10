# GitHub Copilot Instructions — Intel Platform Benchmark Skills

## What this repo is

A collection of GitHub Copilot **skills** for running Intel Xeon platform micro-benchmarks via SSH on remote Linux systems. Each skill is a `SKILL.md` file under `.github/skills/<skill-name>/` that Copilot reads and executes as Bash on the target host.

There are no build steps, tests, or linters — the "code" is Bash inside Markdown skill files.

---

## Repository structure

```
.github/skills/
├── run-benchmark/          # Orchestrator: dispatches to sub-skills
│   ├── SKILL.md
│   └── references/         # Detailed per-benchmark docs (preflight, cpu, memory, amx, wakeup)
├── benchmark-preflight/    # NUMA + C-state checks
├── benchmark-cpu/          # max-freq, turbo-curve, core-to-core latency
│   └── scripts/turbo_curve_imperia_final.sh   # BKM-provided script, do not modify
├── benchmark-memory/       # DRAM latency (multichase), BW (MLC), lat-BW curve
│   └── scripts/run_mlc_lat_bw.sh              # BKM-provided script, do not modify
├── benchmark-amx/          # AMX BF16 + INT8 throughput via oneDNN benchdnn
├── benchmark-wakeup/       # C6 wakeup latency via Intel wult (TDT backend)
├── benchmark-hft/          # HFT compute (hft_rdtscp) + network (eflatency, sfnt-pingpong)
├── benchmark-hpc-grid/     # Monte Carlo options pricing + IAA/QAT/DSA accelerators
└── fsi-benchmark/          # FSI segment orchestrator (HFT + HPC Grid + platform KPIs)
```

Results land in `results/<timestamp>-<tag>/` after a benchmark run.

---

## Target platform

- **Primary:** Intel Diamond Rapids (DMR), 1S × 32C × 1T, CentOS Stream 10, kernel 6.18.0 BKC
- **Also supported:** GNR-SP, EMR, AMD Turin (auto-detected at runtime via `lscpu`)
- All package installs use **`dnf`**, not `apt-get`

---

## How skills work

Each `SKILL.md` has a YAML front matter block:

```yaml
---
name: benchmark-foo
description: "Trigger keywords for Copilot to load this skill"
argument-hint: "[option-a|option-b]"
allowed-tools: Bash
---
```

Copilot reads the description to decide which skill to invoke. The Bash blocks inside are executed on the remote system. Skills are self-contained — they install missing tools, run the benchmark, parse output, and print a structured pass/fail report.

---

## Critical platform rules (apply to every skill)

1. **Never run turbostat on idle cores.** DMR's C6 substates (C6A/C6S/C6SP) stop the TSC, causing turbostat exit code 253. Always pin a busy-loop to the CPU before measuring with turbostat.

2. **DMR C-states differ from GNR.** DMR has C6A/C6S/C6SP (50/70/110 µs exit latency) vs GNR's C6/C6P (170/210 µs). This is expected behavior — do not treat it as a failure.

3. **SMI > 0 is a hard HFT block.** Any SMI delta during a 60s window must be resolved before HFT benchmarks are valid. Check with `rdmsr -a 0x34`.

4. **Use `wult` (TDT backend), not `cyclictest`**, for C-state wakeup latency. `cyclictest` measures OS scheduling latency, not C-state exit.

5. **HFT network tests require two systems** with Solarflare X2522-25G-PLUS NICs and `$PONG_HOST` set. If absent, skip gracefully with `SKIPPED — topology not available`.

---

## Pass/fail thresholds (DMR)

| Benchmark | Metric | Pass threshold | GNR reference |
|---|---|---|---|
| NUMA check | Node count | == 1 | 6 (SNC3) |
| C-state | cpuidle driver | intel_idle | intel_idle |
| Max frequency | Bzy_MHz | ≥ 3600 MHz | 3300 MHz |
| Core-to-core | Max round-trip | ≤ 180 cycles | 63–71 cycles |
| Memory latency | 2 GiB working set | ≤ 139 ns | 116 ns |
| Memory BW | MLC all-reads | ≥ 1454 GBps | 158 GB/s/socket |
| AMX BF16 | iso-core 8C | > 12.6 TFLOPS | 12.6 TFLOPS |
| AMX INT8 | iso-core 8C | > 22.9 TOPS | 22.9 TOPS |
| Wakeup latency | median | ≤ 90 µs | 1.59 µs |
| Wakeup latency | max | ≤ 260 µs | 10.59 µs |

---

## Run order

Always run preflight before any micro-benchmark:
1. `preflight` — confirms NUMA=1 and C-states are healthy
2. Requested benchmark(s)
3. Report: KPI values, PASS/FAIL, delta vs GNR baseline (sign convention: `+X%` = DMR is better for higher-is-better metrics)

The `run-benchmark all` and `fsi-benchmark all` orchestrators enforce this order automatically.

---

## Reporting conventions

- Use structured headers: `BENCHMARK RESULTS`, `=====` separator lines
- Always include: metric value + unit, pass/fail status, delta vs GNR
- Two-tier tuning response for FSI misses: **Tier 1** = immediate OS/BIOS fix; **Tier 2** = root-cause profiling (run `memory-latency-bw` + `benchmark-amx` to classify miss as memory-bound / compute-bound / compiler-bound)
- Output directory: `/tmp/benchmarks/<timestamp>/` for DMR skills, `/tmp/fsi-benchmarks/<timestamp>-fsi/` for FSI skills

---

## Editing skills

- The `scripts/` directories contain BKM-provided reference scripts — do not modify them; reference them from skill steps instead.
- When updating pass/fail thresholds, update both the `SKILL.md` and the corresponding file in `run-benchmark/references/` if one exists.
- CPU/core counts and NUMA topology are discovered at runtime — do not hardcode them in skill Bash blocks.
- `fsi-benchmark/SKILL.md` dispatches to `benchmark-hft` and `benchmark-hpc-grid`; update all three when adding a new FSI test.
