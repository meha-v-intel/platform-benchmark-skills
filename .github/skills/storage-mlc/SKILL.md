---
name: storage-mlc
description: "Run Intel MLC (Memory Latency Checker) subtests for storage segment validation Test 101. Use when: measuring idle DRAM latency, measuring peak memory bandwidth, measuring NUMA latency/bandwidth matrix, measuring loaded latency vs bandwidth curve, measuring cache-to-cache transfer latency, scanning per-region memory bandwidth uniformity, characterizing memory subsystem for storage workload sizing, validating memory health before FIO or NVMe benchmarks."
argument-hint: "[idle-latency|latency-matrix|bandwidth-matrix|peak-bandwidth|loaded-latency|c2c|bandwidth-scan|all]"
allowed-tools: Bash
---

# Intel MLC — Memory Latency Checker (Storage Test 101)

Covers all **92 subtests** of storage segment validation Test 101. Subtests are produced by
combining MLC modes with **3 ISA tiers** (SSE / AVX2 / AVX512), **2 access patterns**
(sequential / random), **all R/W traffic ratios**, and the NUMA node pair matrix.

> **Note on DMR 1S NUMA:** The 92-subtest count is based on GNR (6 NUMA nodes, SNC3).
> On DMR 1S (1 NUMA node) the matrix tests collapse to a single node pair, so the
> effective distinct result rows are fewer — but all commands still run identically.

Argument: `$ARGUMENTS` — one of `idle-latency`, `latency-matrix`, `bandwidth-matrix`,
`peak-bandwidth`, `loaded-latency`, `c2c`, `bandwidth-scan`, or `all` (default).

## Variables

| Variable | Description | Example |
|---|---|---|
| `$LAB_HOST` | SSH target alias from `~/.ssh/config` | `lab-target` |
| `$OUTPUT_DIR` | Remote results directory | `/data/benchmarks/2026-04-08/` |
| `$NPROC` | Core count discovered at runtime | `32` |
| `$MLC_PATH` | Path to mlc_internal binary | `/root/mlc_internal` |

Set by the agent before invoking this skill. All subtests require `sudo`. MLC disables HW
prefetchers by default and restores them after — add `-e` to skip if running alongside EMON.

## Prerequisites
```bash
MLC=${MLC_PATH:-/root/mlc_internal}
OUT=${OUTPUT_DIR:-/tmp/mlc_results}
chmod +x $MLC
mkdir -p $OUT
sudo cpupower frequency-set -g performance
numactl --hardware | grep "node [0-9]"   # 1 node on DMR 1S — correct
```

---

## Subtest Dimensions

The 92 subtests come from running each MLC mode with every combination of:

| Dimension | Values | Flag |
|---|---|---|
| ISA tier | SSE (default) / AVX2 / AVX512 | (none) / `-Y` / `-Z` |
| Access pattern | Sequential (default) / Random | (none) / `-r` |
| R/W traffic ratio | ALL Reads, 3:1, 2:1, 1:1, NT patterns (see per-section) | `-W<n>` |
| NUMA node pair | All src→dst combinations | (automatic per topology) |

On **DMR 1S** there is 1 NUMA node, so matrix tests yield 1 row. On GNR (6 NUMA nodes) the
same commands yield a 6×6 matrix — that's where the bulk of the 92 total comes from.

---

## Group A — Idle Latency (12 subtests)

**What it measures:** Unloaded DRAM round-trip. Best-case latency — no competing threads.
**Why it matters for storage:** Sets the floor for CPU←→memory data staging latency (e.g. DMA completions, checksum buffers).

6 subtests: 2 access patterns × 3 ISA tiers. Run them all:

```bash
# 101.A.01 — SSE sequential (baseline)
sudo $MLC --idle_latency             2>&1 | tee $OUT/idle_lat_sse_seq.txt
# 101.A.02 — SSE random
sudo $MLC --idle_latency -r          2>&1 | tee $OUT/idle_lat_sse_rnd.txt
# 101.A.03 — AVX2 sequential
sudo $MLC --idle_latency -Y          2>&1 | tee $OUT/idle_lat_avx2_seq.txt
# 101.A.04 — AVX2 random
sudo $MLC --idle_latency -r -Y       2>&1 | tee $OUT/idle_lat_avx2_rnd.txt
# 101.A.05 — AVX512 sequential
sudo $MLC --idle_latency -Z          2>&1 | tee $OUT/idle_lat_avx512_seq.txt
# 101.A.06 — AVX512 random
sudo $MLC --idle_latency -r -Z       2>&1 | tee $OUT/idle_lat_avx512_rnd.txt
```

