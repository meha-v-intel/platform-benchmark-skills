---
name: emon-workload-sweep
description: "Create and run a workload configuration sweep with EMON collection. Use when: collecting EMON traces while running a workload, sweeping workload parameters, profiling CPU performance metrics, generating EDP Excel reports, correlating hardware counters with workload performance, automating multi-config benchmarks with EMON."
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

## Key rules (always follow these)

1. **EMON uses `-f <dat_file>`** — never redirect stdout to .dat
2. **Stop with `emon -stop`** — never `kill $EMON_PID`
3. **5s sleep after starting EMON** before launching workload
4. **2s sleep after `emon -stop`** before running mpp.py
5. **Validate .dat and .xlsx** after each config — don't assume success
6. **No `set -e`** in the sweep script — individual config failures should not abort the whole sweep
7. **Root required** — EMON needs kernel driver access
8. **SEP vars sourced** — always `source /opt/intel/sep/sep_vars.sh` first
