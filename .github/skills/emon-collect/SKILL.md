---
name: emon-collect
description: "Collect EMON hardware counter data in parallel with any workload, generate workload sweep scripts with simultaneous EMON collection, post-process .dat files to Excel EDP reports (.xlsx), and investigate hardware-level anomalies. Use when: running EMON alongside a workload, profiling any benchmark with hardware counters, collecting EMON while a job runs, recording EMON to .dat file, converting EMON .dat to xlsx, sweeping workload configurations with EMON collection, generating a parameter sweep script with EMON, post-processing existing EMON .dat files, debugging low throughput or anomalies with hardware counters, iterating hypotheses using EMON signals."
argument-hint: "[collect|sweep|postprocess]"
allowed-tools: Bash
---

# EMON Collect — Parallel EMON Collection, Sweep Scripts, and Post-Processing

# EMON Collect — Parallel EMON Collection, Sweep Scripts, and Post-Processing

Teaches Copilot how to handle **any EMON collection request**:

| Mode | `$ARGUMENTS` | When to use |
|------|-------------|-------------|
| **Single collect** | `collect` or blank | One workload command, wrap with EMON, get `.dat` + `.xlsx` |
| **Sweep** | `sweep` | Multiple configs / parameter permutations — generate a sweep script with EMON at each config |
| **Post-process** | `postprocess` | Re-run `mpp.py` on existing `.dat` files → `.xlsx` |

If the user doesn't specify, ask: "Do you want to collect EMON for a single run, generate a sweep script across multiple configurations, or post-process existing .dat files?"

---

## Phase 0 — Understand the request

### For single-run collection (`collect`)

Ask the user:

1. **Workload command** — the exact shell command or script path. Runs in the **foreground**; EMON collects in the **background**.
2. **Run label** — short name for output files (default: derive from binary name).
3. **Output directory** — where to save `.dat`, logs, `.xlsx` (default: `~/emon_<label>_<timestamp>/`).
4. **Warm-up needed?** — run once without EMON first? (default: no)
5. **Run count** — how many EMON+workload runs? (default: 1)

### For sweep script generation (`sweep`)

Ask the user:

1. **Workload binary/command** — what base command runs the workload?
2. **Configuration dimensions** — what parameters vary? (e.g. thread count, batch size, precision, input size)
3. **Values per dimension** — what are the values to sweep for each?
4. **Baseline config** — when sweeping one dimension, what fixed values are used for the others?
5. **Run repetitions per config** — default 3.
6. **Output directory** — where to store results.

Do **not** assume any values. Collect them before proceeding.

---

## Phase 1 — Verify EMON prerequisites

### 1a. Source SEP environment
```bash
source /opt/intel/sep/sep_vars.sh
```
This adds `emon` to PATH and exports `SEP_BASE_DIR`. Verify it took effect:
```bash
which emon && emon -version
```

> **Persistent setup on DMR-Q9UC (sc00901168s0095 / sc00901168s0097):**
> - SEP 5.58 beta is at `/opt/intel/sep_private_5.58_beta_linux_020402465cf386d3e/`
>   with symlink `/opt/intel/sep → /opt/intel/sep_private_5.58...`
> - `sep_vars.sh` is added to `~/.bashrc` on both systems — no manual sourcing needed
> - SEP driver loads at boot via `insmod-sep`

> **First-time setup on a new system:**
> 1. Copy SEP: `ssh src 'tar cf - -C /opt/intel sep_private_5.58_...' | ssh dst 'tar xf - -C /opt/intel'`
> 2. Load driver: `/opt/intel/sep/sepdk/src/insmod-sep`
>    — kernel mismatch? `cd /opt/intel/sep/sepdk/src && ./build-driver --non-interactive`
> 3. Add to `~/.bashrc`: `source /opt/intel/sep/sep_vars.sh`

### 1b. Discover EDP config files for this platform
```bash
# Find the platform codename from installed EDP files
ls /opt/intel/sep/config/edp/*_server_events_private.txt 2>/dev/null | head -5
```

