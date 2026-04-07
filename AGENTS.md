# Intel Platform Benchmark Agent

## Overview

Agentic benchmark execution system for Intel platform micro-benchmarks on a **remote lab machine via SSH from your laptop**.
The lab machine requires no GitHub auth, no Copilot installation, and no proxy configuration.

Skills live in `.github/skills/`. Each `SKILL.md` defines exact commands, pass/fail criteria, and baseline values.

**End-to-end agentic flow:**
```
Inputs → Auth → System Config → Intent → Session Check → Confirm → Preflight → EMON Start → Benchmarks → EMON Stop → Collect → Analyze & Predict → Deep Dive Report → Commit
```

> **Every benchmark session MUST produce a `deep_dive_report.md` and `tuning_recommendations.md` before the run is considered complete. These are not optional — see Phase 9a.**

---

## Phase 0: Required Inputs

Collect all required inputs from the user **before** proceeding to auth.
Ask for any missing values — do not assume defaults for host, user, or artifact directory.

| Input | Variable | Required | Default | Example |
|---|---|---|---|---|
| Remote host IP or hostname | `TARGET_HOST` | ✅ Yes | — | `10.1.225.221` |
| Remote username | `TARGET_USER` | ✅ Yes | — | `root` |
| SSH alias (for `~/.ssh/config`) | `TARGET_ALIAS` | No | `lab-target` | `lab-target` |
| SSH identity file path | `IDENTITY_FILE` | No | — | `~/.ssh/id_ed25519` |
| Jump / bastion host | `JUMP_HOST` | No | — | `bastion.corp.com` |
| **Remote artifact directory** | `REMOTE_ARTIFACT_DIR` | ✅ Yes | — | `/data/benchmarks` |
| Benchmark intent | `USER_INTENT` | ✅ Yes | — | `HFT workload validation` |

**Prompt template** (ask once, upfront):
> *"Before we start, I need a few details:*
> *1. Remote server IP/hostname?*
> *2. Username on that server?*
> *3. Where on the remote server should benchmark artifacts be stored?*
>    *(e.g. `/data/benchmarks`, `/scratch/results` — must have write access)*
> *4. What would you like to benchmark? (workload type / goal)*"

`REMOTE_ARTIFACT_DIR` is the **root** directory on the remote machine for all benchmark output.
All session data is written to `${REMOTE_ARTIFACT_DIR}/${SESSION_ID}/` on the remote host.

---

## Phase 1: Authentication

Invoke the `benchmark-auth` skill. It tries modes in this order — stop at first success:

**Mode A — Existing `~/.ssh/config` entry**
```bash
grep -q "${TARGET_ALIAS}\|${TARGET_HOST}" ~/.ssh/config \
  && ssh -o BatchMode=yes -o ConnectTimeout=10 ${TARGET_ALIAS} "echo SSH_OK"
```

**Mode B — Identity file provided by user**
```bash
ssh -o BatchMode=yes -i ${IDENTITY_FILE} ${TARGET_USER}@${TARGET_HOST} "echo SSH_OK"
# Write ~/.ssh/config entry for this session alias on success
```

**Mode C — Key exchange (one-time, passwordless setup)**
```bash
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
ssh-keyscan -H ${TARGET_HOST} >> ~/.ssh/known_hosts
[ -n "${JUMP_HOST}" ] && ssh-keyscan -H ${JUMP_HOST} >> ~/.ssh/known_hosts
PROXY_OPT=$([ -n "${JUMP_HOST}" ] && echo "-o ProxyJump=${JUMP_HOST}")
ssh-copy-id -i ~/.ssh/id_ed25519.pub ${PROXY_OPT} ${TARGET_USER}@${TARGET_HOST}
# Write ~/.ssh/config entry then verify
```

**Mode D — Password per session (fallback — never written to disk)**
```bash
export SSHPASS="${SESSION_PASSWORD}"        # env var only
sshpass -e ssh -o StrictHostKeyChecking=accept-new ${TARGET_USER}@${TARGET_HOST} "echo SSH_OK"
# All subsequent SSH/SCP commands wrapped with: sshpass -e
```

**Verification (all modes)**
```bash
ssh ${LAB_HOST} "echo SSH_OK && uname -r && nproc && whoami"
```
- Returns `SSH_OK` → export `LAB_HOST`, proceed to Phase 2.
- Fails → report the error, do not continue.

---

## Phase 2: System Configuration Collection

**Always run before benchmarks.** Invoke `benchmark-system-config` skill:

```bash
/benchmark-system-config
```

