---
name: storage-c2c
description: "Run intra-socket core-to-core latency benchmark for storage segment validation Test 102. Use when: measuring cache coherency latency between cores, measuring core-to-core transfer latency, checking MESIF protocol cost, measuring lock hand-off overhead, validating coherency fabric for storage I/O thread placement, generating a full NxN core latency heatmap, characterizing multi-core communication for NVMe queue placement."
argument-hint: "[min|max|mean|matrix|all]"
allowed-tools: Bash
---

# Core-to-Core Latency (Storage Test 102)

Measures cache coherency (MESIF) latency between every pair of cores on the socket.
Produces 4 subtests: **min latency**, **max latency**, **mean latency**, and a full **N×N matrix heatmap**.

Argument: `$ARGUMENTS` — one of `min`, `max`, `mean`, `matrix`, or `all` (default).

## Variables

| Variable | Description | Example |
|---|---|---|
| `$LAB_HOST` | SSH target alias from `~/.ssh/config` | `lab-target` |
| `$OUTPUT_DIR` | Remote results directory | `/data/benchmarks/2026-04-08/` |
| `$NPROC` | Core count discovered at runtime | `32` |
| `$WORK_DIR` | Home directory on remote machine | `/root` |

Set by the agent before invoking this skill.

## Prerequisites

```bash
C2C_DIR=${WORK_DIR:-/root}/core-to-core-latency
C2C=${C2C_DIR}/target/release/core-to-core-latency
OUT=${OUTPUT_DIR:-/tmp/c2c_results}
mkdir -p $OUT

# Build if not present (requires cargo — install with: dnf install -y rust cargo)
if [[ ! -x "$C2C" ]]; then
    which cargo || dnf install -y rust cargo
    git clone https://github.com/nviennot/core-to-core-latency.git "$C2C_DIR"
    cd "$C2C_DIR" && cargo build --release
fi

# Performance governor
sudo cpupower frequency-set -g performance
sudo systemctl stop irqbalance

# Verify
$C2C --help | head -5
nproc    # confirm expected core count
```

## Benchmark: Bench Mode 1 (CAS — default)

All 4 subtests come from a single run of bench mode 1 (`--bench 1`, the default).
Bench 1 measures CAS (Compare-And-Swap) latency on a single shared cache line —
the dominant pattern for storage lock hand-offs and NVMe submission ring head/tail pointers.

| Benchmark | `--bench` | What it models |
|---|---|---|
| 1 — CAS on one shared cache line | `1` (default) | Lock contention, ring buffer pointer updates |
| 2 — SWSR on two cache lines | `2` | Producer/consumer with separate read/write lines |
| 3 — Message passing (many cache lines + clock) | `3` | Async message queue, completion notification |

**For storage Test 102, bench mode 1 is the primary test.** Run all 3 modes for a full picture.

---

## Subtest 102.1 — Min Latency

The minimum measured latency across all core pairs —  
represents **HT siblings** (two logical cores sharing a physical core / L1 cache).
This is the floor latency achievable on this socket.

```bash
# Quick validation run (8 cores, ~30 s)
sudo $C2C 500 20 --cores 0,1,2,3,4,5,6,7 2>&1 | tee $OUT/c2c_quick.txt
grep "Min" $OUT/c2c_quick.txt

# Full run — all cores (~3 min with 1000 iter × 300 samples)
sudo $C2C 1000 300 2>&1 | tee $OUT/c2c_full.txt
grep "Min" $OUT/c2c_full.txt
```

**Output format:**
```
    Min  latency: 19.6ns ±0.0 cores: (11,10)
```

**DMR measured:** 19.6–19.7 ns (HT sibling pairs — e.g. cores 3,2 or 11,10)  
**Pass:** ≤ 25 ns  
**Interpretation:** Values ≈ 20 ns → HT sibling pair (L1 cache hit, no coherency message). Values ≈ 90–110 ns → cross-core pair (L3 ring/mesh hop).

---