From the output, extract the platform prefix (e.g. `diamondrapids`, `sapphirerapids`,
`graniterapids`) and set:

```bash
PLATFORM="diamondrapids"   # replace with discovered value

EDP_EVENTS="/opt/intel/sep/config/edp/${PLATFORM}_server_events_private.txt"
EDP_METRIC="/opt/intel/sep/config/edp/${PLATFORM}_server_private.xml"
EDP_FORMAT="/opt/intel/sep/config/edp/chart_format_${PLATFORM}_server_private.txt"
MPP_PY="/opt/intel/sep/config/edp/pyedp/mpp.py"

# Confirm all files exist
ls -la "$EDP_EVENTS" "$EDP_METRIC" "$EDP_FORMAT" "$MPP_PY"
```

### 1c. Load SEP driver (if not already loaded)
```bash
lsmod | grep sep5 || /opt/intel/sep/sepdk/src/insmod-sep
lsmod | grep sep5   # confirm loaded
```

### 1d. Smoke-test EMON (optional but recommended on first use)
```bash
# 3-second collection → should produce a non-empty .dat
DAT_TEST="/tmp/emon_smoketest.dat"
emon -collect-edp edp_file="$EDP_EVENTS" -f "$DAT_TEST" > /tmp/emon_smoke.log 2>&1 &
EMON_PID=$!
sleep 3
emon -stop >> /tmp/emon_smoke.log 2>&1
wait $EMON_PID 2>/dev/null
ls -lh "$DAT_TEST"   # should be several MB for 3s
```

---

## Phase 2 — Output directory structure

Create a timestamped directory for all outputs:

```bash
LABEL="<run_label>"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUT_DIR="${HOME}/emon_${LABEL}_${TIMESTAMP}"
mkdir -p "$OUT_DIR"
```

Files produced per run `N`:
```
$OUT_DIR/
├── <label>_run<N>.dat            # raw EMON samples — the primary artifact
├── <label>_run<N>_emon.log       # emon console output (status, start/stop messages)
├── <label>_run<N>_workload.log   # workload stdout + stderr
└── <label>_run<N>.xlsx           # post-processed EDP Excel report
```

---

## Phase 3 — The core collect pattern

This is the **exact sequence** for one EMON+workload run. Every variable must
be set before entering this block.

```bash
# Variables (set per-run)
RUN_N=1
DAT_FILE="${OUT_DIR}/${LABEL}_run${RUN_N}.dat"
EMON_LOG="${OUT_DIR}/${LABEL}_run${RUN_N}_emon.log"
WORKLOAD_LOG="${OUT_DIR}/${LABEL}_run${RUN_N}_workload.log"
XLSX_FILE="${OUT_DIR}/${LABEL}_run${RUN_N}.xlsx"

echo "=== Run $RUN_N ==="

# --- Step 1: Start EMON in background ---
# -f writes raw samples directly to the .dat file (do NOT use stdout redirect for .dat)
# stdout redirect here captures only emon's status/header text to the log
emon -collect-edp edp_file="$EDP_EVENTS" -f "$DAT_FILE" > "$EMON_LOG" 2>&1 &
EMON_PID=$!

# Wait for EMON to initialize before starting the workload
sleep 5

# Verify EMON is still running
if ! kill -0 $EMON_PID 2>/dev/null; then
    echo "ERROR: EMON failed to start. Check $EMON_LOG"
    cat "$EMON_LOG"
    exit 1
fi
echo "EMON running (PID $EMON_PID), starting workload..."

# --- Step 2: Run the workload in the foreground ---
# EMON collects during the entire workload execution window
<WORKLOAD_COMMAND> > "$WORKLOAD_LOG" 2>&1
WORKLOAD_EXIT=$?

echo "Workload exited (code $WORKLOAD_EXIT)"

# --- Step 3: Stop EMON ---
# Always use "emon -stop" — never kill the PID directly
# Killing the PID bypasses clean sample termination and can corrupt the .dat
emon -stop >> "$EMON_LOG" 2>&1
wait $EMON_PID 2>/dev/null || true
sleep 2   # allow final buffer flush to .dat

# --- Step 4: Validate the .dat file ---
if [ ! -f "$DAT_FILE" ] || [ ! -s "$DAT_FILE" ]; then
    echo "ERROR: $DAT_FILE is missing or empty — EMON did not record data"
    cat "$EMON_LOG"
    exit 1
fi
echo "DAT: $(wc -l < "$DAT_FILE") lines, $(du -h "$DAT_FILE" | cut -f1)"

# --- Step 5: Post-process to xlsx ---
python3 "$MPP_PY" \
    -i  "$DAT_FILE" \
    -m  "$EDP_METRIC" \
    -f  "$EDP_FORMAT" \
    -o  "$XLSX_FILE" \
    --socket-view \
    --core-view \
    --thread-view \
    --uncore-view \
    -p  8 \
    > "${OUT_DIR}/${LABEL}_run${RUN_N}_mpp.log" 2>&1

# Validate the xlsx (a valid xlsx is a ZIP archive)
if [ -f "$XLSX_FILE" ] && unzip -t "$XLSX_FILE" >/dev/null 2>&1; then
    echo "Excel: $(du -h "$XLSX_FILE" | cut -f1) — OK"
else
    echo "ERROR: mpp.py failed or produced corrupt xlsx"
    tail -30 "${OUT_DIR}/${LABEL}_run${RUN_N}_mpp.log"
    exit 1
fi
```

