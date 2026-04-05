---
name: run-benchmark
description: "Run Intel DMR platform benchmarks. Use when: running benchmarks, measuring performance, validating platform, checking frequency, memory latency, memory bandwidth, AMX throughput, wakeup latency, core-to-core latency, turbo curve, NUMA, C-states, preflight checks, 3-tier workload sizing, app server validation, database server sizing, AI inference readiness, platform acceptance testing, full system characterization, benchmarking a new server. Invoke with a benchmark name or 'all'."
argument-hint: "[benchmark-name|all|preflight]"
disable-model-invocation: false
allowed-tools: Bash
---

# DMR Benchmark Runner

**Platform:** Intel Diamond Rapids (DMR), 1S×32C×1T, 30GB RAM, CentOS Stream 10
**Output dir:** `/tmp/benchmarks/<timestamp>/`

---

## Full Agentic Execution Flow

Run this complete sequence for every benchmark request.
Each step invokes the corresponding skill — do not skip steps.

```
1. benchmark-auth          ← establish SSH (key / identity file / password)
2. benchmark-system-config ← collect CPU, memory, BIOS, OS, power state
3. benchmark-session check ← find existing run or build new set; confirm with user
4. Platform Discovery      ← NPROC, WORK_DIR, MLC_PATH, OUTPUT_DIR, SESSION_ID
5. benchmark-preflight     ← NUMA + C-state gate (FAIL = stop)
6. benchmark-emon start    ← begin PMU telemetry collection
7. benchmark-<name>        ← run the requested benchmark(s)
8. benchmark-emon stop     ← stop telemetry, retrieve data
9. scp results locally     ← bench/ + emon/ → ./results/<session-id>/
10. benchmark-session save ← persist session record
11. benchmark-analyze      ← bottleneck detection + tuning predictions
```

---

## Quick Reference

| `$ARGUMENTS` | What it runs |
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

---

## Variables

| Variable | Source | Example |
|---|---|---|
| `$LAB_HOST` | benchmark-auth | `lab-target` |
| `$SSH_CMD` | benchmark-auth | `ssh` or `sshpass -e ssh` |
| `$SCP_CMD` | benchmark-auth | `scp` or `sshpass -e scp` |
| `$PLATFORM_ID` | benchmark-system-config | `a3f9c1d2e4f5` |
| `$SYSCONFIG_JSON` | benchmark-system-config | `./results/<id>/sysconfig.json` |
| `$SESSION_ID` | Phase 4 discovery | `20260405T120000-a3f9c1` |
| `$OUTPUT_DIR` | Phase 4 discovery | `/tmp/benchmarks/2026-04-05T12-00-00` |
| `$NPROC` | Phase 4 discovery | `32` |
| `$WORK_DIR` | Phase 4 discovery | `/root` |
| `$MLC_PATH` | Phase 4 discovery | `/root/mlc` |
| `$EMON_OUTPUT_DIR` | benchmark-emon | `/tmp/benchmarks/.../perf` |
| `$WORKLOAD_TYPE` | Derived from intent | `cpu` / `memory` / `ai` / `mixed` |

---

## Step 1 — Authentication

```bash
/benchmark-auth --host <TARGET_HOST> --user <USER> --alias lab-target
# Sets: LAB_HOST, SSH_CMD, SCP_CMD
```

---

## Step 2 — System Configuration

```bash
/benchmark-system-config
# Sets: PLATFORM_ID, SYSCONFIG_JSON
# Saves: ./results/${SESSION_ID}/sysconfig.json
```

---

## Step 3 — Session Check & User Confirmation

```bash
/benchmark-session check --intent "${USER_INTENT}" --platform "${PLATFORM_ID}"
```

Present results to user. Wait for explicit confirmation: **Reuse / Modify / New**.
Do not proceed until user responds.

---

## Step 4 — Platform Discovery

```bash
NPROC=$(${SSH_CMD} $LAB_HOST "nproc --all")
WORK_DIR=$(${SSH_CMD} $LAB_HOST "echo \$HOME")
MLC_PATH=$(${SSH_CMD} $LAB_HOST "ls /root/mlc 2>/dev/null || echo /root/mlc")
KERNEL=$(${SSH_CMD} $LAB_HOST "uname -r")
OUTPUT_DIR="/tmp/benchmarks/$(date +%Y-%m-%dT%H-%M-%S)"
SESSION_ID="$(date +%Y%m%dT%H%M%S)-${PLATFORM_ID}"
${SSH_CMD} $LAB_HOST "mkdir -p $OUTPUT_DIR"
mkdir -p ./results/${SESSION_ID}/{bench,emon}
```

