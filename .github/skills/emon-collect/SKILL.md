---
name: emon-collect
description: "Collect EMON hardware counter data in parallel with any user workload, save as a raw .dat file, and post-process to an Excel EDP report (.xlsx). Use when: running EMON alongside a workload, profiling a workload with hardware counters, collecting EMON while a benchmark runs, capturing CPU performance metrics during any job, recording EMON to .dat file, converting EMON .dat to xlsx, post-processing existing EMON .dat file, attaching EMON collection to an existing command."
argument-hint: "[collect|postprocess]"
allowed-tools: Bash
---

# EMON Collect — Parallel EMON Collection for Any Workload

Teaches Copilot how to wrap **any user-provided workload command** with EMON
hardware counter collection running in the background, save the raw output to a
`.dat` file, and post-process it to an Excel EDP report via `mpp.py`.

Use `$ARGUMENTS` to select mode:
- `collect` — set up prerequisites, run workload + EMON, produce `.dat`
- `postprocess` — post-process an existing `.dat` to `.xlsx`
- *(blank)* — full flow: collect then post-process

---

## Phase 0 — Understand the user's workload

Before doing anything, ask the user for:

1. **Workload command** — the exact shell command (or script path) to run. This
   runs in the **foreground**; EMON collects in the **background** during its
   execution.
2. **Run label** — a short name used for output file naming (default: derive
   from the binary name, e.g. `mlc`, `iperf3`, `llama-bench`).
3. **Output directory** — where to save `.dat`, logs, and `.xlsx` (default:
   `~/emon_<label>_<timestamp>/`). Must be writable.
4. **Warm-up needed?** — should the workload run once without EMON first to
   warm up caches/JIT before the measured run? (default: no)
5. **Run count** — how many timed EMON+workload runs to do (default: 1). If >1,
   each run gets its own `.dat` and `.xlsx`.

Do **not** assume any of these values. Collect them interactively before
proceeding.

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
