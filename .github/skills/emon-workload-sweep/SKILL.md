---
name: emon-workload-sweep
description: "Create and run a workload configuration sweep with EMON collection, and use EMON to investigate anomalies and understand system behavior at the hardware level. Use when: collecting EMON traces while running a workload, sweeping workload parameters, debugging unexpected throughput or behavior (e.g. iperf3 anomalies), forming and testing hardware-level hypotheses, profiling CPU performance metrics, generating EDP Excel reports, correlating hardware counters with workload performance, automating multi-config benchmarks with EMON, iteratively building a deep understanding of system bottlenecks."
argument-hint: "[generate|run|postprocess]"
allowed-tools: Bash
---

# EMON Workload Sweep

Teaches Copilot how to build and run an automation script that:
1. Runs a workload under multiple configuration permutations
2. Collects EMON hardware counter data in the background during each run
3. Post-processes each EMON trace into an Excel EDP report via `mpp.py`

**When the user asks to collect EMON under a workload**, use this skill to:
- Ask the user what workload, what dimensions to sweep, and what configs to vary
- Generate a complete sweep script tailored to their workload
- Guide them through running it and post-processing results

---

## Phase 0 — Understand the user's workload

Before generating the script, gather:

1. **Workload binary/command** — what command runs the workload?
2. **Configuration dimensions** — what parameters vary? (e.g. thread count, batch size, input size, precision mode, memory allocation strategy)
3. **Values per dimension** — what are the values to sweep for each?
4. **Baseline config** — when sweeping one dimension, what fixed values are used for the others?
5. **Run repetitions** — how many times should each config run? (default: 3)
6. **EMON paths** — confirm locations of EMON tools and config files (see Phase 1)

---

## Phase 1 — Verify EMON prerequisites

> **DMR-Q9UC live platform notes (sc00901168s0095 / sc00901168s0097):**
> - SEP 5.58 beta installed at `/opt/intel/sep_private_5.58_beta_linux_020402465cf386d3e/`
>   with symlink `/opt/intel/sep → /opt/intel/sep_private_5.58...`
> - `sep_vars.sh` is already added to `~/.bashrc` on both systems — persistent across sessions
> - SEP driver is loaded at boot (via insmod-sep). If missing after reboot:
>   S1 (kernel 6.8.0-107): pre-built .ko present, just `insmod-sep`
>   S2 (kernel 6.8.0-106): pre-built .ko present, just `insmod-sep`
> - DMR EDP files: `diamondrapids_server_events_private.txt`, `diamondrapids_server_private.xml`,
>   `chart_format_diamondrapids_server_private.txt` — all verified present and working
> - pyedp `.venv` (Python 3.12 + numpy/pyarrow/polars) pre-installed in `config/edp/pyedp/.venv/`
> - Smoke test passed on both systems: 5-second collection → 2.3–2.4MB `.dat`, 5000+ lines

> **First-time setup on a new DMR system:**
> 1. Copy SEP from an existing system: `ssh s1 'tar cf - -C /opt/intel sep_private_5.58_...'  | ssh s2 'tar xf - -C /opt/intel'`
>    (Note: `/opt/intel/sep` is a symlink — also copy the real directory name, not just the symlink)
> 2. Run `/opt/intel/sep/sepdk/src/insmod-sep` to load the pre-built driver
>    — if kernel version mismatch: `cd /opt/intel/sep/sepdk/src && ./build-driver --non-interactive`
>    (without `--non-interactive` it blocks waiting for user input)
> 3. `source /opt/intel/sep/sep_vars.sh` (add to `~/.bashrc` for persistence)

### 1a. Source SEP environment
```bash
source /opt/intel/sep/sep_vars.sh
```
This sets `emon` in PATH and exports `SEP_BASE_DIR`.

### 1b. Confirm required files
```bash
# Verify emon binary
which emon && emon -version

# EDP config files — paths vary by platform
EDP_EVENTS="/opt/intel/sep/config/edp/<platform>_server_events_private.txt"
EDP_METRIC="/opt/intel/sep/config/edp/<platform>_server_private.xml"
EDP_FORMAT="/opt/intel/sep/config/edp/chart_format_<platform>_server_private.txt"
MPP_PY="/opt/intel/sep/config/edp/pyedp/mpp.py"

ls -la "$EDP_EVENTS" "$EDP_METRIC" "$EDP_FORMAT" "$MPP_PY"
```