Collects: CPU model/microcode/topology, NUMA layout, C-states, governor, turbo state,
memory DIMM config, THP, HugePages, BIOS/firmware version, kernel cmdline, IRQ balance, power profile.

Exports:
- `PLATFORM_ID` — 12-char hash of CPU model + core count (used for session deduplication)
- `SYSCONFIG_JSON` — path to `./results/${SESSION_ID}/sysconfig.json`

---

## Phase 3: Intent Analysis & Session Management

### 3a — Parse User Intent

Translate natural language to a benchmark set:

| User says… | Benchmark set | EMON workload type |
|---|---|---|
| "run preflight" / "check platform is ready" | `preflight` | — |
| "test CPU" / "validate compute node" / "web server sizing" | `preflight → cpu` | `cpu` |
| "test memory" / "check DRAM" / "DB tier sizing" | `preflight → memory` | `memory` |
| "3-tier workload" / "web/app/db" / "banking application" | `preflight → cpu + memory` | `mixed` |
| "AI inference" / "LLM serving" / "deep learning" / "GenAI" | `preflight → amx + memory` | `ai` |
| "real-time" / "low-latency trading" / "financial systems" | `preflight → wakeup + cpu` | `cpu` |
| "full validation" / "characterize the platform" / "all benchmarks" | `preflight → cpu → memory → amx → wakeup` | `mixed` |
| "how fast is this box?" | `preflight → cpu + memory` | `mixed` |

If intent is ambiguous → ask the user **one** clarifying question before proceeding.

### 3b — Session Check

Invoke `benchmark-session` skill to check for an existing matching run:

```bash
/benchmark-session check --intent "${USER_INTENT}" --platform "${PLATFORM_ID}"
```

- **Match found**: show summary of existing session (date, benchmarks run, top results), then ask:
  > *"Found a previous run matching this intent on [date]. Reuse it / Modify / Start fresh?"*
- **No match**: show the proposed benchmark set and ask:
  > *"I'll run: [benchmark list]. Confirm to proceed."*

**Always confirm with user before executing any benchmark.**

---

## Phase 4: Platform Discovery

Run once per session, after auth and session confirmation:

```bash
NPROC=$(ssh $LAB_HOST "nproc --all")
WORK_DIR=$(ssh $LAB_HOST "echo \$HOME")
MLC_PATH=$(ssh $LAB_HOST "ls /root/mlc 2>/dev/null || echo /root/mlc")
KERNEL=$(ssh $LAB_HOST "uname -r")
SESSION_ID="$(date +%Y%m%dT%H%M%S)-${PLATFORM_ID}"

# REMOTE_ARTIFACT_DIR was collected in Phase 0 from the user.
# All benchmark output on the remote machine lives under this path.
OUTPUT_DIR="${REMOTE_ARTIFACT_DIR}/${SESSION_ID}"
ssh $LAB_HOST "mkdir -p ${OUTPUT_DIR}/bench ${OUTPUT_DIR}/emon ${OUTPUT_DIR}/sysconfig"

# Local mirror for analysis and git commit
mkdir -p ./results/${SESSION_ID}/{bench,emon,sysconfig}
```

Export all as environment variables — every skill invocation depends on them.

> **Note:** If `REMOTE_ARTIFACT_DIR` was not provided in Phase 0, stop and ask:
> *"Where on the remote server should I store benchmark artifacts?
> (e.g. `/data/benchmarks` — needs write access and sufficient free space)"*
> Do not fall back to `/tmp` silently — tmp may be too small for long runs (40+ min benchmarks produce GB of EMON data).

---

## Phase 5: Preflight Gate

**Always run first. If FAIL → stop immediately. Do not proceed to benchmarks.**

```bash
/benchmark-preflight
```

- NUMA check PASS **and** C-state check PASS → proceed to Phase 6.
- Any FAIL → report findings, suggest fixes, halt.

---

## Phase 6: EMON Monitoring Setup

Start background telemetry before any benchmark begins:

```bash
/benchmark-emon start --workload "${WORKLOAD_TYPE}"
```

- `WORKLOAD_TYPE` derived from Phase 3a intent mapping: `cpu` | `memory` | `ai` | `mixed`
- Detects Intel EMON (`emon` binary) or falls back to Linux `perf stat`
- Selects PMU events appropriate to the workload type
- Launches collection in background on remote machine; records `$EMON_PID`

---

## Phase 7: Remote Benchmark Execution

### Short benchmarks (< 60 seconds)
```bash
ssh $LAB_HOST "sudo <command>" | tee ./results/${SESSION_ID}/<benchmark>.log
```

