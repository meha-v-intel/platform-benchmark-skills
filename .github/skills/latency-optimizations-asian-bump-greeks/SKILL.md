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

## Session 2026-04-24 — Additive Time Budget (Final Reference)

### Starting point for next session
Reference file: `profile_results/bump_compare/time_budget_final.txt`
Checkpoint: `session-state/e801f22e-.../checkpoints/003-additive-time-budget-final.md`

### Budget summary (17-row merged table)
Both configs fully decomposed — all cycles accounted for, identity proofs close exactly.

**OPTIMIZED bottleneck (row 6): SVML exp8 = 57.8% = 4.194s**
- Loop-carried dep: `S *= exp(drift + sigma*z[t])` serialises 256 exp calls per path
- Fix: log-sum reformulation → 1 exp call per path instead of 256
- Expected next speedup: ~2× on top of current 3.05×

### PMU model for MLP>1 (SIMD regime)
- r0xA3 events accumulate per-outstanding-miss-per-cycle when MLP>1
- Correction: use `r04a3/r0ca3` as stall *fraction*, multiply by `total_cycles`
- Identity: `stall_corr + ooo_corr = total_cycles` ✓