Replace `<platform>` with the actual CPU codename, e.g. `diamondrapids`, `sapphirerapids`, `graniterapids`.

Discover the correct platform name:
```bash
ls /opt/intel/sep/config/edp/*.txt | grep events | head -5
```

### 1c. Load SEP driver
```bash
# Check if already loaded
lsmod | grep sep

# Load if not present
/opt/intel/sep/sepdk/src/insmod-sep

# Verify
lsmod | grep sep
```

---

## Phase 2 — Directory structure

Every sweep creates a timestamped results directory:

```
<RESULTS_DIR>/
├── emon_data/          # .dat raw EMON files + emon console logs
├── workload_logs/      # stdout/stderr from each workload run
├── postprocess/        # .xlsx EDP reports + mpp.py logs
└── summary/            # human-readable sweep summary
```

```bash
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="/root/<workload_name>_emon_sweep_${TIMESTAMP}"
mkdir -p "$RESULTS_DIR"/{emon_data,workload_logs,postprocess,summary}
```

---

## Phase 3 — The run_config pattern (core methodology)

Every configuration follows this exact sequence:

### Step 1: Start EMON in background
```bash
# Use -f flag to write raw data directly to .dat file
# Capture EMON console output separately in _emon.log
emon -collect-edp edp_file="$EDP_EVENTS" -f "$dat_file" > "$emon_log" 2>&1 &
EMON_PID=$!

# Wait for EMON to initialize (5s is reliable)
sleep 5

# Verify EMON started successfully
if ! kill -0 $EMON_PID 2>/dev/null; then
    echo "EMON failed to start"
    cat "$emon_log"
    return 1
fi
```

**Critical**: Use `-f <dat_file>` (not `> redirect`) for the raw data. The `-f` flag ensures only pure EMON samples go to the .dat file. Redirecting stdout also captures EMON header/status text which corrupts the .dat.

### Step 2: Run the workload
```bash
# Run workload — capture all output to log file
<YOUR_WORKLOAD_COMMAND> \
    [config parameters] \
    > "$workload_log" 2>&1
WORKLOAD_EXIT=$?
```

The workload runs in the **foreground**. EMON collects in the **background** during this time. The EMON trace covers the entire workload execution window.

### Step 3: Stop EMON
```bash
emon -stop >> "$emon_log" 2>&1
wait $EMON_PID 2>/dev/null || true
sleep 2   # allow final flush to .dat
```

Always stop EMON **after** the workload completes. Never kill the EMON PID directly — use `emon -stop` to ensure clean sample termination and proper .dat file closure.

### Step 4: Validate the .dat file
```bash
if [ ! -f "$dat_file" ] || [ ! -s "$dat_file" ]; then
    echo "DAT file missing or empty — EMON did not collect data"
    return 1
fi
echo "DAT: $(wc -l < "$dat_file") lines, $(du -h "$dat_file" | cut -f1)"
```

### Step 5: Post-process with mpp.py
```bash
python3 "$MPP_PY" \
    -i  "$dat_file" \
    -m  "$EDP_METRIC" \
    -f  "$EDP_FORMAT" \
    -o  "$xlsx_file" \
    --socket-view \
    --core-view \
    --thread-view \
    --uncore-view \
    -p  8 \
    > "$mpp_log" 2>&1

# Validate the Excel output is a valid ZIP/xlsx
if [ -f "$xlsx_file" ] && unzip -t "$xlsx_file" >/dev/null 2>&1; then
    echo "Excel: $(du -h "$xlsx_file" | cut -f1) (valid)"
else
    echo "mpp.py failed or produced corrupt output"
    tail -20 "$mpp_log"
    return 1
fi
```

---

## Phase 4 — Sweep structure

### One-at-a-time dimension sweeps

The recommended pattern: hold all dimensions at a baseline, sweep one at a time.

