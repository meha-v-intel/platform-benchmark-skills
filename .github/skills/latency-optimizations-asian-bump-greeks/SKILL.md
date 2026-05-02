---
name: latency-optimizations-asian-bump-greeks
description: >
  Skill for profiling and optimizing the Monte Carlo Asian option bump-and-run
  Greeks workload (AAD_Asian_BumpGreeks) on Intel platforms. Use this skill when
  asked to profile, analyse bottlenecks, or optimize this workload. Covers the
  full methodology: perf stat, PEBS, time-budget decomposition, AVX-512
  vectorisation, SVML, and OpenMP parallelism.
---

# Skill: Latency Optimizations — Asian Bump Greeks

## Context

**Workload:** `AAD_Asian_BumpGreeks` — Monte Carlo arithmetic Asian call option
under Black-Scholes with time-dependent vol `sigma[t]`.  
**Method:** Bump-and-run: for each of 256 time-step vols, compute `pv_up` and
`pv_dn` with ±h bump → vega = (pv_up - pv_dn) / 2h.  
**Default args:** 20,000 paths × 256 steps × 256 bumps, seed=123.  
**Platform:** Intel DMR-AP (family:19 model:1), pre-production.  
**Location:** `/home/fsi_val/ww16/financial-samples/AAD_Asian/`

---

## Key Files

| File | Purpose |
|---|---|
| `mc_asian_bump_greeks.cpp` | Optimized source (AVX-512 + OpenMP) |
| `mc_asian_bump_greeks.cpp.orig` | Original scalar source (backup) |
| `Makefile` | Build targets: avx512, avx2, gcc, aoc |
| `MPTest/` | Production run harness |
| `profile_results/bump_compare/` | All perf stat + PEBS profiling data |
| `profile_results/bump_compare/benchmark_comparison.txt` | Full benchmark report |

---

## Profiling Methodology

### 6-Pass perf stat (standard decomposition)
Each pass targets a different microarchitectural dimension.  
Run from `/home/fsi_val/ww16/financial-samples/` using `run_bump_latency.sh`.

```bash
# Pass 1 — Cache hierarchy
perf stat -e cycles,instructions,cache-references,cache-misses,\
LLC-loads,LLC-load-misses,LLC-stores ./BINARY

# Pass 2 — TLB + Branch
perf stat -e dTLB-loads,dTLB-load-misses,iTLB-loads,iTLB-load-misses,\
branch-misses,branches ./BINARY

# Pass 3 — CYCLE_ACTIVITY (stall decomposition)
# For ADDITIVE WALL-CLOCK decomposition, use the canonical method in the
# "Additive Wall-Clock Time Decomposition" section below instead of this pass.
perf stat -e r0ca3,r04a3,r08a3 ./BINARY
# r0ca3 = CYCLES_L1D_PENDING (all memory stalls)
# r04a3 = CYCLES_L2_PENDING
# r08a3 = CYCLES_L1D_MISS (outstanding L1D misses)
# NOTE: r08a3 accumulates per-outstanding-miss per cycle when MLP>1;
#        values can legally exceed total cycles for vectorized code.

# Pass 4 — FP vectorisation width
perf stat -e fp_arith_inst_retired.scalar_double,\
fp_arith_inst_retired.128b_packed_double,\
fp_arith_inst_retired.256b_packed_double,\
fp_arith_inst_retired.512b_packed_double ./BINARY

# Pass 5 — Retired loads + uops
perf stat -e mem_inst_retired.all_loads,\
mem_inst_retired.all_stores,uops_issued.any,uops_retired.slots ./BINARY

# Pass 6 — DRAM / memory bandwidth (PMU events vary by platform)
perf stat -e r0104,r0204,r0804 ./BINARY
```

### PEBS (hotspot profiling)
```bash
# Cycles hotspot
perf record -e cycles:pp -c 100003 -d ./BINARY
perf report --stdio --no-children -n | head -30

# L3 miss hotspot
perf record -e mem_load_retired.l3_miss:pp -c 1000 ./BINARY

# L3 hit hotspot
perf record -e mem_load_retired.l3_hit:pp -c 10000 ./BINARY

# L2 hit hotspot
perf record -e mem_load_retired.l2_hit:pp -c 10000 ./BINARY

# Branch mispredicts hotspot
perf record -e branch-misses:pp -c 1000 ./BINARY
```

### Parsing & analysis
```bash
python3 analyze_bump_latency.py profile_results/bump_compare/original/
# NOTE: Script was calibrated for scalar original; produces misleading
#       derived metrics for SIMD/MT builds (CYCLE_ACTIVITY model mismatch).
#       Use raw perf numbers directly for vectorized code.
```

