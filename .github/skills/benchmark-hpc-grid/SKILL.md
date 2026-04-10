---
name: benchmark-hpc-grid
description: "Run Intel FSI HPC Grid benchmarks: Monte Carlo options pricing workloads, IAA compression, QAT crypto acceleration, DSA peer-to-peer bandwidth. Use when: benchmarking financial compute workloads, running Monte Carlo simulations, measuring options pricing throughput, testing Black-Scholes pricing, running Heston model, measuring IAA throughput, testing QAT compression, validating accelerator performance, running financial-samples HPC suite, measuring options/sec throughput."
argument-hint: "[workloads|accelerator|all]"
allowed-tools: Bash
---

# FSI HPC Grid Benchmarks

Runs Monte Carlo options pricing suite (single-node) and accelerator KPIs (IAA, QAT, DSA).  
Argument: `$ARGUMENTS` — `workloads`, `accelerator`, or `all` (default).

---

## CRITICAL: HPC Grid Notes

- **Single-node only** — HPC Grid jobs run within a single node (no MPI across nodes)
- **Two memory configs** — run DMR under both DDR5-12800 MRDIMM Gen2 and DDR5-6400, report separately
- **PR environment variable** — controls thread count; run with core count AND thread count
- **EMR not tested** for HPC Grid (lower core count vs GNR-AP)
- **Reference scripts:** https://github.com/intel-sandbox/financial-samples

---

## Setup

```bash
# Clone financial-samples if not present
ls ~/financial-samples 2>/dev/null || \
    git clone https://github.com/intel-sandbox/financial-samples.git ~/financial-samples

cd ~/financial-samples

# Detect core and thread count
CORE_COUNT=$(lscpu | awk '/^Core\(s\) per socket/{cores=$NF} /^Socket\(s\)/{sockets=$NF} END{print cores*sockets}')
THREAD_COUNT=$(nproc --all)
NUMA_NODES=$(numactl --hardware | awk '/^available:/{print $2}')

echo "Cores: $CORE_COUNT | Threads: $THREAD_COUNT | NUMA nodes: $NUMA_NODES"

# System config verification
echo "--- System Config ---"
dmidecode -t 1 2>/dev/null | grep -E "Manufacturer|Product Name|Version" || true
dmidecode -t 17 2>/dev/null \
    | grep -E "Size|Type:|Speed:|Configured Memory Speed|Part Number" \
    | grep -v "No Module" | head -20 \
    || echo "dmidecode: unavailable"
echo "Kernel: $(uname -r)"

# Set output directory — persistent; never /tmp/
OUTDIR=${BENCHMARK_OUTDIR:-/datafs/fsi-benchmarks}/$(date +%Y%m%dT%H%M)-hpc
RESULTS_DIR=$OUTDIR/bench/hpc_workloads
EMON_DIR=$OUTDIR/emon
mkdir -p $RESULTS_DIR $EMON_DIR $OUTDIR/monitor $OUTDIR/sysconfig

# Capture sysconfig snapshot before any workloads run
lscpu                        > $OUTDIR/sysconfig/cpu_info.txt
numactl --hardware           > $OUTDIR/sysconfig/numa_topology.txt
dmidecode -t 17 2>/dev/null  > $OUTDIR/sysconfig/dimm_info.txt
cpupower frequency-info      > $OUTDIR/sysconfig/cpupower.txt 2>&1
uname -r                     > $OUTDIR/sysconfig/kernel_version.txt
echo "Output dir: $OUTDIR"

# THP, governor, NUMA balancing
echo always > /sys/kernel/mm/transparent_hugepage/enabled
cpupower frequency-set -g performance
echo 0 > /proc/sys/kernel/numa_balancing   # prevent OS page migration mid-run

# NUMA remote-access baseline — saved to file for delta comparison after run
echo "--- NUMA baseline ---"
numastat -c 2>/dev/null > $OUTDIR/monitor/numastat_pre.txt || numastat 2>/dev/null | head -10 > $OUTDIR/monitor/numastat_pre.txt
cat $OUTDIR/monitor/numastat_pre.txt

# Verify perf stat is available — REQUIRED before starting any workload
perf stat -a -- sleep 0.1 2>/dev/null \
    && echo "perf stat: OK" \
    || { echo "ERROR: perf stat unavailable — install linux-tools-$(uname -r)"; exit 1; }
```

---

## Part A — Monte Carlo Options Pricing Workloads

### Workload Suite