```bash
# Define sweep dimensions
DIM1_VALUES=(val1 val2 val3)
DIM2_VALUES=(val1 val2 val3)
# ... more dimensions

# Baselines (used when not sweeping that dimension)
BASELINE_DIM1=val2
BASELINE_DIM2=val2

# Phase 1: Sweep dim1, hold others at baseline
echo "=== Phase 1: Dim1 Sweep ==="
for v in "${DIM1_VALUES[@]}"; do
    run_config "$v" "$BASELINE_DIM2"
done

# Phase 2: Sweep dim2, hold others at baseline
echo "=== Phase 2: Dim2 Sweep ==="
for v in "${DIM2_VALUES[@]}"; do
    run_config "$BASELINE_DIM1" "$v"
done
```

This gives N×M tests instead of a full N×M×... Cartesian product — tractable runtime while isolating each dimension's effect.

### Naming convention for config files
```bash
config_name="${workload_name}_dim1-${v1}_dim2-${v2}_dim3-${v3}"
dat_file="${RESULTS_DIR}/emon_data/${config_name}.dat"
xlsx_file="${RESULTS_DIR}/postprocess/${config_name}.xlsx"
workload_log="${RESULTS_DIR}/workload_logs/${config_name}.log"
emon_log="${RESULTS_DIR}/emon_data/${config_name}_emon.log"
```

---

## Phase 5 — Summary report

After all configs complete, write a summary:

```bash
SUMMARY="$RESULTS_DIR/summary/sweep_summary.txt"
cat > "$SUMMARY" << EOF
Workload EMON Sweep Summary
===========================
Timestamp  : $TIMESTAMP
Platform   : $(lscpu | grep "Model name" | cut -d: -f2 | xargs)
Total tests: $TOTAL_TESTS
Completed  : $COMPLETED_TESTS
Failed     : $FAILED_TESTS
Duration   : ${TOTAL_DURATION}s

DAT files:
$(ls -lh "${RESULTS_DIR}/emon_data/"*.dat 2>/dev/null | awk '{print $9, $5}')

Excel files:
$(ls -lh "${RESULTS_DIR}/postprocess/"*.xlsx 2>/dev/null | awk '{print $9, $5}')

Next steps:
  1. Open xlsx files in Excel or LibreOffice for EDP metric dashboards
  2. Compare workload performance metrics across configs (workload_logs/)
  3. Correlate EMON metrics (IPC, memory BW, LLC miss rate) with performance
  4. Look for bottlenecks: low IPC + high LLC miss = memory bound
EOF

cat "$SUMMARY"
```

---

## Phase 6 — Script generation template

When the user provides workload + dimensions, generate a complete script following this structure:

```
1. Header + set -e-free shebang
2. source sep_vars.sh
3. Path definitions (RESULTS_DIR, EDP_EVENTS, EDP_METRIC, EDP_FORMAT, MPP_PY)
4. Sweep dimension arrays + baseline values
5. mkdir -p results structure
6. Prerequisite checks (workload binary, model/input, emon, EDP files, mpp.py)
7. SEP driver load check + insmod-sep
8. run_config() function (Steps 1–5 above)
9. One for-loop per sweep phase
10. Summary report
```

---

## Phase 7 — Running the generated script

```bash
chmod +x <sweep_script>.sh
sudo ./<sweep_script>.sh 2>&1 | tee sweep_run.log
```

Must run as root or with sudo — EMON requires kernel driver access.

Monitor progress:
```bash
# In another terminal
watch -n5 'ls -lh <RESULTS_DIR>/emon_data/*.dat 2>/dev/null | tail -5'
```

---

## Phase 8 — Post-processing only (re-run mpp.py on existing .dat)

If post-processing failed or you want different views:

```bash
MPP_PY="/opt/intel/sep/config/edp/pyedp/mpp.py"
EDP_METRIC="/opt/intel/sep/config/edp/<platform>_server_private.xml"
EDP_FORMAT="/opt/intel/sep/config/edp/chart_format_<platform>_server_private.txt"

for dat in <RESULTS_DIR>/emon_data/*.dat; do
    name=$(basename "$dat" .dat)
    xlsx="<RESULTS_DIR>/postprocess/${name}.xlsx"
    echo "Processing $name..."
    python3 "$MPP_PY" -i "$dat" -m "$EDP_METRIC" -f "$EDP_FORMAT" \
        -o "$xlsx" --socket-view --core-view --thread-view --uncore-view -p 8
done
```