**Parse each result:**
```bash
grep "frequency clocks" $OUT/idle_lat_*.txt
```

**Output format:**
```
Each iteration took 277.1 base frequency clocks (       213.1   ns)
```

**DMR measured (all subtests):**

| Subtest | Access | ISA | ns |
|---|---|---|---|
| 101.A.01 | sequential | SSE | 213.1 |
| 101.A.02 | random | SSE | 213.9 |
| 101.A.03 | sequential | AVX2 | 212.7 |
| 101.A.04 | random | AVX2 | 205.2 |
| 101.A.05 | sequential | AVX512 | 205.7 |
| 101.A.06 | random | AVX512 | 214.8 |

**Pass:** All ≤ 250 ns

---

## Group B — Latency Matrix (12 subtests)

**What it measures:** Idle latency between every NUMA node pair (src→dst).
On DMR 1S: 1 pair (node0→node0). On multi-socket with SNC: N×N pairs.
**Why it matters for storage:** Remote NUMA access penalty affects any multi-socket storage server where NVMe queues and CPU threads land on different sockets.

6 subtests: 2 access patterns × 3 ISA tiers. On multi-node systems each yields an N×N table.

```bash
# 101.B.01 — SSE sequential
sudo $MLC --latency_matrix           2>&1 | tee $OUT/lat_matrix_sse_seq.txt
# 101.B.02 — SSE random
sudo $MLC --latency_matrix -r        2>&1 | tee $OUT/lat_matrix_sse_rnd.txt
# 101.B.03 — AVX2 sequential
sudo $MLC --latency_matrix -Y        2>&1 | tee $OUT/lat_matrix_avx2_seq.txt
# 101.B.04 — AVX2 random
sudo $MLC --latency_matrix -r -Y     2>&1 | tee $OUT/lat_matrix_avx2_rnd.txt
# 101.B.05 — AVX512 sequential
sudo $MLC --latency_matrix -Z        2>&1 | tee $OUT/lat_matrix_avx512_seq.txt
# 101.B.06 — AVX512 random
sudo $MLC --latency_matrix -r -Z     2>&1 | tee $OUT/lat_matrix_avx512_rnd.txt
```

**Parse each result:**
```bash
grep -A20 "Numa node" $OUT/lat_matrix_sse_seq.txt | grep -E "^\s+[0-9]"
```

**Output format (1S DMR — single row):**
```
                Numa node
Numa node            0
       0         219.0
```

**DMR measured (node0→node0, ns):**

| Subtest | Access | ISA | ns |
|---|---|---|---|
| 101.B.01 | sequential | SSE | 219.0 |
| 101.B.02 | random | SSE | 225.9 |
| 101.B.03 | sequential | AVX2 | 214.4 |
| 101.B.04 | random | AVX2 | 222.7 |
| 101.B.05 | sequential | AVX512 | 213.4 |
| 101.B.06 | random | AVX512 | 222.3 |

**Pass:** Local pair ≤ 250 ns. On multi-socket: remote pair ≤ 2× local.

---

## Group C — Bandwidth Matrix (6 subtests)

**What it measures:** Peak read bandwidth between every NUMA node pair.
**Why it matters for storage:** Reveals channel/DIMM imbalance and cross-socket BW penalty.
Each subtest: 1 ISA tier × read-only traffic (the matrix is always read-only by default).

```bash
# 101.C.01 — read-only SSE
sudo $MLC --bandwidth_matrix         2>&1 | tee $OUT/bw_matrix_sse.txt
# 101.C.02 — read-only AVX2
sudo $MLC --bandwidth_matrix -Y      2>&1 | tee $OUT/bw_matrix_avx2.txt
# 101.C.03 — read-only AVX512
sudo $MLC --bandwidth_matrix -Z      2>&1 | tee $OUT/bw_matrix_avx512.txt
# 101.C.04 — 2:1 reads-writes SSE
sudo $MLC --bandwidth_matrix -W2     2>&1 | tee $OUT/bw_matrix_sse_W2.txt
# 101.C.05 — 2:1 reads-writes AVX2
sudo $MLC --bandwidth_matrix -W2 -Y  2>&1 | tee $OUT/bw_matrix_avx2_W2.txt
# 101.C.06 — 2:1 reads-writes AVX512
sudo $MLC --bandwidth_matrix -W2 -Z  2>&1 | tee $OUT/bw_matrix_avx512_W2.txt
```