---

## Step 5 — Preflight Gate

```bash
/benchmark-preflight
```

- **PASS** (NUMA=1, driver=intel_idle) → continue.
- **FAIL** → stop, report findings, do not run benchmarks.

---

## Step 6 — Start EMON Monitoring

```bash
/benchmark-emon start --workload "${WORKLOAD_TYPE}"
# Sets: EMON_PID, EMON_OUTPUT_DIR, EMON_TOOL
```

Derive `WORKLOAD_TYPE` from intent:

| Benchmark set | WORKLOAD_TYPE |
|---|---|
| cpu only | `cpu` |
| memory only | `memory` |
| amx / AI | `ai` |
| cpu + memory / mixed | `mixed` |

---

## Step 7 — Run Benchmarks

Dispatch to the appropriate sub-skill based on `$ARGUMENTS`:

| Argument | Sub-skill |
|---|---|
| `preflight` | [preflight procedure](./references/preflight.md) |
| `max-freq` | [CPU benchmarks](./references/cpu-benchmarks.md) |
| `turbo-curve` | [CPU benchmarks](./references/cpu-benchmarks.md) |
| `core-to-core` | [CPU benchmarks](./references/cpu-benchmarks.md) |
| `cpu` | max-freq + turbo-curve + core-to-core (sequential) |
| `memory-latency` | [Memory benchmarks](./references/memory-benchmarks.md) |
| `memory-bandwidth` | [Memory benchmarks](./references/memory-benchmarks.md) |
| `memory-latency-bw` | [Memory benchmarks](./references/memory-benchmarks.md) |
| `memory` | memory-latency + memory-bandwidth |
| `amx` | [AMX benchmark](./references/amx-benchmark.md) |
| `wakeup` | [Wakeup latency](./references/wakeup-benchmark.md) |
| `all` | preflight → cpu → memory → amx → wakeup (sequential) |

If `$ARGUMENTS` is empty, show this table and ask the user which benchmark to run.

Tee all output to `./results/${SESSION_ID}/bench/<name>.log`:
```bash
${SSH_CMD} $LAB_HOST "sudo <command>" | tee ./results/${SESSION_ID}/bench/<name>.log
```

---

## Step 8 — Stop EMON & Collect Data

```bash
/benchmark-emon stop

${SCP_CMD} -r ${LAB_HOST}:${OUTPUT_DIR}/      ./results/${SESSION_ID}/bench/
${SCP_CMD} -r ${LAB_HOST}:${EMON_OUTPUT_DIR}/ ./results/${SESSION_ID}/emon/
```

---

## Step 9 — Save Session

```bash
/benchmark-session save \
  --session-id  "${SESSION_ID}" \
  --intent      "${USER_INTENT}" \
  --platform    "${PLATFORM_ID}" \
  --benchmarks  "${BENCHMARK_SET}"
```

---

## Step 10 — Analyze & Report

```bash
/benchmark-analyze --session-id "${SESSION_ID}"
```

---

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
| AMX BF16 | > 12,600 GFLOPS iso-core | 12.6 TFLOPS (8-core) |
| AMX INT8 | > 22,900 TOPS iso-core | 22.9 TOPS (8-core) |
| Wakeup latency | median ≤ 90 µs, max ≤ 260 µs | 1.59 µs median (wult) |

---

## Important Platform Notes

- **Do NOT measure idle cores with turbostat** — TSC stops in DMR C6 substates, causing exit 253.
- **DMR C-states**: C6A/C6S/C6SP (50/70/110 µs) — different from GNR. This is correct behavior.
- **Single NUMA node**: DMR = 1 node. PASS. GNR had 6 (SNC3).
- **All installs use `dnf`**, not `apt-get` — CentOS Stream 10.

## Additional References
- [Preflight checks](./references/preflight.md)
- [CPU benchmarks](./references/cpu-benchmarks.md)
- [Memory benchmarks](./references/memory-benchmarks.md)
- [AMX benchmark](./references/amx-benchmark.md)
- [Wakeup latency benchmark](./references/wakeup-benchmark.md)