### Long benchmarks (≥ 60 seconds — memory-latency-bw ~40 min, wakeup ~35 min)
```bash
ssh $LAB_HOST "tmux new-session -d -s bench-${SKILL_NAME} '<full command>'"
while ssh $LAB_HOST "tmux has-session -t bench-${SKILL_NAME} 2>/dev/null"; do
    echo "--- still running ---"
    ssh $LAB_HOST "tmux capture-pane -pt bench-${SKILL_NAME} -S -10" | tail -5
    sleep 30
done
echo "Benchmark complete."
```

### Reconnect guard
Before re-running any long benchmark:
```bash
ssh $LAB_HOST "tmux ls 2>/dev/null"
```
If session `bench-<skill>` exists → attach and check progress before re-launching.

### Execution order (sequential — never parallel, same hardware)
`preflight` → `cpu` → `memory` → `amx` → `wakeup`

On any individual benchmark failure: log it, continue to next.

---

## Phase 8: Data Collection

**Stop EMON first, then retrieve all data:**

```bash
/benchmark-emon stop
mkdir -p ./results/${SESSION_ID}/{bench,emon,sysconfig}
scp -r ${LAB_HOST}:${OUTPUT_DIR}/       ./results/${SESSION_ID}/bench/
scp -r ${LAB_HOST}:${EMON_OUTPUT_DIR}/  ./results/${SESSION_ID}/emon/
```

`sysconfig.json` was already written locally in Phase 2.

**Save session record:**
```bash
/benchmark-session save \
  --session-id   "${SESSION_ID}" \
  --intent       "${USER_INTENT}" \
  --platform     "${PLATFORM_ID}" \
  --benchmarks   "${BENCHMARK_SET}"
```

---

## Phase 9: Analysis, Bottleneck Detection & Predictions

```bash
/benchmark-analyze --session-id "${SESSION_ID}"
```

The analysis skill:
1. Parses benchmark result logs from `./results/${SESSION_ID}/bench/`
2. Parses EMON telemetry from `./results/${SESSION_ID}/emon/`
3. Cross-references `sysconfig.json` to explain *why* a bottleneck exists
4. Identifies bottlenecks per domain (CPU / Memory / AI / Latency)
5. Generates tuning recommendations with **quantified predicted improvement ranges**
6. Assigns confidence levels (High / Medium / Low) based on Intel platform validation data
7. Maps all findings to the **user's original stated intent**

**Report structure (`report.md`):**
```
BENCHMARK INSIGHTS — <User Intent>
====================================
Target  : <user>@<host>  (<CPU model>, <N>C, <OS>)
Intent  : <original stated goal>
Session : <session-id>

RESULTS SUMMARY
---------------
Preflight       : PASS/FAIL — <details>
<Benchmark N>   : PASS/FAIL — <value> (threshold: <T>, baseline: <B>, delta: ±X%)

EMON SIGNALS
------------
IPC             : <value>  (healthy: >1.5 for CPU workloads)
LLC Miss Rate   : <value>% (elevated: >5% indicates memory pressure)
<event>         : <value>  <interpretation>

BOTTLENECKS DETECTED
--------------------
[B1] <domain>: <observed> vs <expected> (+X% over threshold)
     EMON confirms: <event>=<value> → <root cause>
     Sysconfig: <relevant setting that contributes>

TUNING RECOMMENDATIONS & PREDICTIONS
--------------------------------------
[T1] Action     : <specific tuning command / BIOS setting>
     Metric     : <which KPI improves>
     Predicted  : <X%–Y%> improvement → estimated <new value>
     Confidence : High / Medium / Low
     Basis      : <Intel platform validation reference>

Overall Verdict : PASS/FAIL — <workload-specific assessment>
```

---

## Phase 9a: Deep Dive Analysis & Tuning Recommendations ⚠️ MANDATORY

**This phase is required for every benchmark session. Do not commit results or mark the session complete until both files are written.**

After generating `report.md`, produce two artefacts saved locally under `./results/${SESSION_ID}/`:

### 9a-1 — Deep Dive Report (`deep_dive_report.md`)

For every metric that is measured, produce a section with:
- **Raw data table** — all recorded values across intervals/samples
- **Reference comparison** — measured vs published Intel platform baseline
- **Root cause chain** — step-by-step signal chain explaining *why* the gap exists
  (e.g. working set > L3 → TLB pressure → DRAM amplification → observed latency)
- **Cross-domain correlation** — link EMON signals to benchmark results
  (e.g. 40% L3 miss rate confirms memory-latency bottleneck observed in multichase)
- **Topology analysis** — for C2C, show full matrix with per-tier classification
  (HT sibling / intra-node / cross-NUMA / cross-socket) with HFT/workload verdict per tier