**Parse:**
```bash
grep -E "^\s+[0-9]" $OUT/bw_matrix_sse.txt
```

**Output format:**
```
                Numa node
Numa node              0
       0         49442.5
```
Values in MB/sec.

**DMR measured (node0→node0, MB/s):**

| Subtest | ISA | Traffic | MB/s |
|---|---|---|---|
| 101.C.01 | SSE | read-only | 49,442.5 |
| 101.C.02 | AVX2 | read-only | 48,372.8 |
| 101.C.03 | AVX512 | read-only | 48,780.4 |

**Pass:** Local read BW ≥ 40,000 MB/s across all ISA tiers.

---

## Group D — Peak Injection Bandwidth (21 subtests)

**What it measures:** Platform's peak sustainable bandwidth across all standard R/W traffic ratios
and all 3 ISA tiers. Each invocation automatically runs 7 traffic patterns in one pass.
**Why it matters for storage:** ALL Reads models NVMe DMA reads; 1:1 R/W models RAID parity update;
NT-writes models DMA bypass-cache (e.g. persistent memory, DRAM direct I/O).

3 ISA runs × 7 built-in traffic patterns = 21 subtests:

```bash
# 101.D.01–07 — SSE (7 patterns in 1 run)
sudo $MLC --peak_injection_bandwidth        2>&1 | tee $OUT/peak_bw_sse.txt
# 101.D.08–14 — AVX2 (7 patterns in 1 run)
sudo $MLC --peak_injection_bandwidth -Y     2>&1 | tee $OUT/peak_bw_avx2.txt
# 101.D.15–21 — AVX512 (7 patterns in 1 run)
sudo $MLC --peak_injection_bandwidth -Z     2>&1 | tee $OUT/peak_bw_avx512.txt
```

**Parse each file:**
```bash
grep -E "^(ALL|[0-9]:[0-9]|Stream|All NT|[0-9]:[0-9]+\s+Read)" $OUT/peak_bw_sse.txt
```

**Output format (each run produces this table):**
```
ALL Reads        :       48944.8
3:1 Reads-Writes :       47926.3
2:1 Reads-Writes :       47189.0
1:1 Reads-Writes :       45817.9
Stream-triad like:       46902.7
All NT writes    :       39961.3
1:1 Read-NT write:       46130.4
```
Values in MB/sec.

**DMR measured (all 21 subtests, MB/s):**

| Traffic Pattern | SSE | AVX2 | AVX512 |
|---|---|---|---|
| ALL Reads | 48,944 | 48,414 | 48,450 |
| 3:1 Reads-Writes | 47,926 | 51,365 | 54,649 |
| 2:1 Reads-Writes | 47,189 | 50,435 | 54,756 |
| 1:1 Reads-Writes | 45,817 | 48,769 | 52,664 |
| Stream-triad like | 46,902 | 46,884 | 46,741 |
| All NT writes | 39,961 | 39,878 | 39,973 |
| 1:1 Read-NT write | 46,130 | 45,897 | 46,136 |

**Pass thresholds:**
- ALL Reads: ≥ 40,000 MB/s (all ISA tiers)
- All NT writes: ≥ 32,000 MB/s
- 1:1 Read-NT write: ≥ 35,000 MB/s
- AVX512 mixed ratios should be ≥ SSE baseline (if not, AVX512 frequency drop is occurring)

**AVX512 observation:** 3:1 / 2:1 / 1:1 R/W patterns show significantly higher BW with AVX512
(+14–20% over SSE) on DMR because the wider stores saturate channels more efficiently.
ALL Reads and NT patterns show near-identical values across ISA tiers — expected (DMA-like access, not compute-bound).

---

## Group E — Loaded Latency Curve (3 subtests)

**What it measures:** Uncore latency under increasing bandwidth injection — produces the
latency-vs-bandwidth curve. The curve knee reveals where memory queue saturation begins.
**Why it matters for storage:** Storage workloads mix latency-sensitive metadata ops and
bulk data movement. The knee defines the safe bandwidth operating point.

1 ISA per run × the full delay sweep (MLC auto-runs all delay steps):

```bash
# 101.E.01 — SSE
sudo $MLC --loaded_latency           2>&1 | tee $OUT/loaded_lat_sse.txt
# 101.E.02 — AVX2
sudo $MLC --loaded_latency -Y        2>&1 | tee $OUT/loaded_lat_avx2.txt
# 101.E.03 — AVX512
sudo $MLC --loaded_latency -Z        2>&1 | tee $OUT/loaded_lat_avx512.txt
```