---

## Root Cause: Original Bottleneck

```
=== ADDITIVE TIME BUDGET (Original scalar, 1 thread) ===
SVML exp2 (128-bit, scalar)     61%   ← THE bottleneck
Main FP compute (mul/add/cmp)   24%
L2-fill stalls                   5%
OOO latency hiding               8%
Other                            2%
```

**Why `exp` dominates:** Inner time-step loop has loop-carried dependency:
```cpp
S *= std::exp(drift + diff);   // S[t+1] = f(S[t]) → serial dependency
```
The compiler confirms in `.optrpt`: *"vector dependence prevents vectorization"*.
The SIMD dimension must be across **paths** (outer loop), not time steps.

---

## Optimizations Applied

### Change 1 — Transpose normals to time-major layout
Enables unit-stride AVX-512 loads across 8 paths per SIMD lane.
```cpp
// Fill path-major, then transpose to time-major z[t*paths + p]
for (int p = 0; p < paths; ++p)
    for (int t = 0; t < steps; ++t)
        z[(size_t)t * paths + p] = tmp[(size_t)p * steps + t];
```

### Change 2 — Explicit AVX-512 SIMD kernel (8 paths/iteration)
```cpp
// 8 paths per SIMD iteration
for (int p = 0; p < paths8; p += 8) {
    __m512d S = _mm512_set1_pd(spec.S0);
    __m512d running_sum = _mm512_setzero_pd();
    for (int t = 0; t < steps; ++t) {
        running_sum = _mm512_add_pd(running_sum, S);
        __m512d z_vec   = _mm512_loadu_pd(&normals[t * paths + p]);
        __m512d exp_arg = _mm512_fmadd_pd(
                              _mm512_set1_pd(diff_scale), z_vec,
                              _mm512_set1_pd(drift));
        S = _mm512_mul_pd(S, _mm512_exp_pd(exp_arg));  // SVML 8-wide
    }
    __m512d avgS   = _mm512_div_pd(running_sum, _mm512_set1_pd(double(steps)));
    __m512d payoff = _mm512_max_pd(
                         _mm512_sub_pd(avgS, _mm512_set1_pd(spec.K)),
                         _mm512_setzero_pd());
    sum_payoff += _mm512_reduce_add_pd(payoff);
}
```

### Change 3 — OpenMP parallelism over 256 bumps
```cpp
#pragma omp parallel for schedule(dynamic,4) reduction(+:chk) \
    shared(spec, normals, paths, steps, bump)
for (int k = 0; k < steps; ++k) {
    std::vector<double> sig_up = sigma;  // thread-local copy
    std::vector<double> sig_dn = sigma;
    sig_up[k] += bump;
    sig_dn[k] -= bump;
    const double pv_up = price_asian_mc(spec, sig_up, normals, paths, steps);
    const double pv_dn = price_asian_mc(spec, sig_dn, normals, paths, steps);
    vega[k] = (pv_up - pv_dn) / (2.0 * bump);
    chk += vega[k];
}
```

---

## Critical Makefile Correctness Pitfalls

**`-fimf-domain-exclusion=31`** — corrupts `_mm512_exp_pd` for small arguments
(~[-0.15, 0.15]). The base PV drops from 5.04 → 0.16. Vegas are unaffected
because the bias cancels in the finite difference. **Remove this flag** from any
target using the AVX-512 SIMD kernel.

**`-mrecip=all:0`** — zero-refinement reciprocal for all divisions; corrupts
`avgS = running_sum / steps`. **Remove this flag** from any target using the
AVX-512 SIMD kernel.

Both flags are **safe** for the original scalar code (which uses different
code paths) but **unsafe** for the explicit SIMD kernel.

### Validated Makefile flags for avx512 optimized target
```makefile
icpx mc_asian_bump_greeks.cpp -o mc_asian_bump_greeks.avx512 \
    -g -O3 -march=graniterapids -qopt-zmm-usage=high \
    -ffinite-math-only -fimf-accuracy-bits=11 \
    -fno-alias -qopenmp -m64 \
    -lpthread -lm -ldl
# NOTE: -fimf-domain-exclusion=31 and -mrecip=all:0 REMOVED
```

### gcc/clang SVML shim (for cross-compiler comparison)
`_mm512_exp_pd` is Intel SVML only. For gcc/clang, link against Intel's libsvml:
```cpp
// Add to source before using _mm512_exp_pd:
extern "C" __m512d __svml_exp8(__m512d);
inline __m512d _mm512_exp_pd(__m512d x) { return __svml_exp8(x); }
```
```bash
# Compile with:
-L/opt/intel/oneapi/compiler/2025.3/lib -lsvml \
-Wl,-rpath,/opt/intel/oneapi/compiler/2025.3/lib
```