### Critical notes on the `-f` flag

**Always use `-f <dat_file>` for the raw data — never redirect EMON stdout to
the `.dat` file.** The `-f` flag routes only pure sample data to the file.
Redirecting stdout also captures EMON's startup header and status text, which
corrupts the `.dat` and causes `mpp.py` to fail silently or produce empty sheets.

Correct:
```bash
emon -collect-edp edp_file="$EDP_EVENTS" -f output.dat > emon_status.log 2>&1 &
```

Wrong (do not do this):
```bash
emon -collect-edp edp_file="$EDP_EVENTS" > output.dat 2>&1 &   # corrupt .dat!
```

---

## Phase 4 — Multiple runs (repeat collection)

If the user requested more than one run, loop Phase 3:

```bash
NUM_RUNS=3   # set from user input

for RUN_N in $(seq 1 $NUM_RUNS); do
    DAT_FILE="${OUT_DIR}/${LABEL}_run${RUN_N}.dat"
    EMON_LOG="${OUT_DIR}/${LABEL}_run${RUN_N}_emon.log"
    WORKLOAD_LOG="${OUT_DIR}/${LABEL}_run${RUN_N}_workload.log"
    XLSX_FILE="${OUT_DIR}/${LABEL}_run${RUN_N}.xlsx"

    echo ""
    echo "=== Run $RUN_N / $NUM_RUNS ==="

    emon -collect-edp edp_file="$EDP_EVENTS" -f "$DAT_FILE" > "$EMON_LOG" 2>&1 &
    EMON_PID=$!
    sleep 5

    if ! kill -0 $EMON_PID 2>/dev/null; then
        echo "EMON failed on run $RUN_N — aborting"
        cat "$EMON_LOG"; break
    fi

    <WORKLOAD_COMMAND> > "$WORKLOAD_LOG" 2>&1

    emon -stop >> "$EMON_LOG" 2>&1
    wait $EMON_PID 2>/dev/null || true
    sleep 2

    echo "DAT run $RUN_N: $(wc -l < "$DAT_FILE") lines, $(du -h "$DAT_FILE" | cut -f1)"

    python3 "$MPP_PY" -i "$DAT_FILE" -m "$EDP_METRIC" -f "$EDP_FORMAT" \
        -o "$XLSX_FILE" --socket-view --core-view --thread-view --uncore-view -p 8 \
        > "${OUT_DIR}/${LABEL}_run${RUN_N}_mpp.log" 2>&1

    if unzip -t "$XLSX_FILE" >/dev/null 2>&1; then
        echo "Excel run $RUN_N: $(du -h "$XLSX_FILE" | cut -f1) — OK"
    else
        echo "WARNING: mpp.py failed for run $RUN_N"
    fi
done
```

