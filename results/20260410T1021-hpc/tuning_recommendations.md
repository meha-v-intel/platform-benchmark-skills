# Tuning Recommendations — FSI HPC Grid Monte Carlo

**Session** : 20260410T1021-hpc
**Platform** : GNR-SP 2S × 80C × 2T | 8 NUMA nodes (SNC4) | 251 GiB RAM | Ubuntu 24.04.1 LTS
**Baseline** : GCC avx512 | PR=160: all 16 workloads run | PR=320: 15/16 (amc OOM)

---

## T1 — Install Intel oneAPI Compiler for ICX avx512 Builds [HIGHEST IMPACT]

**Bottleneck**: All results are GCC-compiled. ICX uses Intel-specific vectorization,
FMA fusion, and AMX tile dispatching that GCC cannot generate. Expected delta: 15–30%
throughput improvement for arithmetic-heavy workloads (HestonPricing, mc_asian_bump,
bs_pde_solver, BlackScholes).

**Action**:
```bash
# Add Intel apt repo
wget -O- https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB \
    | gpg --dearmor | tee /usr/share/keyrings/oneapi-archive-keyring.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/oneapi-archive-keyring.gpg] \
    https://apt.repos.intel.com/oneapi all main" \
    | tee /etc/apt/sources.list.d/oneAPI.list
apt-get update
apt-get install -y intel-oneapi-compiler-dpcpp-cpp intel-oneapi-mkl-devel

# Activate environment
source /opt/intel/oneapi/setvars.sh

# Rebuild all workloads with ICX avx512
cd /datafs/subbu/financial-samples
for d in */; do
    cd "$d"
    make clean
    CC=icx CXX=icpx CFLAGS="-O3 -xCORE-AVX512 -qopenmp" make 2>&1 | tail -3
    cd ..
done
```

**Predicted improvement**: +15–30% on compute-bound workloads; +5–10% on memory-bound
**Confidence**: High — Intel BKM for FSI HPC Grid validation
**Basis**: ICX generates EVEX-encoded AVX-512 with better instruction scheduling and
FMA pairing vs GCC. Also enables MKL runtime dispatch to AVX-512 code paths.

---

## T2 — Use numactl --localalloc to Prevent NUMA Remote Access [HIGH IMPACT]

**Bottleneck**: LiborMarketModel showed a 53% slowdown anomaly in one run (149 ms vs
98 ms) consistent with a NUMA remote page access during a cold-start. `numa_balancing`
was not explicitly disabled. Workloads spawning 160–320 processes may land instances
on remote NUMA nodes without explicit pinning.

**Action**:
```bash
# Disable NUMA automatic balancing for benchmark duration
echo 0 > /proc/sys/kernel/numa_balancing

# For runbatch.sh, add numactl --localalloc per instance:
# In /datafs/subbu/financial-samples/<workload>/runbatch.sh, change:
#   OMP_NUM_THREADS=1 taskset -c $i ./inst$i/$EXEFILE
# to:
#   OMP_NUM_THREADS=1 numactl --localalloc --physcpubind=$i ./inst$i/$EXEFILE

# Re-enable after benchmarking (optional):
echo 1 > /proc/sys/kernel/numa_balancing
```

**Predicted improvement**: Eliminates NUMA anomaly runs; reduces LiborMarketModel
variance from ~11% to <2%; may improve AMC per-instance throughput by ~5–10%
**Confidence**: High — NUMA remote access adds 2.8–3.1× latency on this GNR-SP system
**Basis**: Cross-socket UPI latency on this platform is ~490–516 ns vs ~170 ns local (deep_dive_report.md, Finding 3 reference from memory benchmark).

---

## T3 — Discard First 1–2 Runs for Warm-Up Sensitive Workloads [IMMEDIATE]

**Bottleneck**: `ImpliedVolatility` shows a clear warm-up curve within each 5-run batch
(7.10 → 6.50 → 6.11 → 5.96 → 5.87 sec). First run is 21% slower than steady-state.
This skews the 5-run average by ~5–7%. `LiborMarketModel` has similar behavior.

**Action**: Change the benchmark from 5 measured runs to 1 warm-up + 5 measured runs:
```bash
# Modified run loop in run_full_mc.sh for warm-up sensitive workloads:
WARMUP_WLS="ImpliedVolatility LiborMarketModel HestonPricing"

for WL in $WARMUP_WLS; do
    echo "=== Warm-up run for $WL ==="
    PR=$CORE_COUNT <run command> > /dev/null 2>&1  # discard warm-up
    for run in 1 2 3 4 5; do
        PR=$CORE_COUNT <run command> | tee -a $WL_DIR/pr_cores.log
    done
done
```