## Subtest 102.2 — Max Latency

The maximum measured latency across all core pairs —  
represents the **worst-case cross-core hop** on the mesh (cores at opposite ends of the ring).
Critical for storage worst-case analysis: an I/O completion thread on core 0
waiting on a lock held by a thread running on core 27 pays this latency every hand-off.

```bash
grep "Max" $OUT/c2c_full.txt
```

**Output format:**
```
    Max  latency: 105.7ns ±1.0 cores: (27,1)
```

**DMR measured:** 105–115 ns (e.g. cores 27,1 or 23,8 — distant mesh stops)  
**Pass:** ≤ 150 ns  
**Interpretation:** On DMR 1S the mesh is a 2D ring. The maximum pair is determined by the physical distance between the two cores' mesh stops. Values > 150 ns indicate mesh congestion or a BIOS topology issue.

---

## Subtest 102.3 — Mean Latency

Average latency across all core pairs — reflects the typical latency a storage thread will  
see when communicating with a random peer core (e.g. interrupt handler → worker thread placement).

```bash
grep "Mean" $OUT/c2c_full.txt
```

**Output format:**
```
    Mean latency: 92.4ns
```

**DMR measured:** 91–93 ns (32C, all pairs)  
**Pass:** ≤ 120 ns  
**Interpretation:** Mean > 2× min indicates heavy cross-socket traffic or NUMA mis-placement (not applicable on 1S DMR). Mean close to max indicates most core pairs are at long mesh distances — consider CPU topology-aware thread pinning.

---

## Subtest 102.4 — N×N Core Pair Heatmap Matrix

The full N×N lower-triangular matrix of all pair latencies (mean ± jitter in ns).
Used to identify topology zones: HT siblings, intra-cluster, cross-cluster, and
any anomalous high-latency core pairs that indicate a faulty mesh stop or BIOS misconfiguration.

```bash
# Save full matrix output
sudo $C2C 1000 300 2>&1 | tee $OUT/c2c_matrix.txt

# CSV format for programmatic analysis / heatmap plotting
sudo $C2C 1000 300 --csv 2>&1 | tee $OUT/c2c_matrix_full.txt
# CSV section starts after the human-readable block (last N lines of output)
grep -v "CPU:\|Num \|latency:\|^$\|) CAS\|^\s*[0-9]*\s*$" $OUT/c2c_matrix_full.txt \
    | tail -$((NPROC)) > $OUT/c2c_matrix.csv
```

**Human-readable output format (32 cores, DMR — excerpt):**
```
           0       1       2       3  ...  30      31
      0
      1   23±1
      2  102±1   103±1
      3  110±7   100±1    20±0
      4  104±2   103±3    98±0    98±0
      5  100±0    98±0   101±3    97±0    20±0
      ...
     30   98±2    92±0    93±1    96±2   ...    27±0
     31   92±1   102±5    98±1    91±0   ...    27±0

    Min  latency: 19.7ns ±0.0 cores: (3,2)
    Max  latency: 115.4ns ±4.9 cores: (23,8)
    Mean latency: 91.8ns
```

**DMR topology zones visible in the matrix:**

| Zone | Latency range | Example pairs | Meaning |
|---|---|---|---|
| HT siblings | 19–25 ns | (3,2), (5,4), (11,10), (17,16) | Logical cores sharing a physical core |
| Intra-cluster | 80–105 ns | (4,0), (8,0), (16,0) | Same die, nearby mesh stops |
| Cross-cluster | 90–115 ns | (27,1), (23,8), (26,0) | Distant mesh stops |

**Pass:** No core pair (excluding HT siblings) > 150 ns  
**Anomaly flag:** Any pair > 200 ns or HT sibling pair > 30 ns → investigate core disable, BIOS settings, mesh ring fuse.

---

## Running All 4 Subtests

All 4 subtests (min, max, mean, matrix) are produced from **a single command**. Run once, parse all:

```bash
C2C=${WORK_DIR:-/root}/core-to-core-latency/target/release/core-to-core-latency
OUT=${OUTPUT_DIR:-/tmp/c2c_results}
mkdir -p $OUT

sudo cpupower frequency-set -g performance
sudo systemctl stop irqbalance

echo "[Test 102] Core-to-Core Latency — all cores ($(nproc)C), ~3 min..."
sudo $C2C 1000 300 2>&1 | tee $OUT/c2c_full.txt

# Also save CSV for heatmap
sudo $C2C 1000 300 --csv 2>&1 | tee $OUT/c2c_full_csv.txt

# Parse the 4 subtests
echo "--- 102.1 Min ---"
grep "Min" $OUT/c2c_full.txt

echo "--- 102.2 Max ---"
grep "Max" $OUT/c2c_full.txt

echo "--- 102.3 Mean ---"
grep "Mean" $OUT/c2c_full.txt

echo "--- 102.4 Matrix ---"
grep -A$(($(nproc)+5)) "1) CAS" $OUT/c2c_full.txt | head -$(($(nproc)+5))
```

**Optional — run all 3 bench modes for deeper analysis:**
```bash
# Bench 2: SWSR (separate read/write cache lines — models producer/consumer queues)
sudo $C2C 1000 300 -b 2 2>&1 | tee $OUT/c2c_b2.txt

# Bench 3: Message passing / clock (models async I/O completion notification)
sudo $C2C 1000 300 -b 3 2>&1 | tee $OUT/c2c_b3.txt
```

---

## Report Format

```
CORE-TO-CORE LATENCY — Test 102 (Storage Segment Validation)
=============================================================
System   : <CPU model>, <N>C, <OS>
Tool     : core-to-core-latency v1.2.0 (bench mode 1 — CAS)
Cores    : all <N> logical cores

SUBTEST            MEASURED               THRESHOLD      STATUS
───────────────────────────────────────────────────────────────
102.1  Min latency    19.6 ns ±0.0  (3,2)   ≤ 25 ns    ✅ PASS
102.2  Max latency   105.7 ns ±1.0 (27,1)   ≤ 150 ns   ✅ PASS
102.3  Mean latency   92.4 ns                ≤ 120 ns   ✅ PASS
102.4  Matrix         <N>×<N> heatmap saved  no pair >150 ns  ✅ PASS
───────────────────────────────────────────────────────────────
Topology zones:
  HT sibling pairs  : 19–25 ns   (cores sharing a physical core)
  Intra-socket pairs: 80–115 ns  (mesh ring hops)
  Anomalous pairs   : none

VERDICT: PASS — Coherency fabric healthy. Thread-pair placement can use any core pair.
         For latency-critical storage paths (NVMe submission/completion), prefer HT sibling pairs.
```

---

## DMR Platform Notes

- **HT siblings are always ~20 ns** — these are the only pairs below ~80 ns. They share L1/L2 cache so no coherency message crosses the ring. Ideal for tightly coupled producer/consumer thread pairs (e.g. NVMe submission head and IRQ handler).
- **SMT context:** On DMR, logical cores are paired. Core 0 & 1 are HT siblings, 2 & 3 are HT siblings, etc. — but pairs visible in the matrix depend on topology (check `lscpu -e` to confirm).
- **Max latency core pair varies:** The worst pair changes run to run but is always between cores at maximum mesh distance (~115 ns). This is deterministic hardware geometry, not a bug.
- **`irqbalance` must be stopped** before the full run — it migrates IRQs mid-measurement causing latency spikes that inflate jitter values (±1 vs ±10+ ns).
- **Full run takes ~3 min** at `1000 300` (1000 iterations × 300 samples × 496 core pairs on a 32C system). Use `200 10` for a quick ~20-second sanity check.
- **CSV output:** The `--csv` flag appends a CSV matrix at the end of stdout (after the human-readable block). Suitable for importing into Excel or plotting a heatmap. The CSV section starts after the `Mean latency:` line.