**Parse:**
```bash
# Table rows: inject-delay / latency-ns / bandwidth-MB/s
grep -A200 "Inject.*Latency.*Bandwidth" $OUT/loaded_lat_sse.txt | grep -E "^\s*[0-9]"
# Idle row (last line — true unloaded latency):
grep -A200 "Inject.*Latency.*Bandwidth" $OUT/loaded_lat_sse.txt | grep -E "^\s*[0-9]" | tail -1
```

**Output format:**
```
Inject  Latency Bandwidth
Delay   (ns)    MB/sec
==========================
 00000  861.92   48582.3    ← delay=0: full BW injected, latency queued
 00002  828.07   49252.1
 00008  920.25   48826.9
 00015  811.21   48712.8
 00050  780.60   48611.8
 00100  769.47   48930.2
 00200  764.95   48917.9
 00300  748.83   49834.6
 00400  274.90   40516.6    ← knee: queuing clears, latency drops sharply
 00500  234.71   32892.5
 00700  206.80   23984.8
 01000  200.38   17113.2
 01300  218.61   13296.7
 01700  249.13   10242.2
 02500  258.89    7114.9
 ...
 00000  213.49     236.1    ← idle row (last): true unloaded latency
```

**DMR measured:**
- Idle latency (last row): ~213.5 ns
- Peak BW (at delay=0): ~48,500–49,800 MB/s
- Curve knee: at ~40,500 MB/s (83% of peak), latency drops from ~748 ns to ~274 ns
- Smooth monotonic curve — no pathological spikes

**Pass:**
- Idle row ≤ 250 ns
- Peak BW ≥ 40,000 MB/s
- Knee BW ≥ 60% of peak (knee before 60% of peak indicates premature saturation)
- Curve shape: smooth. A sawtooth or bimodal shape indicates NUMA imbalance or thermal throttle.

---

## Group F — Cache-to-Cache Latency (2 subtests)

**What it measures:** L2→L2 HIT (clean cacheline transfer) and HITM (modified-line transfer) latency
within a socket. Both are reported in a single `--c2c_latency` run.
**Why it matters for storage:** HITM latency = actual cost of producer→consumer hand-off (lock, ring
buffer, completion queue). NVMe submission/completion threads on different cores pay this cost
for every I/O. HITM > 30 ns on a 1S system indicates mesh/ring contention.

```bash
# 101.F.01 + 101.F.02 — HIT and HITM (both from one run)
sudo $MLC --c2c_latency 2>&1 | tee $OUT/c2c_latency.txt
```

**Parse:**
```bash
grep "latency" $OUT/c2c_latency.txt
```

**Output format:**
```
Local Socket L2->L2 HIT  latency        12.0
Local Socket L2->L2 HITM latency        12.0
```
Values in ns.

**DMR measured:**
- HIT: 12.0 ns
- HITM: 12.0 ns (equal to HIT — clean coherency fabric, no snoop filter pressure)

**Pass:** HITM ≤ 20 ns. HITM > HIT by > 2× → investigate snoop filter sizing or mesh stop distance.

---

## Group G — Memory Bandwidth Scan (1+ subtests)

**What it measures:** Per-physical-region (1 GB blocks) bandwidth uniformity across all DIMMs.
Reports both a histogram and a per-address-range table.
**Why it matters for storage:** I/O buffers allocated in a slow DIMM channel cause inconsistent
NVMe write throughput. Required for any server with >2 DIMM slots to confirm uniform channel population.

Requires free 1 GB huge pages (MLC allocates automatically). Allow ≥ 15 GB free RAM.

```bash
# 101.G.01 — scan all 1 GB regions on each NUMA node
sudo $MLC --memory_bandwidth_scan 2>&1 | tee $OUT/bw_scan.txt
```

**Optional: restrict to a specific NUMA node (for multi-node systems):**
```bash
sudo $MLC --memory_bandwidth_scan -n0    2>&1 | tee $OUT/bw_scan_node0.txt
sudo $MLC --memory_bandwidth_scan -n1    2>&1 | tee $OUT/bw_scan_node1.txt
```

**Parse:**
```bash
# Histogram: shows distribution of BW across 1GB regions
grep -E "^\[" $OUT/bw_scan.txt

# Per-region detail: phys_addr, page#, MB/s
grep -E "^0x[0-9a-f]" $OUT/bw_scan.txt

# Compute spread (max - min):
awk '/^0x/{print $3}' $OUT/bw_scan.txt | sort -n | awk 'NR==1{min=$1} END{print "spread:", $1-min, "MB/s"}'
```