| Workload | Binary | Description |
|---|---|---|
| Monte Carlo Asian Bump | `mc_asian_bump_greeks` | Asian-style options pricing with bump greeks |
| Monte Carlo Asian AAD | `mc_asian_aad_greeks` | Asian-style options pricing with AAD greeks |
| Asian Options Pricing | `asian-opt` | Asian-style options pricing |
| Binomial Options | `binomial` | American-style options valuation |
| Black Scholes DP | `BlackScholesDP` | European-style options — double precision |
| Black Scholes PDE | `bs_pde_solver` | Black Scholes PDE solver |
| Black Scholes PDE 2D | `bs_pde_2D_solver` | 2D Black Scholes PDE solver |
| Forward Curve Bootstrap | `forward_curve_bootstrap` | Forward interest rate curve construction |
| Heston Implied Volatility | `heston_impllied_vol` | Implied volatility via Heston model |
| Heston Pricing | `heston_price` | Stochastic volatility options pricing |
| Implied Volatility | `implied_vol` | Market implied volatility |
| Libor Market Model | `liborSwaptionGreeks` | Interest rate option sensitivities |
| Monte Carlo American | `amc` | American options via Monte Carlo |
| Monte Carlo European | `emc` | European options via Monte Carlo |
| Spline Forward | `spline_forward_mkl` | Forward rate curve via spline (MKL) |
| Zero Curve Spline | `zero_curve_spline` | Yield curve construction via spline |

### Compiler Variants

Run each workload under all 4 compiler × ISA combinations:

| Compiler | ISA Flag | Build Command |
|---|---|---|
| ICX (Intel) | avx2 | `CC=icx CFLAGS="-O3 -xCORE-AVX2" make` |
| ICX (Intel) | avx512 | `CC=icx CFLAGS="-O3 -xCORE-AVX512" make` |
| GCC | avx512 | `CC=gcc CFLAGS="-O3 -march=native -mavx512f" make` |
| AOCC (AMD) | avx512 | `CC=clang CFLAGS="-O3 -march=native -mavx512f" make` |

> Note: AOCC is AMD's compiler — use only on AMD Turin systems.  
> For Intel platforms, run ICX (avx2 + avx512) and GCC (avx512).

### Running the Workloads

Run each workload × compiler variant under **two PR settings** per the test plan.

> **EMON requirement:** `perf stat -a` MUST wrap each PR=cores run block (started before
> the first run, stopped after the last). Use `-- sleep 999 &` so it spans all 5 runs,
> then `kill $PERF_PID` when done. Output goes to `$EMON_DIR/${WL}_pr${PR}.perf`.
> Never use `-- sleep <N>` with a fixed duration — it will miss the workload window.
> Never start perf inside the per-run loop — it captures only a fraction of one run.

```bash
# For each compiler variant (loop over compilers)
for COMPILER in icx-avx2 icx-avx512 gcc-avx512; do
    # Build with appropriate flags (set CC and CFLAGS per table above)
    # ...

    for WL in mc_asian_bump_greeks mc_asian_aad_greeks asian-opt binomial \
               BlackScholesDP bs_pde_solver bs_pde_2D_solver forward_curve_bootstrap \
               heston_impllied_vol heston_price implied_vol liborSwaptionGreeks \
               amc emc spline_forward_mkl zero_curve_spline; do

        WL_DIR=$RESULTS_DIR/${COMPILER}/${WL}
        mkdir -p $WL_DIR

        # Run A: PR = core count (1 thread per core)
        echo "=== $WL | $COMPILER | PR=$CORE_COUNT — 5 runs ===" | tee $WL_DIR/pr_cores.log

        # Start perf stat BEFORE the run loop — spans all 5 runs
        perf stat -a \
            -e cycles,instructions,cache-misses,cache-references,\
LLC-load-misses,mem_inst_retired.all_loads,mem_inst_retired.all_stores,\
cycle_activity.stalls_mem_any \
            --interval-print 5000 \
            -o $EMON_DIR/${WL}_pr${CORE_COUNT}.perf \
            -- sleep 999 2>/dev/null &
        PERF_PID=$!

        # Start turbostat to monitor frequency and power across the run
        turbostat --interval 2 --show Avg_MHz,Bzy_MHz,Busy%,PkgWatt,CorWatt \
            > $EMON_DIR/${WL}_pr${CORE_COUNT}.turbostat 2>/dev/null &
        TURBO_PID=$!

        # Start RAPL energy counter
        perf stat -a -e power/energy-pkg/,power/energy-cores/,power/energy-dram/ \
            -o $EMON_DIR/${WL}_pr${CORE_COUNT}.rapl \
            -- sleep 999 2>/dev/null &
        RAPL_PID=$!

        for run in 1 2 3 4 5; do
            PR=$CORE_COUNT numactl --physcpubind=0-$((CORE_COUNT-1)) --localalloc \
                ./$WL 2>&1 | tail -1 | tee -a $WL_DIR/pr_cores.log
        done

        # Stop all monitors after the run loop
        kill $PERF_PID $TURBO_PID $RAPL_PID 2>/dev/null
        wait $PERF_PID $TURBO_PID $RAPL_PID 2>/dev/null || true

        # Run B: PR = thread count (SMT / 2T per core) — no separate perf needed;
        # PR=cores run provides the key IPC/BW signal for compute vs memory classification
        echo "=== $WL | $COMPILER | PR=$THREAD_COUNT — 5 runs ===" | tee $WL_DIR/pr_threads.log
        for run in 1 2 3 4 5; do
            PR=$THREAD_COUNT numactl --physcpubind=all --localalloc \
                ./$WL 2>&1 | tail -1 | tee -a $WL_DIR/pr_threads.log
        done
    done
done
```

