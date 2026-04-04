# Intel Platform Benchmark Agent

## Overview

This repo contains skills for running Intel platform micro-benchmarks.

**All benchmark commands execute on a remote lab machine via SSH from your laptop.**
The lab machine requires no GitHub auth, no Copilot installation, and no proxy configuration.

Skills live in `.github/skills/`. Each `SKILL.md` defines the exact commands, pass/fail
criteria, and GNR baseline values for one benchmark area.

---

## Phase 1: SSH Setup (one-time prerequisite)

Triggered when the user says something like:
> *"setup SSH to 10.20.30.40 as user benchuser"*
> *"setup a passwordless environment on lab-machine via jump server bastion.corp.com"*

```bash
# 1. Generate key if missing
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""

# 2. Pre-accept host fingerprints (avoids interactive yes/no prompt)
ssh-keyscan -H $TARGET_HOST >> ~/.ssh/known_hosts
[ -n "$JUMP_HOST" ] && ssh-keyscan -H $JUMP_HOST >> ~/.ssh/known_hosts

# 3. Copy public key to target — user enters password ONCE here
PROXY_OPT=""
[ -n "$JUMP_HOST" ] && PROXY_OPT="-o ProxyJump=$JUMP_HOST"
ssh-copy-id -i ~/.ssh/id_ed25519.pub $PROXY_OPT ${TARGET_USER}@${TARGET_HOST}

# 4. Write ~/.ssh/config entry
cat >> ~/.ssh/config << EOF

Host ${TARGET_ALIAS}
  HostName ${TARGET_HOST}
  User ${TARGET_USER}
  IdentityFile ~/.ssh/id_ed25519
  $([ -n "$JUMP_HOST" ] && echo "ProxyJump ${JUMP_HOST}")
  ServerAliveInterval 60
  ServerAliveCountMax 10
EOF

# 5. Verify
ssh -o BatchMode=yes ${TARGET_ALIAS} "echo SSH_OK && uname -r && nproc"
```

- If the verify step returns `SSH_OK`: report success and proceed.
- If it fails: report the error, do not continue to benchmarks.
- After this one-time setup the agent operates fully unattended.

---

## Phase 2: Understanding User Intent

Translate freeform natural language to the right benchmark skills.
**Always run `benchmark-preflight` first, before any other skill.**

| User says... | Skills to run (in order) |
|---|---|
| "run preflight" / "check the platform is ready" | `benchmark-preflight` |
| "test CPU" / "validate compute node" / "web server sizing" | `benchmark-preflight` → `benchmark-cpu` |
| "test memory" / "check DRAM" / "DB tier sizing" | `benchmark-preflight` → `benchmark-memory` |
| "3-tier workload" / "web/app/db" / "banking application" | `benchmark-preflight` → `benchmark-cpu` + `benchmark-memory` |
| "AI inference" / "LLM serving" / "deep learning" / "GenAI" | `benchmark-preflight` → `benchmark-amx` + `benchmark-memory` |
| "real-time" / "low-latency trading" / "financial systems" | `benchmark-preflight` → `benchmark-wakeup` + `benchmark-cpu` |
| "full validation" / "all benchmarks" / "characterize the platform" | `benchmark-preflight` → `benchmark-cpu` → `benchmark-memory` → `benchmark-amx` → `benchmark-wakeup` |
| "how fast is this box?" | `benchmark-preflight` → `benchmark-cpu` + `benchmark-memory` |

If the intent is ambiguous, ask the user one clarifying question before proceeding.

---

## Phase 3: Platform Discovery

Run once at the start of each benchmark session, before invoking any skill:

```bash
NPROC=$(ssh $LAB_HOST "nproc --all")
WORK_DIR=$(ssh $LAB_HOST "echo \$HOME")
MLC_PATH=$(ssh $LAB_HOST "ls /root/mlc 2>/dev/null || echo /root/mlc")
KERNEL=$(ssh $LAB_HOST "uname -r")
OUTPUT_DIR="/tmp/benchmarks/$(date +%Y-%m-%dT%H-%M-%S)"
ssh $LAB_HOST "mkdir -p $OUTPUT_DIR"
```

