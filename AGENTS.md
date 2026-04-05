# Intel Platform Benchmark Agent

## Overview

Agentic benchmark execution system for Intel platform micro-benchmarks on a **remote lab machine via SSH from your laptop**.
The lab machine requires no GitHub auth, no Copilot installation, and no proxy configuration.

Skills live in `.github/skills/`. Each `SKILL.md` defines exact commands, pass/fail criteria, and baseline values.

**End-to-end agentic flow:**
```
Auth → System Config → Intent → Session Check → Confirm → Preflight → EMON Start → Benchmarks → EMON Stop → Collect → Analyze & Predict
```

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
OUTPUT_DIR="/tmp/benchmarks/$(date +%Y-%m-%dT%H-%M-%S)"
SESSION_ID="$(date +%Y%m%dT%H%M%S)-${PLATFORM_ID}"
ssh $LAB_HOST "mkdir -p $OUTPUT_DIR"
mkdir -p ./results/${SESSION_ID}
```

Export all as environment variables — every skill invocation depends on them.

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

**Report structure:**
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

## Safety Rules

- **Never reboot** the lab machine.
- **Never run benchmarks in parallel** — single machine, shared hardware.
- **Never kill a tmux session** without first checking if a benchmark is mid-run.
- **Always run preflight** — if preflight FAILS, do not proceed.
- **Always confirm benchmark set with user** before executing (reuse or new).
- **Use `dnf`**, not `apt-get` — remote OS is CentOS Stream 10.
- **Do not hardcode core counts** — always use `$NPROC` discovered at runtime.
- **Do not hardcode paths** — always use `$WORK_DIR` discovered at runtime.
- **Never store passwords on disk** — use `SSHPASS` env var only, cleared after session.

---

## Known Platform Quirks (DMR)

- **Single NUMA node is CORRECT** for DMR — not a failure. GNR had 6 nodes (SNC3).
- **TSC stops in C6 substates** (C6A/C6S/C6SP) — never measure idle cores with turbostat (causes exit 253).
- **DMR C6 exit latencies** (50/70/110 µs) differ from GNR (170/210 µs) — expected.
- **Max frequency BKC for DMR is ~2799 MHz** — if 2700–2900 MHz, report "Expected", not FAIL.
  The SKILL.md threshold of ≥3600 MHz is the formal pass criterion; note the BKC context in the report.