---

## Concrete example

`scripts/example_sweep.sh` is a complete working reference — Llama 2 7B swept across 4 dimensions (threads, output tokens, prompt tokens, KV cache type).

**DO NOT run this script.** All paths inside (`LLAMA2_MODEL`, `LLAMA_BENCH`, `EDP_EVENTS`, etc.) are hardcoded to a specific machine and will not exist on other systems. Use it only to understand the script structure — never execute it as-is, test it, or assume its paths are valid. When generating a new script for the user, ask them for their own paths.

---

## Phase 9 — iperf3 + EMON: Anomaly Investigation Methodology

This section describes the *thought process and feedback loop* for using EMON to debug and deeply understand system behavior under iperf3 network workloads. The goal is not just to collect numbers — it is to move from "something is wrong" to "I know WHY it is wrong at the hardware level" and then "I have a hypothesis I can test."

### 9.0 — The investigation mindset

Every iperf3 anomaly (lower than expected throughput, port imbalance, degradation over time, hangs) is a symptom. EMON turns that symptom into hardware signals. Hardware signals suggest hypotheses. Hypotheses drive targeted config changes. Config changes either confirm or refute the hypothesis and teach you something deep about the system.

The loop is:

```
Observe anomaly
      ↓
Collect EMON during anomalous run (+ a known-good run for comparison)
      ↓
Identify which metric deviates from expected
      ↓
Form a specific, falsifiable hypothesis about root cause
      ↓
Design a targeted config change that isolates that variable
      ↓
Re-run with EMON → compare results
      ↓
Refine understanding → next hypothesis or declare root cause understood
```

Do not skip to config changes before looking at EMON. The hardware always tells the truth. Your intuition about where the bottleneck is will be wrong often.

---

### 9.1 — iperf3 throughput decomposition

Before interpreting any EMON metric, know what upper bounds apply to this workload:

| Resource | DMR-Q9UC capacity | Expected at 400 Gbps/port |
|----------|-------------------|---------------------------|
| PCIe Gen6 ×16 | ~1 TB/s per slot | ~50 GB/s per direction — well within PCIe headroom |
| DDR5 8000 MT/s (16 channels) | ~640 GB/s aggregate | ~50 GB/s — only 8% of memory BW |
| CPU core for softirq | ~few Gbps per core at line rate | Needs many cores with IRQ spreading |
| IRQ coalescing (tx/rx-usecs 750) | Batches 100+ packets/interrupt | Reduces core freq at cost of latency |
| NIC descriptor ring (8192 entries) | Deep ring → lower drop rate | Less contention at 400 Gbps |

**Key takeaway for iperf3 at 400 Gbps on CX8/DMR:** PCIe and DRAM are NOT the bottlenecks — there is enormous headroom. The binding constraint is CPU cycles spent in softirq/interrupt processing. Every EMON investigation should start with "where are CPU cycles going per core?"

---

### 9.2 — EMON metrics taxonomy for network workloads

The following EDP sections are most diagnostic for iperf3:

#### CPU utilization and IPC
```
Metric                  | What it tells you for iperf3
------------------------|---------------------------------------------
IPC (INST_RETIRED / CLK)| < 0.5 = interrupt-dominated, short-burst work
                        | 0.5–1.5 = mixed kernel/user work
                        | > 1.5 = well-pipelined (rare for net I/O)
CPU_CLK_UNHALTED        | Per-core: shows which cores are actually busy
                        | Ideal: IRQ cores saturated, others idle
                        | Bad: core 0 alone saturated (IRQ not spread)
```

#### Memory hierarchy
```
Metric                          | What it tells you for iperf3
--------------------------------|---------------------------------------------
LLC_MISS rate                   | High = data not cache-resident (expected for
                                | large iperf3 sends, since buffers >> LLC)
                                | Unusually high = fragmented descriptor ring
UNC_M_CAS_COUNT (per channel)   | Should be moderate and spread across channels
                                | Imbalance = NIC NUMA affinity mismatch
                                | Near-zero = PCIe/NIC not DMAing (link problem)
```