**Predicted improvement**: 5–7% avg latency improvement for ImpliedVolatility;
~2–3% for LiborMarketModel. Results will be more reproducible (CoV <2%).
**Confidence**: High — deterministic warm-up curve observed across all 4 run batches
**Basis**: Branch predictor + TLB + L3 cache warming on first invocation.

---

## T4 — Reduce AMC numPaths for PR=320 Feasibility [MEMORY CONSTRAINT FIX]

**Bottleneck**: AMC PR=320 is infeasible on 251 GB RAM (320 × ~800 MB ≈ 256 GB).
This prevents the SMT comparison for the most critical FSI workload.

**Action**: Reduce `numPaths` from 524288 to 262144 (half) for the PR=320 run only.
This halves per-instance RAM to ~400 MB → 320 × 400 MB = 128 GB (within limits).

```bash
# In run_full_mc.sh, use different args per PR setting for AMC:
# PR=CORE_COUNT: use full problem size
AMC_ARGS_CORES="1 8192 524288 256"

# PR=THREAD_COUNT: halve numPaths to fit in RAM
AMC_ARGS_THREADS="1 8192 262144 256"

# Adjust numPaths accordingly and note in output that configs differ
```

**Predicted improvement**: Enables AMC PR=320 comparison (previously blocked)
**Confidence**: High — memory math is deterministic; 262144 paths × 320 instances = 128 GB
**Basis**: AMC per-instance RAM = numPaths × numSteps × sizeof(double) × ~12 arrays ≈ 800 MB at 524288 paths.

---

## T5 — Fix perf stat Placement for Full EMON Coverage [DATA COMPLETENESS]

**Bottleneck**: The current `/tmp/run_full_mc.sh` already has a `perf stat` block, but
it is mis-placed and captures almost nothing useful:

```bash
# CURRENT (broken) — inside the per-run loop, only 4 workloads, 3-second sleep window:
if [ $run -eq 1 ] && [ "$PR_LABEL" = "cores" ] && \
   [[ "$NAME" =~ ^(emc|amc|BlackScholes|mc_asian_bump)$ ]]; then
    sleep 1
    perf stat -a ... -- sleep 3 2>/dev/null &   # ← captures only 3s, not workload duration
fi
```

**Problems with current placement:**
1. `-- sleep 3` makes perf stat measure a fixed 3-second window, not the actual workload
2. Only 4 of 16 workloads are covered
3. Perf starts 1 second _after_ workload launch — misses the initial burst
4. The `&` without tracking means perf output is lost if the process races

**Fix — in `/tmp/run_full_mc.sh`, inside `run_workload()`, replace the perf block
with one that wraps the _entire_ run loop for run 1 of PR=cores:**

```bash
# LOCATION: inside run_workload(), replace the existing perf block
# BEFORE the "for run in $(seq 1 $NRUNS)" loop, add:

    PERF_PID=""
    if [ "$PR_LABEL" = "cores" ]; then
        perf stat -a \
            -e cycles,instructions,cache-misses,cache-references,\
LLC-load-misses,mem_inst_retired.all_loads,mem_inst_retired.all_stores,\
cycle_activity.stalls_mem_any \
            --interval-print 5000 \
            -o $OUTDIR/emon/${NAME}_pr${PR}.perf \
            -- sleep 999 &
        PERF_PID=$!
    fi

    for run in $(seq 1 $NRUNS); do
        # ... existing run loop (unchanged) ...
    done

    # AFTER the run loop, stop perf:
    [ -n "$PERF_PID" ] && kill $PERF_PID 2>/dev/null; wait $PERF_PID 2>/dev/null || true

# REMOVE the old misplaced perf block inside the run loop entirely.
```

**This gives you:** system-wide IPC, LLC miss rate, memory load/store rate, and memory
stall cycles for every workload × PR=cores run, saved to `$OUTDIR/emon/<workload>_pr160.perf`.

**Predicted improvement**: IPC distinguishes compute-bound (IPC>2) vs memory-bound (IPC<1);
LLC miss rate confirms AMC/LMM are DRAM-bound; stall cycles explain SMT benefit pattern
**Confidence**: High — `perf` is available on this system (confirmed during run)
**Basis**: SKILL.md `emon/` directory placeholder; FSI validation requires telemetry evidence.

---

## T6 — Enable 1 GB Static Hugepages for Large Working-Set Workloads [MEDIUM IMPACT]

**Bottleneck**: AMC (800 MB/instance) and LiborMarketModel have large working sets
that span many 4 KB TLB entries. TLB pressure adds latency overhead on GNR-SP
(measured ~170 ns local DRAM on this system).