---

## Phase 5 — Post-process only (re-run mpp.py on existing .dat files)

If the user already has `.dat` files and only needs xlsx output (or if mpp.py
failed during collection and needs to be re-run):

```bash
# Set these to match the original collection
PLATFORM="diamondrapids"   # discover: ls /opt/intel/sep/config/edp/*.xml
EDP_METRIC="/opt/intel/sep/config/edp/${PLATFORM}_server_private.xml"
EDP_FORMAT="/opt/intel/sep/config/edp/chart_format_${PLATFORM}_server_private.txt"
MPP_PY="/opt/intel/sep/config/edp/pyedp/mpp.py"

# Point at the directory containing .dat files
DAT_DIR="<path_to_dat_directory>"
XLSX_DIR="${DAT_DIR}"   # put xlsx alongside dat, or specify a different path

for DAT in "${DAT_DIR}"/*.dat; do
    NAME=$(basename "$DAT" .dat)
    XLSX="${XLSX_DIR}/${NAME}.xlsx"
    MPP_LOG="${XLSX_DIR}/${NAME}_mpp.log"
    echo "Processing $NAME ..."
    python3 "$MPP_PY" \
        -i  "$DAT" \
        -m  "$EDP_METRIC" \
        -f  "$EDP_FORMAT" \
        -o  "$XLSX" \
        --socket-view \
        --core-view \
        --thread-view \
        --uncore-view \
        -p  8 \
        > "$MPP_LOG" 2>&1
    if unzip -t "$XLSX" >/dev/null 2>&1; then
        echo "  OK: $(du -h "$XLSX" | cut -f1)"
    else
        echo "  FAILED — see $MPP_LOG"
        tail -10 "$MPP_LOG"
    fi
done
```

---

## Phase 6 — Warm-up run (optional)

If the user requested a warm-up, run the workload once **without** EMON before
the measured runs. This primes CPU caches, JIT compilers, and any lazy
initialization paths:

```bash
echo "=== Warm-up run (no EMON) ==="
<WORKLOAD_COMMAND> > "${OUT_DIR}/${LABEL}_warmup.log" 2>&1
echo "Warm-up done. Starting measured run(s)..."
sleep 2
```

---

## Phase 7 — Monitoring during collection

To watch EMON progress while collection is running (in a second terminal):

```bash
# Watch dat file grow in real-time
watch -n 5 'ls -lh <OUT_DIR>/*.dat 2>/dev/null'

# Tail the emon log to see status messages
tail -f <OUT_DIR>/<label>_run1_emon.log

# Check EMON PID is alive
kill -0 $EMON_PID && echo "EMON running" || echo "EMON stopped"
```

---

## Phase 8 — Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `emon: command not found` | `sep_vars.sh` not sourced | `source /opt/intel/sep/sep_vars.sh` |
| `EMON failed to start` — log says driver not loaded | SEP driver not loaded | `/opt/intel/sep/sepdk/src/insmod-sep` |
| `.dat` file is 0 bytes or missing | EMON crashed before workload finished | Check EMON log; reload driver; re-run |
| `.dat` is tiny (< 1 KB) for a long workload | EMON stopped immediately — events file path wrong | Verify `EDP_EVENTS` path exists and matches platform |
| `mpp.py` exits with `KeyError` or `IndexError` | Wrong `EDP_METRIC` or `EDP_FORMAT` for this `.dat` | Re-discover platform prefix; match files to the exact CPU codename |
| xlsx file is 0 bytes or fails `unzip -t` | mpp.py produced corrupt output | Check mpp.log for Python tracebacks; ensure pyedp venv is active if needed |
| Workload exits instantly before EMON collects anything | Workload very short (< 5s) | Reduce sleep before workload to 2s, or loop the workload: `for i in $(seq 10); do <cmd>; done` |
| `Permission denied` starting EMON | Not running as root | `sudo` prefix, or `sudo /opt/intel/sep/sepdk/src/insmod-sep` then retry |
| mpp.py needs Python packages (numpy, polars, pyarrow) | venv not activated | `source /opt/intel/sep/config/edp/pyedp/.venv/bin/activate` before running mpp.py |