#### Uncore / PCIe / IIO
```
Metric                              | What it tells you for iperf3
------------------------------------|---------------------------------------------
UNC_IIO_DATA_REQ_OF_CPU.MEM_WRITE   | NIC→CPU DMA writes (incoming data)
UNC_IIO_DATA_REQ_OF_CPU.MEM_READ    | CPU→NIC DMA reads (outgoing data)
Low or near-zero IIO BW             | NIC is idle or PCIe link is degraded
                                    | (confirmed root cause of Gen1 case: 28 Gbps)
IIO on socket 0 but DRAM on socket 1| NUMA cross-traffic — CX8 #2 affinity mismatch
```

#### Interrupt and softirq distribution (via per-core view)
```
Metric                              | What it tells you
------------------------------------|---------------------------------------------
Per-core CPU_CLK_UNHALTED pattern   | Should spread across 80 cores per CX8 port
                                    | (one CX8 per socket, 63 queues per port)
If only 1–4 cores hot               | IRQ affinity not applied (run set_aff_perf.sh)
If wrong cores hot (cores 80-159    | IRQ binding crossed socket boundary →
for eth1/eth2 on CX8 #1)           | NUMA mismatch, expect ~20% throughput penalty
```

---

### 9.3 — Known iperf3 anomaly signatures on DMR-Q9UC + CX8

These are real anomalies observed during this session. Their EMON signatures help identify the same pattern in the future:

#### Anomaly A: 28 Gbps on a 400G link (PCIe speed downgrade)

- **Observed symptom:** All 4 ports plateau at 28 Gbps regardless of `-P` count or tuning
- **EMON signature:** IIO BW very low (< 3 GB/s on MEM_WRITE and MEM_READ); IPC moderate (CPU not saturated); DRAM BW very low
- **What EMON tells you:** The NIC is barely DMAing anything. The CPU is not the bottleneck. The problem is before the CPU — in the PCIe link.
- **Root cause:** `lspci LnkSta: Speed 2.5GT/s (downgraded)` — BIOS locked PCIe to Gen1 after thermal crash. At Gen1 ×16 = 4 GB/s max → matches 28 Gbps observed.
- **Hypothesis test:** `setpci` to retrain link → if IIO BW jumps but throughput still bounded → confirmed PCIe was the bottleneck → cold power cycle for Gen6.

#### Anomaly B: Good throughput but highly uneven per-core CPU load

- **Observed symptom:** 365 Gbps but CPU utilization spiky, some cores at 100%, most idle
- **EMON signature:** Per-core `CPU_CLK_UNHALTED` shows large variance across cores; IPC on hot cores < 0.3
- **What EMON tells you:** IRQ processing concentrated on too few cores. NIC queues not spread across CPUs.
- **Hypothesis:** `tune_nic.sh` not applied, or `set_aff_perf.sh` not run after tuning
- **Test:** `ethtool -l eth1` to check combined queue count (should be 63), `cat /proc/interrupts | grep mlx` to see per-core IRQ distribution. Apply tuning — re-run with EMON to confirm load spreads.

#### Anomaly C: Throughput drops after 30–60 seconds (thermal or IRQ coalescing)

- **Observed symptom:** iperf3 interval data shows initial rate, then 10–20% drop mid-run
- **EMON signature to look for:** Rising `CPU_CLK_UNHALTED` on specific cores mid-run + LLC miss rate increase
- **What EMON tells you:** If a core is starting to saturate, check if IRQ affinity has shifted (unlikely) or if the NIC is rebalancing queues. If temperature rises → check `dmesg -T | grep temp_warn`.
- **Risk note:** `-P 128` caused a thermal crash on CX8 #2 (server-side). EMON thermal counters (if available) can give early warning before `temp_warn` appears in dmesg.

#### Anomaly D: CX8 #2 ports underperforming vs CX8 #1 after recovery

- **EMON investigation:** Compare IIO BW on PCIe domain `0001:11:xx` vs `0000:61:xx`
- If CX8 #2 IIO BW is 30% lower → incomplete PCIe link recovery (still at Gen3) → cold boot needed
- If equal but throughput lower → NUMA affinity issue (IRQs for eth3/eth4 landing on wrong socket)

---

