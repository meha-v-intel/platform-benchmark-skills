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

# Set output directory
RESULTS_DIR=/tmp/fsi-benchmarks/$(date +%Y%m%dT%H%M)-hpc/bench/hpc_workloads
mkdir -p $RESULTS_DIR

# THP and governor
echo always > /sys/kernel/mm/transparent_hugepage/enabled
cpupower frequency-set -g performance
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

Run each workload × compiler variant under **two PR settings** per the test plan:

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
        for run in 1 2 3 4 5; do
            PR=$CORE_COUNT numactl --physcpubind=0-$((CORE_COUNT-1)) --localalloc \
                ./$WL 2>&1 | tail -1 | tee -a $WL_DIR/pr_cores.log
        done

        # Run B: PR = thread count (SMT / 2T per core)
        echo "=== $WL | $COMPILER | PR=$THREAD_COUNT — 5 runs ===" | tee $WL_DIR/pr_threads.log
        for run in 1 2 3 4 5; do
            PR=$THREAD_COUNT numactl --physcpubind=all --localalloc \
                ./$WL 2>&1 | tail -1 | tee -a $WL_DIR/pr_threads.log
        done
    done
done
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
IAA_DIR=/tmp/fsi-benchmarks/$(date +%Y%m%dT%H%M)-hpc/bench/hpc_accelerator/iaa
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
QAT_DIR=/tmp/fsi-benchmarks/$(date +%Y%m%dT%H%M)-hpc/bench/hpc_accelerator/qat
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
DSA_DIR=/tmp/fsi-benchmarks/$(date +%Y%m%dT%H%M)-hpc/bench/hpc_accelerator/dsa
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

## HPC Grid Report Format

```
HPC GRID BENCHMARK RESULTS — <PLATFORM> — <TIMESTAMP>
======================================================
Platform        : DMR 1S×256C / GNR-AP 2S×128C / AMD Turin 2S×128C
Memory Config   : DDR5-12800 MRDIMM Gen2 (1DPC)   [repeat for DDR5-6400]
Thread Configs  : PR=<core_count> and PR=<thread_count>

MONTE CARLO WORKLOADS (select key results — full CSV in bench/hpc_workloads/)
  mc_asian_bump   ICX avx512 PR=<N>cores : avg XXXXX options/sec ± XXXX
  mc_asian_bump   ICX avx512 PR=<N>threads: avg XXXXX options/sec ± XXXX
  BlackScholesDP  ICX avx512 PR=<N>cores : avg XXXXX options/sec ± XXXX
  heston_price    ICX avx512 PR=<N>cores : avg XXXXX options/sec ± XXXX
  amc             ICX avx512 PR=<N>cores : avg XXXXX options/sec ± XXXX
  [ICX avx512 vs GCC avx512 delta: +X.X% — ICX better/worse]

LZ KPI STATUS
  Row 23 IAA RocksDB Analytics : PASS/FAIL — X.Xx vs GNR (threshold: ≥1.2×)
  Row 24 IAA Compression BW   : PASS/FAIL — XXX GB/s (threshold: ≥GNR)
  Row 27 AI Inference (AMX)   : → delegate to /benchmark-amx
  Row 40 HPC Perf vs Comp     : PASS/FAIL — X.Xx vs AMD Turin
  Row 47 Stream Triad vs GNR  : → delegate to /benchmark-memory

ACCELERATORS
  QAT RSA (row 53)   : PASS/FAIL — XXX Kops  (threshold: ≥100 Kops)
  QAT Bulk (row 54)  : PASS/FAIL — XXX Gbps  (threshold: ≥400 Gbps @4K)
  QAT Zstd (row 55)  : PASS/FAIL — XXX/XXX GB/s (compress/decompress)
  DSA P2P (row 58)   : PASS/FAIL — XXX GB/s  (threshold: ≥60 GB/s)

TUNING RECOMMENDATIONS: [none | Tier-1 items | Tier-2 profiling needed]
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