### Checking whether SEP driver is loaded
```bash
lsmod | grep sep5
# Empty output → not loaded → run insmod-sep
```

### Activating the pyedp virtual environment
Some systems require the pyedp `.venv` to be activated before running `mpp.py`:
```bash
source /opt/intel/sep/config/edp/pyedp/.venv/bin/activate
python3 "$MPP_PY" -i "$DAT_FILE" ...
```
On DMR-Q9UC the venv is pre-configured with Python 3.12 + numpy/pyarrow/polars.

---

## Quick reference — one-shot collect and post-process

For experienced users who know their paths. Replace `<...>` placeholders:

```bash
source /opt/intel/sep/sep_vars.sh
lsmod | grep sep5 || /opt/intel/sep/sepdk/src/insmod-sep

PLATFORM="diamondrapids"
EDP_EVENTS="/opt/intel/sep/config/edp/${PLATFORM}_server_events_private.txt"
EDP_METRIC="/opt/intel/sep/config/edp/${PLATFORM}_server_private.xml"
EDP_FORMAT="/opt/intel/sep/config/edp/chart_format_${PLATFORM}_server_private.txt"
MPP_PY="/opt/intel/sep/config/edp/pyedp/mpp.py"

LABEL="<workload_name>"
OUT_DIR=~/emon_${LABEL}_$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT_DIR"
DAT="${OUT_DIR}/${LABEL}.dat"
XLSX="${OUT_DIR}/${LABEL}.xlsx"

emon -collect-edp edp_file="$EDP_EVENTS" -f "$DAT" > "${OUT_DIR}/${LABEL}_emon.log" 2>&1 &
EMON_PID=$!; sleep 5

<WORKLOAD_COMMAND> > "${OUT_DIR}/${LABEL}_workload.log" 2>&1

emon -stop >> "${OUT_DIR}/${LABEL}_emon.log" 2>&1
wait $EMON_PID 2>/dev/null; sleep 2

echo "DAT: $(wc -l < "$DAT") lines, $(du -h "$DAT" | cut -f1)"

python3 "$MPP_PY" -i "$DAT" -m "$EDP_METRIC" -f "$EDP_FORMAT" \
    -o "$XLSX" --socket-view --core-view --thread-view --uncore-view -p 8

unzip -t "$XLSX" >/dev/null 2>&1 && echo "Excel OK: $XLSX" || echo "mpp.py failed"
```

---

## Phase 9 — Sweep script generation

When the user wants to sweep a workload across multiple configurations with EMON
at each one, generate a self-contained bash script. Ask for the workload details
(Phase 0 → sweep), then produce a script following this structure.

### 9.1 — Sweep directory structure

```bash
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULTS_DIR="/root/<workload_name>_emon_sweep_${TIMESTAMP}"
mkdir -p "$RESULTS_DIR"/{emon_data,workload_logs,postprocess,summary}
```

```
$RESULTS_DIR/
├── emon_data/       # raw .dat files + emon console logs
├── workload_logs/   # stdout/stderr from each workload run
├── postprocess/     # .xlsx EDP reports + mpp.py logs
└── summary/         # human-readable sweep summary
```

### 9.2 — The run_config function

Every configuration calls this function. It wraps the core collect pattern
(Phase 3) into a reusable unit:

```bash
run_config() {
    local config_name="$1"   # unique label for this config, e.g. "threads-8_batch-32"
    shift
    local workload_cmd="$@"  # full workload command for this config

    local dat_file="${RESULTS_DIR}/emon_data/${config_name}.dat"
    local xlsx_file="${RESULTS_DIR}/postprocess/${config_name}.xlsx"
    local workload_log="${RESULTS_DIR}/workload_logs/${config_name}.log"
    local emon_log="${RESULTS_DIR}/emon_data/${config_name}_emon.log"
    local mpp_log="${RESULTS_DIR}/postprocess/${config_name}_mpp.log"

    echo ""
    echo "=== Config: $config_name ==="

    # Start EMON
    emon -collect-edp edp_file="$EDP_EVENTS" -f "$dat_file" > "$emon_log" 2>&1 &
    EMON_PID=$!
    sleep 5

    if ! kill -0 $EMON_PID 2>/dev/null; then
        echo "EMON failed for $config_name — skipping"
        cat "$emon_log"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi

    # Run workload
    eval "$workload_cmd" > "$workload_log" 2>&1
    WORKLOAD_EXIT=$?

    # Stop EMON cleanly
    emon -stop >> "$emon_log" 2>&1
    wait $EMON_PID 2>/dev/null || true
    sleep 2

    # Validate .dat
    if [ ! -f "$dat_file" ] || [ ! -s "$dat_file" ]; then
        echo "ERROR: $dat_file missing or empty"
        FAILED_TESTS=$((FAILED_TESTS + 1))
        return 1
    fi
    echo "DAT: $(wc -l < "$dat_file") lines, $(du -h "$dat_file" | cut -f1)"

    # Post-process
    python3 "$MPP_PY" \
        -i  "$dat_file" \
        -m  "$EDP_METRIC" \
        -f  "$EDP_FORMAT" \
        -o  "$xlsx_file" \
        --socket-view --core-view --thread-view --uncore-view \
        -p  8 \
        > "$mpp_log" 2>&1

    if [ -f "$xlsx_file" ] && unzip -t "$xlsx_file" >/dev/null 2>&1; then
        echo "Excel: $(du -h "$xlsx_file" | cut -f1) — OK"
        COMPLETED_TESTS=$((COMPLETED_TESTS + 1))
    else
        echo "mpp.py failed for $config_name — see $mpp_log"
        tail -10 "$mpp_log"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
}
```

> **Do not use `set -e`** in sweep scripts. Individual config failures must not
> abort the whole sweep — failed configs are counted and the sweep continues.

### 9.3 — One-at-a-time dimension sweep pattern

Recommended default: hold all dimensions at baseline, sweep one at a time.
This gives N+M tests (tractable) instead of a full N×M×... Cartesian product,
and isolates each dimension's effect cleanly.

```bash
# Define sweep dimensions and values
DIM1_VALUES=(val_a val_b val_c)
DIM2_VALUES=(val_x val_y val_z)
BASELINE_DIM1=val_b   # used when sweeping dim2
BASELINE_DIM2=val_x   # used when sweeping dim1

TOTAL_TESTS=$(( ${#DIM1_VALUES[@]} + ${#DIM2_VALUES[@]} ))
COMPLETED_TESTS=0
FAILED_TESTS=0
START_TIME=$(date +%s)

# Phase 1: Sweep dim1, hold dim2 at baseline
echo "=== Phase 1: DIM1 Sweep ==="
for v1 in "${DIM1_VALUES[@]}"; do
    config_name="${WORKLOAD_NAME}_dim1-${v1}_dim2-${BASELINE_DIM2}"
    run_config "$config_name" <workload_cmd --dim1 $v1 --dim2 $BASELINE_DIM2>
done

# Phase 2: Sweep dim2, hold dim1 at baseline
echo "=== Phase 2: DIM2 Sweep ==="
for v2 in "${DIM2_VALUES[@]}"; do
    config_name="${WORKLOAD_NAME}_dim1-${BASELINE_DIM1}_dim2-${v2}"
    run_config "$config_name" <workload_cmd --dim1 $BASELINE_DIM1 --dim2 $v2>
done
```

### 9.4 — Config naming convention

```bash
# Encode every varying parameter into the config name — this is the filename stem
config_name="${workload_name}_dim1-${v1}_dim2-${v2}_rep${rep}"
# → emon_data/myworkload_threads-8_batch-32_rep1.dat
# → postprocess/myworkload_threads-8_batch-32_rep1.xlsx
```

Keep names filesystem-safe: use `-` within a dimension value, `_` between dimensions.

### 9.5 — Multiple repetitions per config

If the user wants N repetitions per configuration:

```bash
NUM_REPS=3
for v in "${DIM1_VALUES[@]}"; do
    for rep in $(seq 1 $NUM_REPS); do
        config_name="${WORKLOAD_NAME}_dim1-${v}_rep${rep}"
        run_config "$config_name" <workload_cmd --dim1 $v>
    done
done
```

### 9.6 — Sweep summary report

After all configs complete:

```bash
END_TIME=$(date +%s)
TOTAL_DURATION=$((END_TIME - START_TIME))
SUMMARY="$RESULTS_DIR/summary/sweep_summary.txt"

cat > "$SUMMARY" << EOF
Workload EMON Sweep Summary
===========================
Timestamp  : $TIMESTAMP
Platform   : $(lscpu | grep "Model name" | cut -d: -f2 | xargs)
Workload   : $WORKLOAD_NAME
Total tests: $TOTAL_TESTS
Completed  : $COMPLETED_TESTS
Failed     : $FAILED_TESTS
Duration   : ${TOTAL_DURATION}s

DAT files:
$(ls -lh "${RESULTS_DIR}/emon_data/"*.dat 2>/dev/null | awk '{print $9, $5}')

Excel files:
$(ls -lh "${RESULTS_DIR}/postprocess/"*.xlsx 2>/dev/null | awk '{print $9, $5}')

Next steps:
  1. Open xlsx files in Excel/LibreOffice for EDP metric dashboards
  2. Compare workload performance across configs in workload_logs/
  3. Correlate EMON metrics (IPC, memory BW, LLC miss rate) with performance
  4. Low IPC + high LLC miss → memory bound; low IPC + high BE stalls → backend bound
EOF

cat "$SUMMARY"
```

### 9.7 — Full sweep script layout

When generating a sweep script, follow this order:

```
1.  #!/usr/bin/env bash  (no set -e)
2.  source /opt/intel/sep/sep_vars.sh
3.  EDP path definitions
4.  WORKLOAD_NAME + TIMESTAMP + RESULTS_DIR creation
5.  Sweep dimension arrays + baseline values
6.  Prerequisite checks (binary exists, EDP files exist, emon in PATH)
7.  SEP driver check + insmod-sep if needed
8.  run_config() function
9.  Counter init: TOTAL_TESTS, COMPLETED_TESTS, FAILED_TESTS, START_TIME
10. One for-loop per sweep phase
11. Summary report
```

Running the generated script:
```bash
chmod +x <sweep_script>.sh
sudo ./<sweep_script>.sh 2>&1 | tee sweep_run.log
```

Must run as root — EMON needs kernel driver access.

Monitor live:
```bash
# In a second terminal
watch -n 5 'ls -lh <RESULTS_DIR>/emon_data/*.dat 2>/dev/null | tail -5'
```

---

## Phase 10 — Anomaly investigation with EMON

When EMON is being used to debug unexpected behavior (low throughput, imbalanced
load, degradation over time), use this investigation loop:

```
Observe anomaly
      ↓
Collect EMON during anomalous run + a known-good run for comparison
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

**Never skip to config changes before collecting EMON.** Hardware always tells
the truth. Intuition about where the bottleneck is will often be wrong.

### 10.1 — Reading the Excel output: tab order

Open the post-processed xlsx in this order:

1. **Summary → IPC** — if IPC < 0.5 the CPU is interrupt- or stall-dominated; fix that first
2. **Core view → CPU_CLK_UNHALTED heatmap** — which cores are actually doing work? Concentrated = IRQ affinity wrong
3. **Uncore view → IO BW** — near-zero IO BW = NIC/PCIe problem (not CPU); elevated SCA miss = data not cached
4. **Uncore view → Memory controller** — per-channel imbalance = NUMA mismatch
5. **Core view → interval over time** — IPC drop mid-run = thermal throttle or queue starvation

### 10.2 — The diff approach

The most powerful technique is comparing two EMON traces — one known-good, one
anomalous. The metric delta isolates the effect of exactly one config change:

```bash
# Collect known-good baseline
emon ... -f baseline_good.dat &; sleep 5
<workload with known-good config> > baseline_good_workload.log 2>&1
emon -stop; sleep 2
python3 "$MPP_PY" -i baseline_good.dat ... -o baseline_good.xlsx

