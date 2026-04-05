---
name: benchmark-emon
description: "EMON and perf telemetry collection for benchmark runs. Use when: collecting performance monitoring data, measuring IPC, tracking cache misses, measuring memory bandwidth via PMU, monitoring AMX tile utilization, collecting CPU events during benchmarks, measuring LLC miss rate, identifying hotspots with perf, enabling EMON monitoring."
argument-hint: "[start|stop] [--workload cpu|memory|ai|mixed]"
allowed-tools: Bash
---

# EMON / Perf Telemetry Collection

Collects hardware performance counter data during benchmark execution.
Detects Intel EMON (`emon` binary) and falls back to Linux `perf stat`.
Events are selected per workload type to surface the most relevant bottleneck signals.

## Variables Required

| Variable | Description | Example |
|---|---|---|
| `$LAB_HOST` | SSH target | `lab-target` |
| `$SESSION_ID` | Current session identifier | `20260405T120000-a3f9c1` |
| `$OUTPUT_DIR` | Remote results directory | `/tmp/benchmarks/2026-04-05/` |

## Variables Exported by This Skill

| Variable | Description |
|---|---|
| `$EMON_PID` | PID of background collection process on remote host |
| `$EMON_OUTPUT_DIR` | Remote path to EMON/perf output files |
| `$EMON_TOOL` | `emon` or `perf` (whichever was used) |

---

## Workload-Specific PMU Event Sets

### CPU workload (`--workload cpu`)
```
cycles
instructions
cache-references
cache-misses
branch-instructions
branch-misses
L1-dcache-load-misses
LLC-loads
LLC-load-misses
cpu-migrations
context-switches
page-faults
```

### Memory workload (`--workload memory`)
```
cycles
instructions
LLC-load-misses
LLC-store-misses
mem_load_retired.l3_miss
mem_load_retired.fb_hit
mem_inst_retired.all_loads
mem_inst_retired.all_stores
offcore_response.demand_data_rd.any_response
cpu-migrations
page-faults
```

### AI / AMX workload (`--workload ai`)
```
cycles
instructions
amx_retired.int8_type
amx_retired.bf16_type
fp_arith_inst_retired.512b_packed_single
fp_arith_inst_retired.512b_packed_double
fp_arith_inst_retired.1024b_packed_bfloat16
LLC-load-misses
mem_load_retired.l3_miss
cache-misses
```

### Mixed workload (`--workload mixed`)
Union of CPU + Memory event sets (use `perf stat -e` with comma-separated list).

---

## Step 1 — Detect Available Tool

```bash
ssh $LAB_HOST "
if command -v emon &>/dev/null; then
    echo 'EMON_TOOL=emon'
    emon --version 2>/dev/null | head -1
elif command -v perf &>/dev/null; then
    echo 'EMON_TOOL=perf'
    perf --version
else
    echo 'EMON_TOOL=none'
    echo 'WARNING: Neither emon nor perf found — installing perf...'
    dnf install -y perf 2>/dev/null
fi
"
```

---

## Step 2 — Start Collection

Argument: `start --workload <type>`

### Using Intel EMON
```bash
EMON_OUTPUT_DIR="${OUTPUT_DIR}/emon"
ssh $LAB_HOST "mkdir -p ${EMON_OUTPUT_DIR}"

ssh $LAB_HOST "nohup emon \
    -collect-edp \
    -f ${EMON_OUTPUT_DIR}/emon_data.txt \
    > ${EMON_OUTPUT_DIR}/emon.log 2>&1 &
echo \$! > ${EMON_OUTPUT_DIR}/emon.pid
echo 'EMON started, PID: '\$(cat ${EMON_OUTPUT_DIR}/emon.pid)"
```

### Using Linux perf stat (fallback)

Select the event string based on `$WORKLOAD_TYPE`:

```bash
EMON_OUTPUT_DIR="${OUTPUT_DIR}/perf"
ssh $LAB_HOST "mkdir -p ${EMON_OUTPUT_DIR}"

# Build event string for the workload type (set EVENTS based on table above)
case "${WORKLOAD_TYPE}" in
    cpu)    EVENTS="cycles,instructions,cache-references,cache-misses,branch-instructions,branch-misses,L1-dcache-load-misses,LLC-loads,LLC-load-misses,cpu-migrations,context-switches,page-faults" ;;
    memory) EVENTS="cycles,instructions,LLC-load-misses,LLC-store-misses,mem_load_retired.l3_miss,mem_inst_retired.all_loads,mem_inst_retired.all_stores,cpu-migrations,page-faults" ;;
    ai)     EVENTS="cycles,instructions,amx_retired.int8_type,amx_retired.bf16_type,fp_arith_inst_retired.512b_packed_single,fp_arith_inst_retired.1024b_packed_bfloat16,LLC-load-misses,cache-misses" ;;
    mixed)  EVENTS="cycles,instructions,cache-misses,branch-misses,LLC-load-misses,LLC-store-misses,mem_load_retired.l3_miss,cpu-migrations,page-faults" ;;
esac

ssh $LAB_HOST "nohup perf stat \
    -e ${EVENTS} \
    -a \
    --interval-print 5000 \
    -o ${EMON_OUTPUT_DIR}/perf_stat.txt \
    sleep 86400 \
    > ${EMON_OUTPUT_DIR}/perf.log 2>&1 &
echo \$! > ${EMON_OUTPUT_DIR}/perf.pid
echo 'perf stat started, PID: '\$(cat ${EMON_OUTPUT_DIR}/perf.pid)"
```

Export:
```bash
export EMON_PID=$(ssh $LAB_HOST "cat ${EMON_OUTPUT_DIR}/*.pid")
export EMON_OUTPUT_DIR
export EMON_TOOL
```

---

## Step 3 — Stop Collection

Argument: `stop`

```bash
# Stop the collection process
ssh $LAB_HOST "
PID=\$(cat ${EMON_OUTPUT_DIR}/*.pid 2>/dev/null)
if [ -n \"\$PID\" ]; then
    kill -INT \$PID 2>/dev/null || kill \$PID 2>/dev/null
    sleep 3
    echo 'EMON/perf collection stopped (PID '\$PID')'
else
    echo 'WARNING: No PID file found — collection may have already stopped'
fi
"

# Allow time for final flush to disk
sleep 5

# Verify output was written
ssh $LAB_HOST "
ls -lh ${EMON_OUTPUT_DIR}/
wc -l ${EMON_OUTPUT_DIR}/*.txt ${EMON_OUTPUT_DIR}/*.csv 2>/dev/null
"
```

---

## Step 4 — Retrieve Data Locally

```bash
mkdir -p ./results/${SESSION_ID}/emon
scp -r ${LAB_HOST}:${EMON_OUTPUT_DIR}/ ./results/${SESSION_ID}/emon/
echo "EMON data saved to ./results/${SESSION_ID}/emon/"
```

---

## Step 5 — Quick Parse for Report

```python
import re, os

SESSION_ID = os.environ.get('SESSION_ID', 'unknown')
emon_dir = f'./results/{SESSION_ID}/emon'

def parse_perf_stat(path):
    metrics = {}
    try:
        text = open(path).read()
        # Parse "value  event-name" lines
        for line in text.splitlines():
            m = re.match(r'\s*([\d,]+)\s+([\w\-\.]+)', line)
            if m:
                val_str = m.group(1).replace(',', '')
                try:
                    metrics[m.group(2)] = int(val_str)
                except ValueError:
                    pass
    except FileNotFoundError:
        pass
    return metrics

perf_file = f'{emon_dir}/perf_stat.txt'
metrics = parse_perf_stat(perf_file)

if metrics:
    cycles = metrics.get('cycles', 0)
    instrs = metrics.get('instructions', 0)
    ipc    = instrs / cycles if cycles > 0 else 0
    llc_misses = metrics.get('LLC-load-misses', 0)
    llc_loads  = metrics.get('LLC-loads', 1)
    llc_miss_rate = llc_misses / llc_loads * 100 if llc_loads > 0 else 0

    print("EMON / PERF SUMMARY")
    print("=" * 40)
    print(f"IPC              : {ipc:.2f}  (healthy: >1.5 for compute, >0.8 for memory)")
    print(f"LLC Miss Rate    : {llc_miss_rate:.1f}%  (elevated: >5% indicates DRAM pressure)")
    for k, v in metrics.items():
        if k not in ('cycles', 'instructions', 'LLC-loads', 'LLC-load-misses'):
            print(f"{k:<25}: {v:,}")
else:
    print("EMON data not yet parsed — run benchmark-analyze for full interpretation.")
```

---

## Report Format

```
EMON COLLECTION
===============
Tool         : emon / perf stat
Workload     : <cpu|memory|ai|mixed>
Events       : <N> event counters
Output       : ./results/<session-id>/emon/

QUICK SIGNALS (for benchmark-analyze)
--------------------------------------
IPC          : <value>
LLC Miss Rate: <X>%
<event>      : <value>
```