### 9.4 — Hypothesis-driven EMON sweep design for iperf3

When you observe an anomaly, define a sweep that varies the suspected variable while holding everything else constant. The EMON trace at each point tells you whether the hypothesis is confirmed.

#### Template: IRQ affinity hypothesis
```
Observation: throughput lower than expected, CPU load unbalanced
Hypothesis: IRQ affinity not set correctly, most interrupts on one core

Sweep:
  Config A: default (no affinity script)   → EMON: per-core CLK_UNHALTED
  Config B: tune_nic.sh only               → same metric
  Config C: tune_nic.sh + set_aff_perf.sh  → same metric

Expected if hypothesis correct:
  Config A: core 0 at 100%, others near 0 → throughput ~20 Gbps
  Config B: better distribution but not optimal → throughput ~100 Gbps
  Config C: 63 cores ~evenly loaded → throughput ~365 Gbps
```

#### Template: NUMA affinity hypothesis
```
Observation: eth3/eth4 (CX8 #2, socket 1) consistently lower than eth1/eth2 (CX8 #1, socket 0)
Hypothesis: IRQs for eth3/eth4 landing on socket 0 cores → cross-NUMA DMA

EMON check:
  1. Per-core CLK_UNHALTED: which cores handle eth3/eth4 interrupts?
     (set_aff_perf.sh should bind eth1 IRQs→cores 0-79, eth2 IRQs→cores 80-159)
  2. UNC_M_CAS_COUNT per DIMM channel: if eth3/eth4 data lands in socket 0 DRAM, cross-NUMA penalty
  3. Compare IIO_DATA_REQ on domain 0001:11.x vs 0000:61.x

Fix: verify set_irq_affinity_cpulist.sh properly maps eth3/eth4 IRQs to >160 cores (socket 1 equivalent)
```

#### Template: Stream count (-P) hypothesis
```
Observation: -P 1 gives 2 Gbps, -P 100 gives 365 Gbps — what is the per-stream contribution?
Hypothesis: each iperf3 stream maps to one NIC queue; throughput scales until all queues saturated

Sweep: -P 1, 4, 8, 16, 32, 64, 100 with EMON collection at each

EMON signals to track:
  - IPC vs -P count: should plateau once all queues busy
  - Per-core CLK_UNHALTED spread: how many cores get work as -P increases?
  - DRAM BW: should scale linearly with -P until CPU-bound

Expected: throughput scales with -P until ~63 streams (queue count), then plateaus.
If plateau earlier → some queues not receiving traffic (hashing collision)
If plateau later → RSS hash distributing unevenly
```

---

### 9.5 — Running EMON alongside iperf3 on DMR-Q9UC

The server runs iperf3 server processes bound to the link IPs. To capture EMON during a client-driven test:

```bash
# On S1 (server side — runs emon + iperf3 servers)
source /opt/intel/sep/sep_vars.sh

EDP_EVENTS="/opt/intel/sep/config/edp/diamondrapids_server_events_private.txt"
EDP_METRIC="/opt/intel/sep/config/edp/diamondrapids_server_private.xml"
EDP_FORMAT="/opt/intel/sep/config/edp/chart_format_diamondrapids_server_private.txt"
MPP_PY="/opt/intel/sep/config/edp/pyedp/mpp.py"

DAT="/tmp/iperf3_eth1_P100.dat"
LOG="/tmp/iperf3_eth1_P100.log"
XLSX="/tmp/iperf3_eth1_P100.xlsx"

# Restart iperf3 server (not running from a previous attempt)
pkill -x iperf3 2>/dev/null; sleep 1
nohup iperf3 -s -B 192.168.214.207 -p 5201 > /tmp/s_eth1.log 2>&1 &
sleep 1

# Start EMON collection
emon -collect-edp edp_file="$EDP_EVENTS" -f "$DAT" > "$LOG" 2>&1 &
EMON_PID=$!
sleep 5

echo "EMON running, PID=$EMON_PID — start iperf3 client on S2 now"
# (trigger S2 client externally, or use sleep as a gating signal)
# Wait for expected test duration + teardown
wait  # or use: ssh s2 'timeout 90 iperf3 -c ... -P 100 -t 30'

emon -stop >> "$LOG" 2>&1
wait $EMON_PID 2>/dev/null
sleep 2

# Post-process
python3 "$MPP_PY" -i "$DAT" -m "$EDP_METRIC" -f "$EDP_FORMAT" \
    -o "$XLSX" --socket-view --core-view --thread-view --uncore-view -p 8
echo "Excel: $XLSX"
```