# Remove one variable, collect again
emon ... -f test_no_irq_affinity.dat &; sleep 5
<same workload, one thing changed> > test_no_irq_affinity_workload.log 2>&1
emon -stop; sleep 2
python3 "$MPP_PY" -i test_no_irq_affinity.dat ... -o test_no_irq_affinity.xlsx

# Open both xlsx → compare IPC, CLK_UNHALTED distribution, IIO BW
# The delta IS the effect of that one config change
```

### 10.3 — Common hardware-level anomaly signatures

| Anomaly | EMON signal to check | Likely root cause |
|---------|---------------------|-------------------|
| Much lower throughput than expected | `metric_IO read/write BW` near-zero | PCIe link speed downgrade (check `lspci LnkSta`) |
| Uneven per-core CPU load | Per-core `CPU_CLK_UNHALTED` variance | IRQ affinity not set; interrupts landing on one core |
| Throughput OK but spiky | IPC dropping mid-interval; LLC miss rate rising | Thermal throttle; check `dmesg | grep temp` |
| Cross-socket IO | IO BW on socket 0 + IMC activity on socket 1 | NUMA mismatch; NIC DMA crossing NUMA boundary |
| Low IPC (< 0.5) under network workload | `TOPDOWN.BACKEND_BOUND_SLOTS` + `CYCLE_ACTIVITY.STALLS_L3_MISS` | Memory-latency stalls; IRQ storm consuming all cycles |
| mpp.py empty sheets | Near-zero sample count in .dat | EDP events file wrong platform; driver unloaded mid-run |

### 10.4 — DMR-specific event rename notes

On DMR (PantherCove/DiamondRapids), several GNR-era event names were renamed.
Using old names silently collects nothing:

| GNR name | DMR replacement |
|----------|----------------|
| `UNC_IIO_DATA_REQ_OF_CPU.*` | `UNC_ITC_*` (writes) + `UNC_OTC_*` (reads) |
| `RESOURCE_STALLS.*` | `BE_STALLS.*` |
| `IDQ_UOPS_NOT_DELIVERED.CORE` | `IDQ_BUBBLES.CORE` |
| `OFFCORE_REQUESTS.*` | `OFFMODULE_REQUESTS.*` |
| `OFFCORE_RESPONSE.*` | `OMR.*` |
| `UNC_M_RPQ_INSERTS` | `UNC_HAMVF_HA_IMC_READS_COUNT` |
| `UNC_M_WPQ_INSERTS` | `UNC_HAMVF_HA_IMC_WRITES_COUNT.FULL` |

Also note: DMR `UNC_ITC_*` writes use **4B granularity**; `UNC_OTC_*` reads use
**64B granularity**. Do not compare them directly or the write BW will appear
16× higher than it is.

---

## Key rules (always follow)

1. **`-f <dat_file>`** — always use this flag for raw EMON data; never redirect stdout to `.dat`
2. **`emon -stop`** — always stop with this command; never `kill $EMON_PID`
3. **5s sleep** after starting EMON, before launching the workload
4. **2s sleep** after `emon -stop`, before running `mpp.py`
5. **Validate both** the `.dat` (non-empty) and the `.xlsx` (`unzip -t`) after every run
6. **No `set -e`** in sweep scripts — per-config failures must not abort the sweep
7. **Root required** — EMON needs SEP kernel driver access (`sudo` or run as root)
8. **Source `sep_vars.sh` first** — always, every session

Investigation rules:
9. Collect EMON before changing config — let hardware signals drive the hypothesis
10. Always collect a known-good trace for diff comparison
11. Change exactly one variable per test
12. Start with IPC — if low, fix interrupt handling before anything else
13. Near-zero IO BW = PCIe/NIC problem; check uncore view first
14. Cross-tab: core view → IRQ/NUMA diagnosis; uncore view → PCIe/memory diagnosis