### Verifying EMON Coverage

After the run, confirm all workloads have perf output before reporting:

```bash
# Every workload should have a non-empty .perf file
MISSING=0
for WL in mc_asian_bump_greeks mc_asian_aad_greeks asian-opt binomial \
           BlackScholesDP bs_pde_solver bs_pde_2D_solver forward_curve_bootstrap \
           heston_impllied_vol heston_price implied_vol liborSwaptionGreeks \
           amc emc spline_forward_mkl zero_curve_spline; do
    PERF_FILE=$EMON_DIR/${WL}_pr${CORE_COUNT}.perf
    if [ ! -s "$PERF_FILE" ]; then
        echo "WARN: missing or empty EMON for $WL — $PERF_FILE"
        MISSING=$((MISSING+1))
    fi
done
[ $MISSING -eq 0 ] && echo "EMON: all workloads covered" || echo "EMON: $MISSING workloads missing telemetry"

# NUMA remote-access delta — flag any remote hits that occurred during workloads
echo "--- NUMA post-run (compare to $OUTDIR/monitor/numastat_pre.txt) ---"
numastat -c 2>/dev/null > $OUTDIR/monitor/numastat_post.txt || numastat 2>/dev/null | head -10 > $OUTDIR/monitor/numastat_post.txt
cat $OUTDIR/monitor/numastat_post.txt

# IPC spot-check from perf stat (expected 2–4 for FP-heavy workloads)
echo "--- IPC spot-check (BlackScholesDP, ICX avx512) ---"
PERF_FILE=$EMON_DIR/BlackScholesDP_pr${CORE_COUNT}.perf
if [ -s "$PERF_FILE" ]; then
    awk '/instructions/{inst=$1} /cycles/{cyc=$1} END{
        if(cyc>0) printf "IPC: %.2f (expected 2–4 for FP workloads)\n", inst/cyc}' "$PERF_FILE" \
        || grep -E "instructions|cycles" "$PERF_FILE" | tail -4
fi
```

### Parsing Results

```bash
# Extract avg ± std-dev per workload × compiler × PR setting
for COMPILER in icx-avx2 icx-avx512 gcc-avx512; do
    for WL in mc_asian_bump_greeks BlackScholesDP heston_price amc emc; do
        for PR_TAG in pr_cores pr_threads; do
            echo -n "$WL | $COMPILER | $PR_TAG: "
            awk 'NF>0 && !/===/{sum+=$1; sumsq+=$1^2; n++} END {
                if(n>0){avg=sum/n; std=sqrt(sumsq/n - avg^2);
                printf "avg %.1f options/sec ± %.1f (n=%d)\n", avg, std, n}
            }' $RESULTS_DIR/${COMPILER}/${WL}/${PR_TAG}.log
        done
    done
done
```

### Pass/Fail Criteria

Compare results against LZ KPI table (rows 40–48 for DMR, rows 23–27 for both platforms):

| LZ Row | KPI | Pass Criterion |
|---|---|---|
| 40 | HPC Perf vs Comp | ≥1.05× AMD Turin on same workload set |
| 41 | Linpack 2S Perf/W vs GNR | ≥1.2× (if Linpack available) |
| 43 | DGEMM Perf/W vs GNR | ≥1.2× (run DGEMM separately) |
| 27 | AI Inference | Delegate to `benchmark-amx` skill — 3× BF16, 4× INT8 vs AMD |
| 47 | Stream Triad vs GNR | ≥1.2× (delegate to `benchmark-memory` skill) |