---

## Correctness Validation

Always validate with three seeds (200, 42, 999):
```bash
# Quick check: base PV and vega checksum
OMP_NUM_THREADS=1 ./mc_asian_bump_greeks.avx512 20000 256 200
# Expected: base PV ≈ 5.04, vega checksum ≈ 22.07

# Full 256-vega comparison (build a debug variant printing all vegas)
# Max abs diff between orig and opt: ≤ 1e-6 across all seeds
# Max rel diff on meaningful vegas (|vega|>1e-4): < 0.01%
# "Large" relative errors only appear on near-zero vegas (< 1e-5) which
# are within MC statistical noise — not algorithmic errors.
```

**Root cause of small FP differences:** FMA instruction fusion +
`-fimf-accuracy-bits=11` vs gcc defaults. Expected compiler behavior.

---

## Benchmark Results (DMR-AP, April 2026)

Workload: 20,000 paths × 256 steps × 256 bumps, seed=123

### Single-thread comparison

| Compiler/ISA | Variant | Time | Ops/sec | vs gcc-orig |
|---|---|---|---|---|
| icpx/avx512 | orig | 6.35s | 40.3 | 3.5× |
| icpx/avx2 | orig | 7.05s | 36.3 | 3.1× |
| gcc | orig | 22.0s | 11.6 | **1.0× baseline** |
| clang/aoc | orig | 17.8s | 14.4 | 1.2× |
| icpx/avx512 | **opt** | 7.0s | 36.6 | 3.1× |
| icpx/avx2 | opt | N/A | N/A | AVX-512 intrinsics req. |
| gcc | **opt** | 10.7s | 24.0 | 2.1× |
| clang/aoc | **opt** | 10.3s | 24.9 | 2.1× |

### 32-thread comparison

| Compiler/ISA | Variant | Time | Ops/sec | vs gcc-orig |
|---|---|---|---|---|
| icpx/avx512 | orig | 6.43s | 39.8 | 3.4× |
| icpx/avx2 | orig | 7.08s | 36.2 | 3.1× |
| gcc | orig | 22.1s | 11.6 | 1.0× |
| clang/aoc | orig | 17.9s | 14.3 | 1.2× |
| icpx/avx512 | **opt** | **0.19s** | **1325** | **114×** |
| icpx/avx2 | opt | N/A | N/A | AVX-512 intrinsics req. |
| gcc | **opt** | **0.25s** | **1027** | **88×** |
| clang/aoc | **opt** | **0.37s** | **701** | **60×** |

### Microarchitectural summary (icpx/avx512, seed=123)

| Metric | gcc orig 1T | icpx opt 1T | icpx opt 32T |
|---|---|---|---|
| IPC | 4.67 | 0.84 | ~0.8 |
| AVX-512 % of FP | 0% | 96% | 96% |
| GFLOPS/core | 3.46 | 7.15 | 264.6 |
| L3 hit % | 32.9% | 73.6% | 53.9% |
| DRAM hit % | 32.3% | 10.7% | 34.9% |
| MLP (avg outstanding L1D misses) | 0.06× | 8.28× | 5.54× |
| PEBS #1 hotspot | `main` 85.6% | `__svml_exp8_ep_z0` 57.8% | — |

**IPC drop (4.67→0.84) is expected:** fewer instructions issued (8× work per
instruction) but each `_mm512_exp_pd` has high latency. Total work/second is
higher despite lower IPC.

---

## Platform Limitations (Pre-production DMR-AP)