- **Advisory notes** — any sub-threshold finding that could become a problem at scale

Structure per benchmark domain — include every section for which data exists:

```
## 1. Platform Summary
   Table: CPU model/CPUID/microcode, sockets, cores, NUMA topology, base/turbo freq,
          TDP, C-states with exit latencies, cpufreq governor, HWP/EPB state, kernel.

## 2. CPU Frequency & Power
   Raw data table (all turbostat intervals: Avg_MHz, Busy%, Bzy_MHz, IPC,
                   SMI, Pkg_W, RAM_W, CoreTmp)
   Key observations: achieved frequency vs ceiling, IPC health, thermal headroom,
                     SMI=0 confirmation, C-state residency during test, HWP state.
   Advisories: uncore frequency, EPB setting, flat vs stepped turbo curve.

## 3. Core-to-Core Latency
   Full latency matrix (all measured core pairs, ns ± jitter) — formatted table.
   Tier classification table: HT sibling / intra-node / cross-NUMA intra-socket /
                               cross-socket, with latency range and HFT verdict per tier.
   Root cause of cross-socket penalty (UPI signal chain, wire latency breakdown).
   Asymmetry analysis (mesh-stop distance effects — min vs max to UPI egress port).
   SNC topology impact (how cluster count inflates intra-socket cross-cluster latency).

## 4. Memory Subsystem  (include if memory benchmark was run)
   Latency curve table: all working set sizes and measured latency.
   Why latency climbs with working set: TLB pressure, row-buffer misses, NUMA spill.
   EMON corroboration: LLC miss rate → DRAM pressure confirmation.
   Reference gap analysis (measured vs Intel published DRAM baseline).

## 5. Wakeup Latency  (include if wakeup benchmark was run)
   Full percentile table: min / P50 / avg / P99 / P99.9 / P99.99 / P99.999 / max.
   Additional fields: IntrLatency, WakeLatencyRaw, LDist, SMI count, NMI count,
                      CC0% / CC1% / CC6% residency, datapoint count, duration.
   Distribution interpretation: bimodal shape, C1 fast path vs C6P tail.
   Pre-wake mechanism effect: WakeLatencyRaw avg vs WakeLatency avg delta, meaning.
   HFT stall risk: worst-case latency ÷ typical polling interval = stall multiplier.
   Root cause: which C-state drives the tail (identify from CC% residency + latency spec).

## 6. EMON Telemetry
   Aggregated stats table (avg / min / max across all intervals):
     IPC, LLC miss rate (misses/loads), L3 miss rate (cache-misses/cache-refs),
     L1d miss count, branch miss %, context switches/sec, CPU migrations/sec.
   IPC interpretation: system-wide near-idle context vs single-thread benchmark context.
   Cache pressure signals: LLC miss rate threshold (>15% = elevated), L3 miss rate.
   OS noise signals: context switches/sec target < 3,000 for HFT; migration rate.

## 7. Bottleneck Summary
   Severity-graded table of ALL findings — include PASS items too:
     ID | Severity (🔴 CRITICAL / 🟡 HIGH / 🟢 PASS) | Metric | Finding

## 8. Deep Analysis: Cross-Domain Correlations
   For each CRITICAL or HIGH bottleneck, a signal chain block showing:
     Root signal → Amplifier 1 → Amplifier 2 → ... → Observed value
   Predicted breakdown: baseline value + each amplifier's contribution = observed.

## 9. Tuning Recommendations  (one sub-section per CRITICAL/HIGH/ADVISORY finding)
   For each recommendation:
     - Severity tag: [🔴 CRITICAL | 🟡 HIGH | 🟢 MEDIUM]
     - Exact bash commands to apply the fix (copy-paste ready)
     - Verification command to confirm the fix took effect
     - Table: Action | Expected metric | % reduction | Confidence
     - Power/resource cost (if applicable)

## 10. Priority Action Plan
    Table: Priority | Action (REC-N name) | Target Metric | Predicted Gain |
           Effort (Low/Medium/High) | Requires Reboot (Yes/No)
    Implementation phases:
      PHASE 1 — Immediate (no reboot, < 15 min): commands + expected gain per fix
      PHASE 2 — Next maintenance window (reboot required): kernel/GRUB changes
      PHASE 3 — Platform owner coordination: BIOS/firmware changes

## 11. Cumulative Post-Tuning Projections
    Table: Metric | Current | After Phase 1 | After Phase 1+2+3 | HFT/Workload Target
    End-to-end workload latency/throughput estimate after all fixes applied.

## 12. Summary Scorecard  (mandatory — use exact format from scorecard spec below)

## 13. Raw Data Files
    Table listing every file under ./results/${SESSION_ID}/ with a one-line description.
```