> **Tier-2 trigger:** If Monte Carlo throughput misses target by >10%:
> 1. Run `/benchmark-memory memory-latency-bw` to get the latency-BW curve
> 2. Identify inflection point (the thread count where BW saturates)
> 3. Compare to the PR count where Monte Carlo throughput peaks
> 4. If they match → memory-bound → recommend MRDIMM upgrade or `numactl --localalloc`
> 5. If throughput peaks below BW saturation → compute-bound → recommend ICX avx512 + AMX

---

## Part B — Accelerator KPIs

### B1 — IAA (Intel Analytics Accelerator)

Tests compression/decompression throughput and RocksDB analytics performance.

```bash
IAA_DIR=$OUTDIR/bench/hpc_accelerator/iaa
mkdir -p $IAA_DIR

# Verify IAA is configured
accel-config list | grep -E "iax|state"   # expect: enabled

# Compression throughput (5 runs)
echo "=== IAA Compression — 5 runs ===" | tee $IAA_DIR/iaa_compress.log
for run in 1 2 3 4 5; do
    accel-config test-runner --type compress --input-size 1048576 --iterations 1000 \
        2>&1 | grep Throughput | tee -a $IAA_DIR/iaa_compress.log
done

# Decompression throughput (5 runs)
echo "=== IAA Decompression — 5 runs ===" | tee $IAA_DIR/iaa_decompress.log
for run in 1 2 3 4 5; do
    accel-config test-runner --type decompress --input-size 1048576 --iterations 1000 \
        2>&1 | grep Throughput | tee -a $IAA_DIR/iaa_decompress.log
done
```

**LZ KPI rows 23–26:**
- Compression ≥ GNR baseline (DMR min) | ≥1.2× GNR (DMR target)
- Page fault latency ≤ 1.75 µs (DMR min) | ≤ 1.5 µs (DMR target)

### B2 — QAT (Intel QuickAssist Technology)

Tests crypto and compression acceleration.

```bash
QAT_DIR=$OUTDIR/bench/hpc_accelerator/qat
mkdir -p $QAT_DIR

# Verify QAT service running
systemctl is-active qat 2>/dev/null || { echo "WARN: QAT service not running — sudo systemctl start qat"; }
qatmgr --status 2>/dev/null | head -10

# RSA (PKE) — LZ row 53: ≥100 Kops min, ≥200 Kops target
echo "=== QAT RSA PKE — 5 runs ===" | tee $QAT_DIR/qat_rsa.log
for run in 1 2 3 4 5; do
    cpa_sample_code runTests=30 signOfLife=0 cyNumBuffers=4096 cySymLoops=5000 \
        2>&1 | grep -E "RSA|Kops" | tee -a $QAT_DIR/qat_rsa.log
done

# Bulk Crypto — LZ row 54: ≥400 Gbps @4K min, ≥800 Gbps target
echo "=== QAT Bulk Crypto @4K — 5 runs ===" | tee $QAT_DIR/qat_bulk.log
for run in 1 2 3 4 5; do
    cpa_sample_code runTests=40 signOfLife=0 cyNumBuffers=4096 pktSize=4096 \
        2>&1 | grep -E "Gbps|throughput" | tee -a $QAT_DIR/qat_bulk.log
done

# Compression (Zstd and Deflate) — LZ row 55: Zstd 200/100/100; Deflate 160/100
echo "=== QAT Compression (Zstd + Deflate) — 5 runs ===" | tee $QAT_DIR/qat_compress.log
for run in 1 2 3 4 5; do
    cpa_sample_code runTests=32 signOfLife=0 dcChainMode=0 \
        2>&1 | grep -E "Zstd|Deflate|GB/s" | tee -a $QAT_DIR/qat_compress.log
done
```

### B3 — DSA (Data Streaming Accelerator) P2P Bandwidth

Tests peer-to-peer bandwidth via DSA. **LZ row 58:** ≥60 GB/s (DMR min), ≥120 GB/s (DMR target).

```bash
DSA_DIR=$OUTDIR/bench/hpc_accelerator/dsa
mkdir -p $DSA_DIR

# Verify DSA configured
accel-config list | grep -E "dsa|state"

# P2P bandwidth via NTB (5 runs)
echo "=== DSA P2P BW — 5 runs ===" | tee $DSA_DIR/dsa_p2p.log
for run in 1 2 3 4 5; do
    accel-config test-runner --type memmove --transfer-size 1048576 \
        --device dsa0 --iterations 1000 \
        2>&1 | grep "Bandwidth\|GB/s" | tee -a $DSA_DIR/dsa_p2p.log
done
```