Use the **core-view** tab in the Excel output to see per-core CLK_UNHALTED heat maps — this is the fastest way to spot IRQ affinity and NUMA issues visually.

Use the **uncore-view** tab to see IIO and memory controller traffic — this is where PCIe speed issues and cross-NUMA DMA show up.

---

### 9.6 — Reading EMON output for iperf3: what to look at first

When you open the post-processed Excel from an iperf3 run, go in this order:

1. **Summary tab → IPC** — is it above 0.5? If not, the CPU is interrupt-dominated. No amount of config tuning will help unless you reduce interrupt rate (increase coalescing `rx-usecs`) or spread IRQs.

2. **Core view → CPU_CLK_UNHALTED heatmap** — is work distributed across 60+ cores? If concentrated in <10 cores, IRQ affinity is wrong. Note *which* cores are hot — that tells you which socket's NIC queue affinity applies.

3. **Uncore view → IIO BW (per-domain)** — each CX8 is on a different PCIe domain (`0000:61:xx` and `0001:11:xx`). Compare IIO write BW across domains. If CX8 #2 is lower → incomplete Gen6 recovery or NUMA mismatch.

4. **Uncore view → Memory controller (per-channel)** — imbalanced channel usage can indicate NUMA affinity issues. For iperf3, data fills buffers → if all writes land on 2 of 16 channels, something is wrong with address interleaving.

5. **Core view → look at interval over time** — does IPC change over the 30s run? A drop mid-run signals thermal throttling, queue starvation, or IRQ handler buildup.

---

### 9.7 — The "diff" approach: always compare to a known-good EMON trace

The most powerful investigation technique is not absolute values, but *differences* between a known-good run and an anomalous run:

```bash
# Step 1: Collect known-good baseline (365 Gbps, full tuning, Gen6, -P 100)
run_with_emon "baseline_full_tuning" "iperf3 -c ... -P 100 -t 30"

# Step 2: Remove one variable, collect EMON
run_with_emon "no_irq_affinity" "iperf3 -c ... -P 100 -t 30"
# (after reverting set_aff_perf.sh)

# Step 3: Compare the two Excel files
# What changed in IPC? CLK_UNHALTED distribution? IIO BW?
# That delta IS the effect of IRQ affinity tuning
```

This "diff" discipline is how you isolate individual effects without being confused by absolute values that depend on platform-specific calibration.

---

## Key rules (always follow these)

1. **EMON uses `-f <dat_file>`** — never redirect stdout to .dat
2. **Stop with `emon -stop`** — never `kill $EMON_PID`
3. **5s sleep after starting EMON** before launching workload
4. **2s sleep after `emon -stop`** before running mpp.py
5. **Validate .dat and .xlsx** after each config — don't assume success
6. **No `set -e`** in the sweep script — individual config failures should not abort the whole sweep
7. **Root required** — EMON needs kernel driver access
8. **SEP vars sourced** — always `source /opt/intel/sep/sep_vars.sh` first

## Investigation rules (for anomaly debugging)

9. **Never skip to config changes** — collect EMON first, let hardware signals drive the hypothesis
10. **Always collect a known-good trace** — EMON absolute values are meaningless without a diff reference
11. **One variable at a time** — each test changes exactly one thing; otherwise you cannot attribute cause
12. **Hypotheses must be falsifiable** — "IRQ affinity is wrong" → testable by checking per-core CLK_UNHALTED
13. **Start with IPC** — if IPC is low, CPU is interrupt-dominated; fix interrupt handling before anything else
14. **Check uncore IIO BW early** — near-zero IIO BW = NIC/PCIe problem, not a CPU/software problem
15. **Core-view is for IRQ/NUMA diagnosis, uncore-view is for PCIe/memory diagnosis** — know which tab to open
16. **The diff between two EMON traces reveals the effect of one config change** — this is the core learning signal