### 9a-2 — Tuning Recommendations (`tuning_recommendations.md`)

For every metric that **FAIL**s or is marked **ADVISORY** in the scorecard, produce a dedicated section:

```
## REC-N — <Metric Name> [❌ CRITICAL | ⚠️ ADVISORY | ❌ HIGH]

### Assessment
  Measured: <value> | Reference: <value> | Gap: <+X%>
  2–3 sentence explanation of what this means for the target workload.

### Root Cause
  Ordered list of contributing factors (most impactful first).

### Fix
  Exact bash commands to apply the fix on the target system.
  Include verification command to confirm fix took effect.

### Expected Improvement
  Table: Action → Expected metric value → % reduction → Confidence level

### End-to-End Workload Impact
  Amdahl's Law estimate: what % of the workload is affected,
  predicted overall latency/throughput improvement.
```

End the file with:
```
## Combined Implementation Sequence
  PHASE 1 — Immediate (no reboot): list of quick fixes + expected gains
  PHASE 2 — Next maintenance window (reboot required): kernel/GRUB changes
  PHASE 3 — Platform owner coordination: BIOS/firmware changes

## Predicted Outcomes After Full Tuning
  Table: Metric | Current | After Phase 1 | After Phase 2+3 | Target | Met?
  Summary: projected end-to-end latency/throughput range after all fixes.
```

### Scorecard format (used in both files)

Every report must include this exact scorecard table for the workload:

```
BENCHMARK        MEASURED      REFERENCE     GAP        STATUS
───────────────────────────────────────────────────────────────
<metric>         <value>       <ref>         <±X%>      ✅ PASS / ❌ CRITICAL / ⚠️ ADVISORY
...
───────────────────────────────────────────────────────────────
VERDICT: PASS / CONDITIONAL / FAIL — <one-line summary>
         <list of blocking items if CONDITIONAL or FAIL>
```

Status codes:
- `✅ PASS` — within threshold
- `⚠️ ADVISORY` — within threshold but warrants monitoring or has HFT-specific concern
- `❌ HIGH` — exceeds threshold, impacts performance
- `❌ CRITICAL` — exceeds threshold, directly blocks workload readiness

---

## Phase 10: Save Results Locally — Do NOT Commit Results

After analysis and deep dive report are complete, all session artifacts are stored **locally only**.

**What stays local (never commit):**
- `./results/${SESSION_ID}/` — all benchmark output, logs, CSVs, reports
- `./sessions/` — session metadata YML files
- Both directories are in `.gitignore`. Never use `git add -f` to force-add them.

**What IS committed (after deep dive report is written):**
- `AGENTS.md` — when agent instructions are updated
- `.github/skills/*.md` — when skills are updated
- Any other source/config files in the repo root

**Commit message format for code changes:**
```
type(scope): short description

Details of what changed and why.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
```

**Verification before commit:**
```bash
git --no-pager status --short   # must show NO files under results/ or sessions/
git --no-pager diff --cached    # review staged changes — confirm no result data
```

---

## Safety Rules

- **Never reboot** the lab machine.
- **Never run benchmarks in parallel** — single machine, shared hardware.
- **Never kill a tmux session** without first checking if a benchmark is mid-run.
- **Always run preflight** — if preflight FAILS, do not proceed.
- **Always confirm benchmark set with user** before executing (reuse or new).
- **Use `dnf`** for CentOS/RHEL, **`apt-get`** for Ubuntu/Debian — detect OS from `sysconfig.json`.
- **Do not hardcode core counts** — always use `$NPROC` discovered at runtime.
- **Do not hardcode paths** — always use `$WORK_DIR` and `$REMOTE_ARTIFACT_DIR` discovered at runtime.
- **Never store passwords on disk** — use `SSHPASS` env var only, cleared after session.
- **Always ask for `REMOTE_ARTIFACT_DIR`** in Phase 0 — never silently default to `/tmp`.

---

## Known Platform Quirks (DMR)

- **Single NUMA node is CORRECT** for DMR — not a failure. GNR had 6 nodes (SNC3).
- **TSC stops in C6 substates** (C6A/C6S/C6SP) — never measure idle cores with turbostat (causes exit 253).
- **DMR C6 exit latencies** (50/70/110 µs) differ from GNR (170/210 µs) — expected.
- **Max frequency BKC for DMR is ~2799 MHz** — if 2700–2900 MHz, report "Expected", not FAIL.
  The SKILL.md threshold of ≥3600 MHz is the formal pass criterion; note the BKC context in the report.