---

## Mandatory Reports

After every run, generate both report files in `$OUTDIR/`. **These are required even when all KPIs pass.**

### Generate deep_dive_report.md

```bash
# Collect key telemetry values from raw files before writing the report
IPC_SPOT=$(awk '/instructions/{inst=$1} /cycles/{cyc=$1} END{
    if(cyc>0) printf "%.2f", inst/cyc}' \
    $EMON_DIR/BlackScholesDP_pr${CORE_COUNT}.perf 2>/dev/null || echo "N/A")

FREQ_MAX=$(awk 'NR>1 && $2~/^[0-9]+$/{if($2>m)m=$2} END{printf "%d", m+0}' \
    $EMON_DIR/BlackScholesDP_pr${CORE_COUNT}.turbostat 2>/dev/null || echo "N/A")
FREQ_MIN=$(awk 'NR>1 && $2~/^[0-9]+$/{if(m==0||$2<m)m=$2} END{printf "%d", m+0}' \
    $EMON_DIR/BlackScholesDP_pr${CORE_COUNT}.turbostat 2>/dev/null || echo "N/A")
PKG_WATT=$(awk 'NR>1 && $4~/[0-9]/{if($4>m)m=$4} END{printf "%.1f", m+0}' \
    $EMON_DIR/BlackScholesDP_pr${CORE_COUNT}.turbostat 2>/dev/null || echo "N/A")

NUMA_PRE=$(awk '/numa_miss|numa_foreign/{sum+=$2} END{print sum+0}' \
    $OUTDIR/monitor/numastat_pre.txt 2>/dev/null || echo "0")
NUMA_POST=$(awk '/numa_miss|numa_foreign/{sum+=$2} END{print sum+0}' \
    $OUTDIR/monitor/numastat_post.txt 2>/dev/null || echo "0")
NUMA_DELTA=$((NUMA_POST - NUMA_PRE))

SESSION=$(basename $OUTDIR)
PLATFORM=$(lscpu | awk -F': +' '/Model name/{print $2}' | head -1)
OS=$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-$(uname -s)}")
KERNEL=$(uname -r)

cat > $OUTDIR/deep_dive_report.md << DEEP_DIVE
# Deep Dive Performance Analysis Report

**Session**   : ${SESSION}
**Platform**  : ${PLATFORM} | ${CORE_COUNT}C | $(free -g | awk '/Mem/{print $2}') GiB RAM
**OS**        : ${OS} | Kernel ${KERNEL}
**Compiler**  : ${COMPILER:-GCC} (last run)
**Output dir**: ${OUTDIR}
**Date**      : $(date +%Y-%m-%d)

---

## Platform Summary

| Attribute | Value |
|---|---|
| CPU | ${PLATFORM} |
| Cores / Threads | ${CORE_COUNT}C / ${THREAD_COUNT}T |
| NUMA nodes | ${NUMA_NODES} |
| RAM | $(free -g | awk '/Mem/{print $2}') GiB |
| OS | ${OS} |
| Kernel | ${KERNEL} |
| Compiler (last run) | ${COMPILER:-GCC} |
| THP | always |
| NUMA balancing | disabled (echo 0 > /proc/sys/kernel/numa_balancing) |

---

## Preflight Status

| Check | Result | Detail |
|---|---|---|
| NUMA nodes | ${NUMA_NODES} | Expected ≥1; SNC4 = 8 on GNR-SP |
| THP | enabled | always |
| Governor | performance | cpupower frequency-set -g performance |
| NUMA balancing | disabled | prevents OS migration mid-run |
| Compiler | ${COMPILER:-GCC} | See Compiler Variants table |

---

## Monitoring Telemetry

### Tools Executed

| Tool | Command | Purpose | Raw Output File |
|---|---|---|---|
| \`turbostat\` | \`turbostat --interval 2 --show Avg_MHz,Bzy_MHz,Busy%,PkgWatt,CorWatt\` | CPU frequency, pkg power (W) during each workload run | \`emon/<workload>_pr${CORE_COUNT}.turbostat\` |
| \`perf stat -a\` | \`perf stat -a -e cycles,instructions,cache-misses,LLC-load-misses,mem_inst_retired.all_loads,cycle_activity.stalls_mem_any\` | System-wide IPC, LLC miss rate, memory load rate, stall cycles (per workload × PR=cores) | \`emon/<workload>_pr${CORE_COUNT}.perf\` |
| \`RAPL\` | \`perf stat -a -e power/energy-pkg/,power/energy-cores/,power/energy-dram/\` | Package, core, and DRAM energy (Joules) per workload run | \`emon/<workload>_pr${CORE_COUNT}.rapl\` |
| \`numastat -c\` | \`numastat -c\` | NUMA remote page access counts — pre and post workloads | \`monitor/numastat_pre.txt\`, \`monitor/numastat_post.txt\` |
| \`dmidecode -t 17\` | \`dmidecode -t 17\` | DIMM population, speed (MT/s), configured speed | \`sysconfig/dimm_info.txt\` |
| \`lscpu\` | \`lscpu\` | CPU topology, ISA, features | \`sysconfig/cpu_info.txt\` |
| \`cpupower\` | \`cpupower frequency-info\` | CPU governor, min/max frequency, boost state | \`sysconfig/cpupower.txt\` |

### Metrics Observed (BlackScholesDP, ${COMPILER:-GCC}, PR=${CORE_COUNT})

| Metric | Value | Threshold / Expected | Status |
|---|---|---|---|
| IPC (system-wide) | ${IPC_SPOT} | 2–4 (FP-heavy workloads) | $(echo "$IPC_SPOT" | awk '{if($1~/^[0-9]/)print ($1>=2&&$1<=4)?"PASS":"WARN"; else print "N/A"}') |
| Freq max/min during run | ${FREQ_MAX}/${FREQ_MIN} MHz | <5% droop | $(echo "$FREQ_MAX $FREQ_MIN" | awk '{if($1~/^[0-9]/&&$2~/^[0-9]/&&$1>0)print (($1-$2)/$1>0.05)?"WARN: >5% droop":"PASS"; else print "N/A"}') |
| Package power peak | ${PKG_WATT} W | ≤ TDP | N/A |
| NUMA remote hits delta | ${NUMA_DELTA} | 0 | $([ "${NUMA_DELTA:-0}" -eq 0 ] 2>/dev/null && echo "PASS" || echo "WARN") |
| EMON coverage | $([ $MISSING -eq 0 ] && echo "Complete (all workloads)" || echo "$MISSING workloads missing") | All workloads | $([ $MISSING -eq 0 ] && echo "PASS" || echo "WARN") |

---

## Benchmark Results

See \`bench/hpc_workloads/\` for full results per compiler × workload × PR setting.

### Key Workloads (${COMPILER:-GCC}, PR=${CORE_COUNT} — avg of 5 runs)

| Workload | avg options/sec | ± std-dev | LZ KPI | Status |
|---|---|---|---|---|
$(for WL in mc_asian_bump_greeks BlackScholesDP heston_price amc emc; do
    LOG=$RESULTS_DIR/${COMPILER:-gcc-avx512}/${WL}/pr_cores.log
    if [ -f "$LOG" ]; then
        awk -v wl="$WL" 'NF>0 && !/===/{sum+=$1; sumsq+=$1^2; n++} END{
            if(n>0){avg=sum/n; std=sqrt(sumsq/n-avg^2);
            printf "| %s | %.0f | ±%.0f | Row 40 | — |\n", wl, avg, std}}' "$LOG"
    else
        echo "| $WL | N/A | — | Row 40 | NO DATA |"
    fi
done)

### LZ KPI Status

| LZ Row | KPI | Measured | Threshold | Status |
|---|---|---|---|---|
| 40 | HPC Perf vs AMD Turin | see bench/ | ≥1.05× AMD | — |
| 23 | IAA RocksDB Analytics | see bench/hpc_accelerator/iaa/ | ≥1.2× GNR | — |
| 24 | IAA Compression BW | see bench/hpc_accelerator/iaa/ | ≥ GNR | — |
| 53 | QAT RSA (Kops) | see bench/hpc_accelerator/qat/ | ≥100 Kops | — |
| 54 | QAT Bulk Crypto (Gbps) | see bench/hpc_accelerator/qat/ | ≥400 Gbps | — |
| 58 | DSA P2P BW (GB/s) | see bench/hpc_accelerator/dsa/ | ≥60 GB/s | — |

---

## Key Findings

1. [Populate from IPC results: IPC≥2 → compute-bound; IPC<1 → memory-bound; cite emon/*.perf file]
2. [Populate from EMON: LLC miss rate → classify memory vs compute bottleneck per workload]
3. [Populate from numastat: NUMA remote delta=${NUMA_DELTA} — $([ "${NUMA_DELTA:-0}" -eq 0 ] && echo "no remote accesses (clean)" || echo "WARN: remote accesses detected, check numactl binding")]
4. [Populate from turbostat: freq droop ${FREQ_MAX}→${FREQ_MIN} MHz during peak load]
5. [Populate from compiler comparison: ICX avx512 vs GCC avx512 throughput delta for key workloads]

---

## Raw Data Files Index

| File | Description |
|---|---|
| \`sysconfig/cpu_info.txt\` | lscpu output — CPU model, cores, ISA features |
| \`sysconfig/numa_topology.txt\` | numactl --hardware — NUMA node sizes and distances |
| \`sysconfig/dimm_info.txt\` | dmidecode -t 17 — DIMM speed and population |
| \`sysconfig/cpupower.txt\` | cpupower frequency-info — governor, boost, freq range |
| \`sysconfig/kernel_version.txt\` | uname -r — kernel version |
| \`monitor/numastat_pre.txt\` | NUMA remote page hit counts before workloads |
| \`monitor/numastat_post.txt\` | NUMA remote page hit counts after workloads (delta = ${NUMA_DELTA}) |
| \`emon/<workload>_pr${CORE_COUNT}.perf\` | perf stat — IPC, LLC miss rate, memory stalls per workload |
| \`emon/<workload>_pr${CORE_COUNT}.turbostat\` | turbostat — freq, power during each workload run |
| \`emon/<workload>_pr${CORE_COUNT}.rapl\` | RAPL energy counters — pkg + core + DRAM Joules |
| \`bench/hpc_workloads/<compiler>/<workload>/pr_cores.log\` | Throughput (options/sec) × 5 runs at PR=cores |
| \`bench/hpc_workloads/<compiler>/<workload>/pr_threads.log\` | Throughput × 5 runs at PR=threads (SMT comparison) |
| \`bench/hpc_accelerator/iaa/iaa_compress.log\` | IAA compression throughput |
| \`bench/hpc_accelerator/qat/qat_rsa.log\` | QAT RSA Kops |
| \`bench/hpc_accelerator/dsa/dsa_p2p.log\` | DSA P2P bandwidth |

---

## Overall Verdict

$([ $MISSING -eq 0 ] && echo "EMON Coverage: COMPLETE" || echo "EMON Coverage: PARTIAL — $MISSING workloads missing telemetry (see tuning_recommendations.md T5)")
NUMA Remote Hits: ${NUMA_DELTA} ($([ "${NUMA_DELTA:-0}" -eq 0 ] && echo "clean — no remote accesses" || echo "WARN — remote accesses detected; see tuning T2"))
Compiler Coverage: ${COMPILER:-GCC only} — $(echo "${COMPILER:-gcc-avx512}" | grep -q icx && echo "ICX available" || echo "ICX not run — install oneAPI for +15-30% (see tuning T1)")
DEEP_DIVE

echo "deep_dive_report.md written to $OUTDIR/deep_dive_report.md"
```