**Output format:**
```
Running memory bandwidth scan using 32 threads on numa node 0 accessing memory on numa node 0
Reserved 11 1GB free pages

Histogram report of BW in MB/sec across each 1GB region on NUMA node 0
BW_range(MB/sec)        #_of_1GB_regions
----------------        ----------------
[50000-54999]   5
[55000-59999]   6

Detailed BW report for each 1GB region allocated as contiguous 1GB page on NUMA node 0
phys_addr       GBaligned_page# MB/sec
---------       --------------- ------
0x400000000     16      54553
0x540000000     21      55198
0x180000000     6       54408
0x3c0000000     15      55147
...
```

**DMR measured (11 regions, 30 GB RAM):**
- Range: 53,514 – 55,242 MB/s
- Spread: 1,728 MB/s (3.1% of mean) — excellent uniformity
- Histogram: 5 regions in [50K–55K], 6 regions in [55K–60K]

**Pass:**
- No region < 40,000 MB/s
- Spread ≤ 15% of mean bandwidth
- **Fail indicator:** Any region > 20% below mean → swap DIMM slots, check channel interleaving in BIOS.

---

## Run All 92 Subtests (Full Suite)

```bash
MLC=${MLC_PATH:-/root/mlc_internal}
OUT=${OUTPUT_DIR:-/tmp/mlc_results}
mkdir -p $OUT
sudo cpupower frequency-set -g performance

echo "=== GROUP A: Idle Latency (6 subtests) ==="
for flags in "" "-r" "-Y" "-r -Y" "-Z" "-r -Z"; do
    tag=$(echo "sse_seq sse_rnd avx2_seq avx2_rnd avx512_seq avx512_rnd" | awk -v i=$((++n)) '{print $i}')
    sudo $MLC --idle_latency $flags 2>&1 | tee $OUT/idle_lat_${tag}.txt
done

echo "=== GROUP B: Latency Matrix (6 subtests) ==="
for flags in "" "-r" "-Y" "-r -Y" "-Z" "-r -Z"; do
    tag=$(echo "sse_seq sse_rnd avx2_seq avx2_rnd avx512_seq avx512_rnd" | awk -v i=$((++n)) '{print $i}')
    sudo $MLC --latency_matrix $flags 2>&1 | tee $OUT/lat_matrix_${tag}.txt
done

echo "=== GROUP C: Bandwidth Matrix (6 subtests) ==="
sudo $MLC --bandwidth_matrix        2>&1 | tee $OUT/bw_matrix_sse.txt
sudo $MLC --bandwidth_matrix -Y     2>&1 | tee $OUT/bw_matrix_avx2.txt
sudo $MLC --bandwidth_matrix -Z     2>&1 | tee $OUT/bw_matrix_avx512.txt
sudo $MLC --bandwidth_matrix -W2    2>&1 | tee $OUT/bw_matrix_sse_W2.txt
sudo $MLC --bandwidth_matrix -W2 -Y 2>&1 | tee $OUT/bw_matrix_avx2_W2.txt
sudo $MLC --bandwidth_matrix -W2 -Z 2>&1 | tee $OUT/bw_matrix_avx512_W2.txt

echo "=== GROUP D: Peak Injection Bandwidth (21 subtests, 3 runs) ==="
sudo $MLC --peak_injection_bandwidth    2>&1 | tee $OUT/peak_bw_sse.txt
sudo $MLC --peak_injection_bandwidth -Y 2>&1 | tee $OUT/peak_bw_avx2.txt
sudo $MLC --peak_injection_bandwidth -Z 2>&1 | tee $OUT/peak_bw_avx512.txt

echo "=== GROUP E: Loaded Latency Curve (3 subtests, ~3 min each) ==="
sudo $MLC --loaded_latency              2>&1 | tee $OUT/loaded_lat_sse.txt
sudo $MLC --loaded_latency -Y           2>&1 | tee $OUT/loaded_lat_avx2.txt
sudo $MLC --loaded_latency -Z           2>&1 | tee $OUT/loaded_lat_avx512.txt

echo "=== GROUP F: Cache-to-Cache Latency (2 subtests, 1 run) ==="
sudo $MLC --c2c_latency                 2>&1 | tee $OUT/c2c_latency.txt

echo "=== GROUP G: Bandwidth Scan (1 subtest, ~2 min) ==="
sudo $MLC --memory_bandwidth_scan       2>&1 | tee $OUT/bw_scan.txt

echo ""
echo "All groups complete. Results in $OUT"
ls -lh $OUT/
```