- `perf mem record` → "memory events not supported"
- PEBS weight/data_src → all zero (hardware doesn't populate)
- PCM: CPU unsupported; VTune 2025.10: CPU not recognized
- L2 request events (r01f1-r40f1): all zero (umask encoding differs on pre-prod)
- `perf_event_paranoid = 2`
- `CYCLE_ACTIVITY` events (r08a3): accumulate per-outstanding-miss per cycle
  when MLP>1 — values can legally exceed total cycles for SIMD code

---

## Next Steps

1. Run on **production DMR** for full PEBS weight/data_src + PCM/VTune support
2. Profile `mc_asian_aad_greeks` (BW-bound AAD workload) for comparison
3. Compare against SPR/EMR baselines to quantify DMR-AP generation improvement
4. Cache blocking for bump loop to reduce DRAM pressure at 32T
   (DRAM hit % goes from 10.7% at 1T → 34.9% at 32T)
5. Investigate icpx vs gcc 32T gap (1325 vs 1027): OMP scheduling + SVML dispatch
6. Profile avx2 optimized path (requires rewriting kernel without AVX-512 intrinsics)

---

## Additive Wall-Clock Time Decomposition (Canonical Method)

This is the **primary method** for "additive time analysis" on any single-threaded
workload. It decomposes every CPU cycle into exactly one of six non-overlapping
categories, then converts to wall-clock time so the Time column sums to elapsed.

### When to use

Use this method whenever the user asks for:
- "additive time analysis"
- "latency decomposition"
- "wall-clock time breakdown"
- "where is the time going"
- any request for a timing table that sums to wall clock

This method works on **any single-threaded x86 workload**, not just Asian bump Greeks.

### Step 1 — Collect perf events (single pass)

All six CYCLE_ACTIVITY raw events plus `cycles` in one `perf stat` invocation.
Pin to a single core and bind memory to local NUMA node for clean measurements.

```bash
perf stat -r 5 \
  -e cycles,r01a3,r02a3,r04a3,r05a3,r06a3 \
  -- taskset -c 0 numactl --membind=0 \
  env OMP_NUM_THREADS=1 ./BINARY [ARGS]
```

### Step 2 — Event definitions (Intel GNR / DMR / SPR family, event 0xA3)

| Raw code | Name | What it counts |
|----------|------|----------------|
| `r04a3`  | STALLS_L2_MISS | Cycles **stalled** (no uop dispatch) while ≥1 L2 miss is outstanding |
| `r06a3`  | CYCLES_L3_MISS | **All** cycles (stall + execute) while ≥1 L3 miss is outstanding |
| `r05a3`  | CYCLES_L2_MISS | **All** cycles (stall + execute) while ≥1 L2 miss is outstanding |
| `r01a3`  | OOO_L2_MISS    | Cycles **executing** (OOO) while ≥1 L2 miss is outstanding |
| `r02a3`  | OOO_L3_MISS    | Cycles **executing** (OOO) while ≥1 L3 miss is outstanding |
| `cycles` | CPU_CLK_UNHALTED | Total unhalted CPU cycles |

**Identity checks (must hold within ±1%):**
```
r05a3 = r04a3 + r01a3    (cycles_L2 = stalls_L2 + ooo_L2)
r06a3 = STALLS_L3 + r02a3  (cycles_L3 = stalls_L3 + ooo_L3)
```
If these fail, the events have different semantics on this CPU — fall back to
the 6-pass method above.

### Step 3 — Decomposition formulas

Six non-overlapping, exhaustive categories. Every cycle belongs to exactly one:

```
STALL_DRAM  = r06a3 - r02a3        # stall cycles waiting for DRAM (L3 miss)
STALL_L3    = r04a3 - STALL_DRAM   # stall cycles waiting for L3 (L2 miss, L3 hit)
              = r04a3 - r06a3 + r02a3
STALL_C2C   = 0                     # eliminated when numactl --membind=0 is used
OOO_L2      = r01a3 - r02a3        # executing while L2 miss pending (L3 hit)
OOO_L3      = r02a3                 # executing while L3 miss pending (DRAM)
PURE_EXEC   = cycles - r04a3 - r01a3  # no outstanding L2 miss
```

**Proof of additivity:**
```
STALL_DRAM + STALL_L3 + OOO_L2 + OOO_L3 + PURE_EXEC
= (r06a3-r02a3) + (r04a3-r06a3+r02a3) + (r01a3-r02a3) + r02a3 + (cycles-r04a3-r01a3)
= r06a3 - r02a3 + r04a3 - r06a3 + r02a3 + r01a3 - r02a3 + r02a3 + cycles - r04a3 - r01a3
= cycles  ✓
```

**Clamping:** If `STALL_L3` or `OOO_L2` compute as negative (measurement noise
when L3 hit rate ≈ 0%), clamp to zero and absorb the residual into the dominant
adjacent category (STALL_DRAM or OOO_L3 respectively). Document when this occurs.

### Step 4 — Convert to wall-clock time

```
Time_component = (component_cycles / total_cycles) × elapsed_seconds
```

This guarantees `sum(Time_component) = elapsed_seconds` exactly.

### Step 5 — Output table format

Always produce the table in exactly this format:

```
Wall Clock = {elapsed}s — Full Additive Breakdown

 Category                          Cycles    % Wall   Time     Events used
 ─────────────────────────────────────────────────────────────────────────
 * STALL  DRAM fill  (L3→DRAM)    X.XXXB    XX.X%    X.XXXs   r04a3, r06a3
 * STALL  L3 fill    (L2→L3 hit)  X.XXXB     X.X%    X.XXXs   r04a3, r05a3
 * STALL  C2C        (remote)     X.XXXB     X.X%    X.XXXs   numactl --membind=0
   OOO    L2 miss    (exec+fill)  X.XXXB     X.X%    X.XXXs   r01a3
   OOO    L3 miss    (exec+fill)  X.XXXB     X.X%    X.XXXs   r02a3
   Pure EXECUTE      (no L2 miss) X.XXXB    XX.X%    X.XXXs   residual
 ─────────────────────────────────────────────────────────────────────────
   Total CPU cycles               X.XXXB   100.0%    X.XXXs   ✓
```

**Formatting rules:**
- Cycles in billions with 3 decimal places (e.g., `5.382B`)
- Percentages with 1 decimal place
- Time in seconds with 3 decimal places
- Rows marked `*` are stall categories (bottleneck candidates)
- Total line must show `100.0%` and `✓`
- Sum of the Time column must equal the Wall Clock header value

### Reference measurement (GNR 160C, May 2026)

```
Wall Clock = 2.534s — Full Additive Breakdown (mc_asian_bump_greeks.avx512, 1T)

 Category                          Cycles    % Wall   Time     Events used
 ─────────────────────────────────────────────────────────────────────────
 * STALL  DRAM fill  (L3→DRAM)    5.133B    63.7%    1.614s   r04a3, r06a3
 * STALL  L3 fill    (L2→L3 hit)  0.000B     0.0%    0.000s   r04a3, r05a3
 * STALL  C2C        (remote)     0.000B     0.0%    0.000s   numactl --membind=0
   OOO    L2 miss    (exec+fill)  0.332B     4.1%    0.104s   r01a3
   OOO    L3 miss    (exec+fill)  0.005B     0.1%    0.002s   r02a3
   Pure EXECUTE      (no L2 miss) 2.587B    32.1%    0.814s   residual
 ─────────────────────────────────────────────────────────────────────────
   Total CPU cycles               8.056B   100.0%    2.534s   ✓

Note: STALL_L3 = 0% because working set (~10 GB) >> L3 capacity (1.1 GiB).
      All L2 misses also miss L3 → r04a3 ≈ r06a3 within measurement noise.
```

### Earlier reference (DMR-AP, April 2026)

```
Wall Clock = 2.587s — Full Additive Breakdown (mc_asian_bump_greeks.avx512, 1T)

 Category                          Cycles    % Wall   Time     Events used
 ─────────────────────────────────────────────────────────────────────────
 * STALL  DRAM fill  (L3→DRAM)    5.382B    65.5%    1.694s   r04a3, r06a3
 * STALL  L3 fill    (L2→L3 hit)  0.315B     3.8%    0.099s   r04a3, r05a3
 * STALL  C2C        (remote)     0.000B     0.0%    0.000s   numactl --membind=0
   OOO    L2 miss    (exec+fill)  0.343B     4.2%    0.108s   r01a3
   OOO    L3 miss    (exec+fill)  0.009B     0.1%    0.003s   r02a3
   Pure EXECUTE      (no L2 miss) 2.172B    26.4%    0.683s   residual
 ─────────────────────────────────────────────────────────────────────────
   Total CPU cycles               8.221B   100.0%    2.587s   ✓
```

### Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `r05a3 - r04a3 ≠ r01a3` (>5% off) | Events have different semantics on this CPU | Try cmask-encoded variants: `cpu/event=0xa3,umask=0x05,cmask=0x05/` etc. |
| `STALL_L3` negative | L3 hit rate ≈ 0%, measurement noise | Clamp to 0; note in output |
| `r02a3` has >15% variance | Very few L3-miss OOO cycles | Normal; increase `-r N` to ≥10 runs |
| All `rXXa3` return 0 | Kernel lacks PMU support for this CPU | Check `perf_event_paranoid`; try running as root |
| Sum ≠ 100.0% | Rounding | Use `cycles - r04a3 - r01a3` for PURE_EXEC (residual absorbs rounding) |

---

## Session 2026-04-24 — Prior Additive Time Budget Notes

### Budget summary (17-row merged table)
Both configs fully decomposed — all cycles accounted for, identity proofs close exactly.

**OPTIMIZED bottleneck (row 6): SVML exp8 = 57.8% = 4.194s**
- Loop-carried dep: `S *= exp(drift + sigma*z[t])` serialises 256 exp calls per path
- Fix: log-sum reformulation → 1 exp call per path instead of 256
- Expected next speedup: ~2× on top of current 3.05×