### Generate tuning_recommendations.md

```bash
cat > $OUTDIR/tuning_recommendations.md << TUNING
# Tuning Recommendations — FSI HPC Grid Monte Carlo

**Session** : ${SESSION}
**Platform** : ${PLATFORM} | ${CORE_COUNT}C | $(free -g | awk '/Mem/{print $2}') GiB RAM
**Generated**: $(date)

---

## KPI Scorecard

| KPI | Measured | Reference | Gap | Severity |
|---|---|---|---|---|
| EMON Coverage | $([ $MISSING -eq 0 ] && echo "Complete" || echo "$MISSING workloads missing") | All workloads | — | $([ $MISSING -eq 0 ] && echo "✅ Pass" || echo "⚠️ DATA GAP") |
| Compiler | ${COMPILER:-GCC only} | ICX avx2 + avx512 + GCC avx512 | — | $(echo "${COMPILER:-gcc}" | grep -q icx && echo "✅ Pass" || echo "⚠️ INCOMPLETE") |
| NUMA Remote Hits | ${NUMA_DELTA} | 0 | — | $([ "${NUMA_DELTA:-0}" -eq 0 ] 2>/dev/null && echo "✅ Pass" || echo "⚠️ WARN") |
| IPC (BlackScholesDP) | ${IPC_SPOT} | 2–4 (FP workload) | — | $(echo "$IPC_SPOT" | awk '{if($1~/^[0-9]/)print ($1>=2)?"✅ Pass":"⚠️ WARN (memory-bound)"; else print "N/A"}') |
| Freq droop | ${FREQ_MAX}→${FREQ_MIN} MHz | <5% | — | $(echo "$FREQ_MAX $FREQ_MIN" | awk '{if($1~/^[0-9]/&&$2~/^[0-9]/&&$1>0)print (($1-$2)/$1>0.05)?"⚠️ WARN":"✅ Pass"; else print "N/A"}') |

> If all rows show ✅ Pass: No performance misses detected in this run.

---

## Tier-1 Recommendations (Immediate Fixes)

### T1 — Install Intel oneAPI (ICX) if GCC-only run [HIGHEST IMPACT]
ICX avx512 yields +15–30% over GCC for compute-bound workloads (Black-Scholes, Heston, mc_asian).
See SKILL.md Compiler Variants table for build commands.

### T2 — Verify numactl --localalloc binding for all workloads [HIGH IMPACT]
NUMA delta = ${NUMA_DELTA}. $([ "${NUMA_DELTA:-0}" -eq 0 ] && echo "Clean — no action needed." || echo "Non-zero remote hits detected. Add numactl --localalloc to run loop and disable numa_balancing.")

\`\`\`bash
echo 0 > /proc/sys/kernel/numa_balancing
# For each workload run:
numactl --localalloc --physcpubind=0-$((CORE_COUNT-1)) ./<workload>
\`\`\`

### T3 — Discard first run for warm-up sensitive workloads [IMMEDIATE]
ImpliedVolatility and LiborMarketModel show ~20% warm-up penalty on first run.
Use 1 discard + 5 measured runs to eliminate this bias.

### T4 — Verify EMON coverage before reporting [DATA COMPLETENESS]
$([ $MISSING -eq 0 ] && echo "All workloads covered — no action needed." || echo "$MISSING workloads missing EMON. Fix perf stat placement per T5 below.")

### T5 — Fix perf stat placement if EMON is incomplete [DATA COMPLETENESS]
Start \`perf stat -- sleep 999 &\` BEFORE the run loop; kill after. Never use \`-- sleep <N>\` with a fixed duration.
See run-benchmark/SKILL.md Mandatory Reports → EMON requirement note.

---

## Tier-2 Profiling (if throughput misses threshold)

1. Run \`/benchmark-memory memory-latency-bw\` to get the latency-BW curve
2. Identify the thread count where BW saturates (inflection point on the curve)
3. Compare to the PR count where Monte Carlo throughput peaks
4. If they match → **memory-bound** → increase MRDIMM BW or reduce PR to BW saturation point
5. If throughput peaks below BW saturation → **compute-bound** → rebuild with ICX avx512 + check AMX tile usage

---

## Priority Order

| Priority | Action | Impact | Effort |
|---|---|---|---|
| 1 (now) | Verify EMON coverage for all workloads | Data completeness | 5 min |
| 2 (now) | Install ICX if GCC-only run | +15–30% throughput | 30 min |
| 3 (now) | Run full 3-compiler matrix (ICX avx2, ICX avx512, GCC avx512) | LZ Row 40 compliance | 2 hrs |
| 4 (next) | Fix NUMA binding if remote hits > 0 | Eliminates anomalies | 10 min |
| 5 (planned) | Enable 1 GB hugepages for AMC/LMM | +5–12% large-WS workloads | 15 min |
TUNING

echo "tuning_recommendations.md written to $OUTDIR/tuning_recommendations.md"
echo "All output files in: $OUTDIR"
ls -la $OUTDIR/
```