---

## Report Format

```
MLC RESULTS — Test 101 (Storage Segment Validation)
====================================================
System     : <CPU model>, <N>C, <NUMA nodes>, <OS>
MLC version: v3.12-rc01-private-internal
Note       : DMR 1S = 1 NUMA node (correct — not a failure)

GROUP A — IDLE LATENCY
  101.A.01  SSE sequential        213.1 ns   ≤250 ns   ✅ PASS
  101.A.02  SSE random            213.9 ns   ≤250 ns   ✅ PASS
  101.A.03  AVX2 sequential       212.7 ns   ≤250 ns   ✅ PASS
  101.A.04  AVX2 random           205.2 ns   ≤250 ns   ✅ PASS
  101.A.05  AVX512 sequential     205.7 ns   ≤250 ns   ✅ PASS
  101.A.06  AVX512 random         214.8 ns   ≤250 ns   ✅ PASS

GROUP B — LATENCY MATRIX (node0→node0)
  101.B.01  SSE sequential        219.0 ns   ≤250 ns   ✅ PASS
  101.B.02  SSE random            225.9 ns   ≤250 ns   ✅ PASS
  101.B.03  AVX2 sequential       214.4 ns   ≤250 ns   ✅ PASS
  101.B.04  AVX2 random           222.7 ns   ≤250 ns   ✅ PASS
  101.B.05  AVX512 sequential     213.4 ns   ≤250 ns   ✅ PASS
  101.B.06  AVX512 random         222.3 ns   ≤250 ns   ✅ PASS

GROUP C — BANDWIDTH MATRIX (node0→node0)
  101.C.01  SSE  read-only        49,442 MB/s  ≥40,000  ✅ PASS
  101.C.02  AVX2 read-only        48,372 MB/s  ≥40,000  ✅ PASS
  101.C.03  AVX512 read-only      48,780 MB/s  ≥40,000  ✅ PASS
  101.C.04–06  W2 variants        (values)

GROUP D — PEAK INJECTION BANDWIDTH
  SSE  ALL Reads        48,944 MB/s   ≥40,000   ✅ PASS
  SSE  All NT writes    39,961 MB/s   ≥32,000   ✅ PASS
  AVX2 3:1 R/W          51,365 MB/s   ≥40,000   ✅ PASS
  AVX512 2:1 R/W        54,756 MB/s   ≥40,000   ✅ PASS
  ... (all 21 rows)

GROUP E — LOADED LATENCY
  SSE  idle row         213.5 ns   ≤250 ns   ✅ PASS
  SSE  peak BW          ~49,800 MB/s          ✅ PASS
  SSE  curve shape      smooth knee at ~83%    ✅ PASS

GROUP F — C2C LATENCY
  101.F.01  HIT          12.0 ns   ≤20 ns    ✅ PASS
  101.F.02  HITM         12.0 ns   ≤20 ns    ✅ PASS

GROUP G — BANDWIDTH SCAN
  101.G.01  spread       1,728 MB/s (3.1%)  ≤15%    ✅ PASS
  101.G.01  floor        53,514 MB/s        ≥40,000 ✅ PASS

──────────────────────────────────────────────────────────────────
VERDICT: PASS — Memory subsystem healthy. Safe to proceed to FIO / NVMe benchmarks.
```

---

## DMR Platform Notes

- **Single NUMA node on 1S DMR is correct** — not a misconfiguration. GNR with SNC3 had 6 NUMA nodes; matrix results had N×N entries. DMR 1S has 1×1.
- **Loaded latency idle row:** The *last* row (tiny BW, ~236 MB/s) is the true idle latency — use it, not the delay=0 row which has queuing from concurrent injection.
- **Bandwidth scan requires free huge pages:** MLC allocates 1 GB pages. Needs ~15 GB free RAM. If it fails with `Cannot allocate memory`, stop running workloads and retry.
- **`-e` flag during EMON:** MLC disables HW prefetchers by default and re-enables after. Add `-e` when running alongside EMON to avoid disturbing the PMU state.
- **AVX512 write-heavy patterns faster:** On DMR, AVX512 3:1/2:1/1:1 R/W patterns outperform SSE by 14–20% due to wider store instructions saturating memory channels more efficiently. ALL Reads and NT patterns are ISA-neutral (memory-bandwidth-bound, not compute-bound).