**Action**:
```bash
# Allocate 1 GB hugepages before running AMC/LMM
# AMC at PR=160: 160 instances × 800 MB = 128 GB → need at least 128 x 1GB pages
echo 160 > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages

# Verify allocation
grep -i hugepages /proc/meminfo

# Workloads must request hugepages via mmap(MAP_HUGETLB) — check source:
grep -r "MAP_HUGETLB\|hugepage\|madvise" /datafs/subbu/financial-samples/amc/

# If not natively supported, use transparent hugepages (already set to 'always'):
echo always > /sys/kernel/mm/transparent_hugepage/enabled
echo defer+madvise > /sys/kernel/mm/transparent_hugepage/defrag
```

**Predicted improvement**: 5–12% throughput improvement for AMC and LiborMarketModel
**Confidence**: Medium — depends on workload mmap() pattern; THP covers most cases
**Basis**: TLB miss on GNR adds ~30–60 ns per access. AMC with 128 simultaneous large
allocations saturates the 4-level page walk hardware.

---

## T7 — Run Complete 4-Compiler Matrix When ICX Available [COMPLETENESS]

**Bottleneck**: SKILL.md requires ICX avx2, ICX avx512, GCC avx512, AOCC avx512
comparison. Currently only GCC avx512 is available. The ICX vs GCC delta validates
Intel compiler advantage (FSI LZ Row 40).

**Action** (after T1 — ICX install):
```bash
declare -A COMPILERS=(
    ["icx-avx2"]="icx -O3 -xCORE-AVX2 -qopenmp -liomp5 -lpthread"
    ["icx-avx512"]="icx -O3 -xCORE-AVX512 -qopenmp -liomp5 -lpthread"
    ["gcc-avx512"]="gcc -O3 -march=native -mprefer-vector-width=512 -mfma -Ofast -fopenmp -lgomp"
)

for VARIANT in icx-avx2 icx-avx512 gcc-avx512; do
    # Rebuild all 16 workloads with this compiler
    # Run full PR=cores + PR=threads × 5 repetitions
    # Save results to $RESULTS_DIR/$VARIANT/<workload>/
done
```

**Predicted improvement**: Provides ICX/GCC delta; validates AVX-512 vs AVX2 gain;
enables LZ Row 40 compiler comparison
**Confidence**: High — standard Intel FSI validation requirement
**Basis**: benchmark-hpc-grid SKILL.md compiler variant table.

---

## Priority Order

| Priority | Action | Impact | Effort | Expected Outcome |
|---|---|---|---|---|
| 1 (now) | **T3** — Discard warm-up runs | Medium | 5 min | ImpliedVolatility -7% wall time, lower variance |
| 2 (now) | **T2** — numactl --localalloc + disable numa_balancing | High | 10 min | Fix LiborMarketModel anomaly, stable AMC results |
| 3 (now) | **T5** — perf stat EMON coverage | Data | 15 min | IPC/LLC/BW telemetry for next run |
| 4 (now) | **T4** — AMC numPaths=262144 for PR=320 | Unlocks data | 5 min | AMC SMT comparison now feasible |
| 5 (next) | **T1** — Install Intel oneAPI ICX | Highest | 30 min | +15–30% on compute-bound workloads |
| 6 (next) | **T7** — Full 4-compiler matrix | Completeness | 2 hrs | LZ Row 40 ICX vs GCC delta validated |
| 7 (planned) | **T6** — 1 GB Hugepages | Medium | 15 min | +5–12% AMC/LiborMarketModel throughput |

### Quick-win script (apply T2 + T3 immediately):
```bash
ssh root@10.1.225.221 "
# T2: Disable NUMA balancing
echo 0 > /proc/sys/kernel/numa_balancing

# T2: Verify
cat /proc/sys/kernel/numa_balancing   # should print 0

# T3: Note — modify /tmp/run_full_mc.sh to add 1 warm-up run before 5 measured runs
# for ImpliedVolatility, LiborMarketModel, HestonPricing
sed -i 's/for run in 1 2 3 4 5/for run in 0 1 2 3 4 5/' /tmp/run_full_mc.sh
# Then filter run=0 results from parsing
"
```

---

## Expected Results After All Tunings Applied

| Workload | Current (GCC, no tuning) | Expected (ICX, T1–T4) | Delta |
|---|---|---|---|
| AMC PR=160 TOTAL | 52,855 Kpaths/sec | ~61,000–69,000 Kpaths/sec | +15–30% |
| AMC PR=320 TOTAL | OOM | ~55,000–62,000 Kpaths/sec | NEW DATA |
| BlackScholes PR=160 | 39.2 GOpts/sec | ~45–51 GOpts/sec | +15–30% |
| HestonImpliedVol PR=320 | 383,036 opts/sec | ~440–497K opts/sec | +15–30% |
| LiborMarketModel PR=160 | 206.1 Kpaths/sec (w/ outlier) | ~214 Kpaths/sec (clean) | +4% (outlier fix) |
| ImpliedVolatility PR=160 | 6.299 s (w/ warm-up) | ~5.85 s (steady state) | -7% wall time |