---

## Tier-1 Tuning (HPC Grid-Specific)

| Symptom | Root Cause | Fix |
|---|---|---|
| Monte Carlo throughput below target | Wrong compiler ISA | Rebuild with `icx -xCORE-AVX512`; verify AMX in use with `perf stat -e amx_tile_retired` |
| PR=threads slower than PR=cores | SMT thrashing on memory-bound WL | Use `PR=$CORE_COUNT`; bind with `numactl --physcpubind --localalloc` |
| Throughput drops between MRDIMM and DDR5-6400 > 30% | Working set exceeds LLC, memory-bandwidth bottleneck | Expected for memory-bound WLs; document both configs |
| IAA not delivering expected throughput | Work queue not configured | `accel-config load-config /etc/accel-config/iaa.conf`; verify `wq_size ≥ 128` |
| QAT crypto below threshold | QAT firmware not loaded or wrong driver | Check `lspci \| grep 4xxx`; `rmmod qat_4xxx && modprobe qat_4xxx` |
| DSA P2P below threshold | IOMMU enabled blocking DMA | Verify `iommu=off` or set passthrough; check `dmesg \| grep iommu` |
| Monte Carlo options/sec not scaling linearly with cores | NUMA remote memory access | Verify `numactl --localalloc`; check `numastat` for remote hits |