Export these as environment variables — all skill invocations depend on them.
Pass them explicitly when wrapping skill commands for remote execution.

---

## Phase 4: Remote Execution Pattern

### Short benchmarks (< 60 seconds)
```bash
ssh $LAB_HOST "sudo <command>" | tee ./results/<benchmark>.log
```

### Long benchmarks (≥ 60 seconds — memory-latency-bw ~40 min, wakeup ~35 min)
```bash
# Launch in tmux — survives SSH disconnections
ssh $LAB_HOST "tmux new-session -d -s bench-$SKILL_NAME '<full command>'"

# Poll every 30s, show tail of output
while ssh $LAB_HOST "tmux has-session -t bench-$SKILL_NAME 2>/dev/null"; do
    echo "--- still running ---"
    ssh $LAB_HOST "tmux capture-pane -pt bench-$SKILL_NAME -S -10" | tail -5
    sleep 30
done
echo "Benchmark complete."
```

### Collecting results
```bash
mkdir -p ./results
scp -r $LAB_HOST:$OUTPUT_DIR/ ./results/
```

### Reconnecting to an interrupted benchmark
Before re-running any long benchmark, check for an existing tmux session:
```bash
ssh $LAB_HOST "tmux ls 2>/dev/null"
```
If a session named `bench-<skill>` exists, attach and check progress before re-launching.

---

## Phase 5: Execution Order

1. **Always run preflight first** — if NUMA or C-state check FAILS, stop and report. Do not proceed.
2. Run skills sequentially — never in parallel (same hardware):
   `preflight` → `cpu` → `memory` → `amx` → `wakeup`
3. On any benchmark failure: log it, continue to the next benchmark.
4. Collect all results via `scp` before beginning analysis.

---

## Phase 6: Local Analysis and Reporting

After `scp`, parse `./results/` locally and generate a report that:

1. Maps results back to the **user's original stated intent** — not just raw numbers.
2. Shows `PASS` / `FAIL` per benchmark with delta vs GNR baseline.
3. Gives a workload-specific verdict (e.g., *"Suitable for DB-tier in a banking workload"*).
4. Flags unexpected platform behavior (NUMA topology, C-state driver, frequency anomalies).

**Example report structure for a "3-tier banking workload" request:**
```
BENCHMARK INSIGHTS — 3-Tier Banking Workload
=============================================
Target:  benchuser@10.20.30.40  (Intel DMR, 32C, CentOS Stream 10)
Intent:  Validate platform for 3-tier web/app/DB banking application

Preflight    : PASS  — 1 NUMA node, intel_idle driver, C6A/C6S/C6SP states present
CPU (App Tier): PASS  — Max freq 2799 MHz (DMR BKC expected), turbo curve monotonic
Memory (DB Tier): PASS  — Latency 121 ns (≤139 ns), BW 1510 GB/s (≥1454 GB/s)

Overall Verdict: PASS — Platform is suitable for 3-tier banking deployment.
```

---

## Safety Rules

- **Never reboot** the lab machine.
- **Never run benchmarks in parallel** — single machine, shared hardware.
- **Never kill a tmux session** without first checking if a benchmark is mid-run.
- **Always run preflight** — if preflight FAILS, do not proceed to other benchmarks.
- **Use `dnf`**, not `apt-get` — remote OS is CentOS Stream 10.
- **Do not hardcode core counts** — always use `$NPROC` discovered at runtime.
- **Do not hardcode paths** — always use `$WORK_DIR` discovered at runtime.

---

## Known Platform Quirks (DMR)

- **Single NUMA node is CORRECT** for DMR — not a failure. GNR had 6 nodes (SNC3).
- **TSC stops in C6 substates** (C6A/C6S/C6SP) — never measure idle cores with turbostat (causes exit 253).
- **DMR C6 exit latencies** (50/70/110 µs) differ from GNR (170/210 µs) — this is expected.
- **Max frequency BKC for DMR is ~2799 MHz** — if result is 2700–2900 MHz, report as "Expected", not FAIL.
  The SKILL.md threshold of ≥3600 MHz is the formal pass criterion; note the BKC context in the report.
