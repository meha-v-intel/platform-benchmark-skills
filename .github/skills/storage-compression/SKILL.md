---
name: storage-compression
description: "Compression/decompression throughput benchmark for Test 105. Use when: measuring lz4 compression speed, zlib (pigz) throughput, zstd throughput, compression ratio vs speed trade-off, storage tier compression validation, CPU-bound compression scaling, multi-thread compression test, single-thread zlib bandwidth, platform compression readiness."
argument-hint: "[lz4|zlib|zstd|all] [--level 1|3|6|9] [--threads 1|NPROC|all] [--corpus random|text|mixed]"
allowed-tools: Bash
---

# Storage Compression / Decompression — Test 105

Measures compression and decompression throughput (MB/s) and ratio across three codecs:
- **lz4** — ultra-fast byte-level compression (levels 1–9)
- **zlib via pigz** — DEFLATE-based, multi-threaded (levels 1–9, threads 1–NPROC)
- **zstd** — modern entropy coder, best ratio-vs-speed envelope (levels 1–9)

Each codec is exercised against three corpora: random (incompressible), zero (maximally compressible), text (realistic, ~2× ratio).

---

## Variables

```bash
NPROC=$(nproc --all)
CORPUS_DIR=/tmp/compression_bench
SESSION_DIR=./results/${SESSION_ID}/bench/compression

# Corpus sizes
CORPUS_RANDOM_SIZE_MB=512     # Incompressible (urandom) — throughput ceiling
CORPUS_ZERO_SIZE_MB=512       # Zero bytes — ratio/speed floor
CORPUS_TEXT_SIZE_MB=64        # Mixed text (realistic storage pattern)

# Tool paths (all standard PATH after dnf install lz4 pigz)
LZ4_BIN=$(which lz4)
PIGZ_BIN=$(which pigz)
ZSTD_BIN=$(which zstd)
```

---

## Prerequisites

```bash
# Verify tools are installed
lz4   --version 2>&1 | head -1   # Expected: LZ4 command line interface ... v1.9.x
pigz  --version 2>&1             # Expected: pigz 2.x
zstd  --version 2>&1 | head -1   # Expected: *** Zstandard CLI ... v1.5.x

# Install if missing (CentOS/RHEL — dnf; Ubuntu/Debian — apt-get)
# CentOS/RHEL:
dnf install -y lz4 pigz
# zstd ships with CentOS 10 base; already present if kernel >= 5.x install

# Verify kernel has DEFLATE acceleration (ISA-L / zlib-ng — informational only)
python3 -c "import zlib; print('zlib version:', zlib.ZLIB_VERSION)"
# Expected on DMR: zlib 1.3.1.zlib-ng  (zlib-ng = AVX2-accelerated)

# Create output dirs
mkdir -p ${CORPUS_DIR} ${SESSION_DIR}
```

> **minLZ subtests (Intel-internal):** Any subtests involving the minLZ codec can only be
> run after the Intel-internal minLZ tool has been built and installed on the target system.
> minLZ is not available via `dnf` or any public package manager. Obtain the source from the
> Intel-internal repository, build per its README, and confirm `minlz` (or equivalent binary)
> is on `$PATH` before attempting those subtests. All Groups A–C in this skill use only
> publicly available tools (lz4, pigz, zstd) and are unaffected by minLZ availability.

---

## EMON Collection — Compression Workload PMU Events

Collect hardware counters during the full sweep to characterize CPU efficiency and
detect whether compression is compute-bound, memory-bound, or cache-thrashing.

### Event Set

```bash
EMON_EVENTS="cycles,instructions,cache-misses,LLC-load-misses,\
cpu-migrations,page-faults,\
fp_arith_inst_retired.512b_packed_single,\
mem_load_retired.l3_miss"
```

| Counter | What it measures |
|---|---|
| `cycles` / `instructions` | IPC — efficiency of compression loop |
| `cache-misses` | CPU cache pressure during large-buffer passes |
| `LLC-load-misses` | DRAM spill — elevated if working set > LLC (45 MB on DMR) |
| `cpu-migrations` | OS noise — should be near-zero during pinned compress run |
| `fp_arith_inst_retired.512b_packed_single` | AVX-512 vectorisation inside zlib-ng / zstd |
| `mem_load_retired.l3_miss` | Confirms DRAM pressure on buffers > L3 |

### Start EMON (run in background before subtest)

```bash
# Start perf stat monitoring, output to session dir
perf stat \
  -e ${EMON_EVENTS} \
  --interval-print 2000 \
  -x , \
  -o ${SESSION_DIR}/emon_${CODEC}_${LEVEL}_${THREADS}t.csv \
  -- sleep 3600 &
EMON_PID=$!

echo "EMON PID: ${EMON_PID}"
```

### Stop EMON (after subtest completes)

```bash
kill ${EMON_PID} 2>/dev/null
wait ${EMON_PID} 2>/dev/null
echo "EMON stopped. Data: ${SESSION_DIR}/emon_${CODEC}_${LEVEL}_${THREADS}t.csv"
```

### Parse EMON Output

```bash
# Extract IPC and LLC miss rate from CSV
python3 - <<'EOF'
import csv, sys

emon_file = sys.argv[1] if len(sys.argv) > 1 else "/tmp/emon_sample.csv"
counters = {}
try:
    with open(emon_file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split(',')
            if len(parts) >= 3:
                name = parts[2].strip().strip('"')
                try:
                    val = float(parts[1].replace(',', ''))
                    counters[name] = counters.get(name, 0) + val
                except ValueError:
                    pass
    cycles = counters.get('cycles', 0)
    insns  = counters.get('instructions', 0)
    llc    = counters.get('LLC-load-misses', 0)
    cache  = counters.get('cache-misses', 0)
    ipc    = round(insns / cycles, 2) if cycles > 0 else 0
    llc_pct = round(100 * llc / max(cache, 1), 1)
    print(f"  IPC         : {ipc}  (healthy: >0.8 for compress, >1.5 for decompress)")
    print(f"  LLC miss %  : {llc_pct}%  (elevated: >10% indicates DRAM pressure)")
    print(f"  cycles      : {cycles:,.0f}")
    print(f"  instructions: {insns:,.0f}")
except FileNotFoundError:
    print(f"  EMON file not found: {emon_file}")
EOF
```

### Interpretation Table

| Signal | Expected (compress) | Expected (decompress) | FAIL indicator |
|---|---|---|---|
| IPC | 0.8 – 1.2 | 1.5 – 2.5 | < 0.5 (branch-heavy, bad pattern) |
| LLC miss % | < 5% (64 MB fits in L3) | < 5% | > 15% (DRAM bound) |
| `fp_arith_inst_retired` | > 0 (zlib-ng AVX2 or zstd AVX-512) | > 0 | 0 (scalar fallback only) |
| `cpu-migrations` | < 5 total | < 5 total | > 50 (OS noise, use taskset) |

---

## Corpus Generation

```bash
# Run once per session — ~10 seconds total
mkdir -p ${CORPUS_DIR}

echo "[corpus] generating random (${CORPUS_RANDOM_SIZE_MB}MB)..."
dd if=/dev/urandom bs=1M count=${CORPUS_RANDOM_SIZE_MB} \
   of=${CORPUS_DIR}/random.bin 2>/dev/null

echo "[corpus] generating zero (${CORPUS_ZERO_SIZE_MB}MB)..."
dd if=/dev/zero bs=1M count=${CORPUS_ZERO_SIZE_MB} \
   of=${CORPUS_DIR}/zero.bin 2>/dev/null

echo "[corpus] generating text (~${CORPUS_TEXT_SIZE_MB}MB)..."
find /usr/share/doc /usr/share/man -type f 2>/dev/null \
  | xargs cat 2>/dev/null \
  | head -c $((CORPUS_TEXT_SIZE_MB * 1024 * 1024)) \
  > ${CORPUS_DIR}/text.bin

ls -lh ${CORPUS_DIR}/
```

---

## Group A — lz4 Compression / Decompression (18 subtests)

Uses lz4's built-in `-b` benchmark mode for clean in-memory throughput.
Output format per line: `level#filename : original -> compressed (ratio), compress MB/s, decompress MB/s`

### A-1 through A-9: lz4 levels 1–9 on text corpus

```bash
CORPUS=${CORPUS_DIR}/text.bin
CODEC=lz4
for LEVEL in 1 2 3 4 5 6 7 8 9; do
    echo -n "[A-${LEVEL}] lz4 level ${LEVEL} text — "
    lz4 -b${LEVEL} ${CORPUS} 2>&1 | grep "^" | tail -1
    echo "" >> ${SESSION_DIR}/lz4_text_sweep.log
    lz4 -b${LEVEL} ${CORPUS} 2>&1 >> ${SESSION_DIR}/lz4_text_sweep.log
done
```

Expected output line (DMR, text corpus, level 1):
```
1#text.bin : 7885206 -> 3953947 (1.994), ~408 MB/s, ~3600 MB/s
```

### A-10: lz4 level 1 — random corpus (throughput ceiling)

```bash
lz4 -b1 ${CORPUS_DIR}/random.bin 2>&1 | tail -1
# Expected: ~19000–21000 MB/s compress, ~21000 MB/s decompress (memory bandwidth limited)
```

### A-11: lz4 level 1 — zero corpus (ratio floor, max compression)

```bash
lz4 -b1 ${CORPUS_DIR}/zero.bin 2>&1 | tail -1
# Expected: ~15000 MB/s compress, ~6700 MB/s decompress, ratio ~255:1
```

### A-12: Full level sweep, all three corpora (summary table generation)

```bash
for CORPUS_NAME in text random zero; do
    CORPUS=${CORPUS_DIR}/${CORPUS_NAME}.bin
    echo "--- lz4 sweep: ${CORPUS_NAME} ---" | tee -a ${SESSION_DIR}/lz4_all_sweep.log
    lz4 -b1 -e9 ${CORPUS} 2>&1 | tee -a ${SESSION_DIR}/lz4_all_sweep.log
    echo ""
done
```

---

## Group B — zlib (pigz) Compression / Decompression (15 subtests)

pigz exposes zlib DEFLATE with multi-threaded compress and effectively single-threaded
decompress (DEFLATE stream is sequential). Uses `-k` (keep input) and `-c` (stdout).

### Throughput formula

```
throughput_MBps = corpus_size_MB / wall_seconds
```

Use `bash`'s built-in `$SECONDS` or `time`:

```bash
# Helper function
run_pigz_compress() {
    local CORPUS=$1 LEVEL=$2 THREADS=$3 LABEL=$4
    local START=$(date +%s%N)
    pigz -${LEVEL} -p${THREADS} -k -c ${CORPUS} > /dev/null
    local END=$(date +%s%N)
    local SIZE_MB=$(du -m ${CORPUS} | cut -f1)
    local ELAPSED_S=$(echo "scale=3; (${END} - ${START}) / 1000000000" | bc)
    local TPUT=$(echo "scale=1; ${SIZE_MB} / ${ELAPSED_S}" | bc)
    echo "[${LABEL}] ${TPUT} MB/s (${ELAPSED_S}s, level ${LEVEL}, ${THREADS}T)"
}
```

### B-1: zlib level 1, 1 thread, 512MB zero

```bash
run_pigz_compress ${CORPUS_DIR}/zero.bin 1 1 "B-1 zlib-l1-p1"
# DMR baseline: ~2160 MB/s
```

### B-2: zlib level 1, NPROC threads, 512MB zero

```bash
run_pigz_compress ${CORPUS_DIR}/zero.bin 1 ${NPROC} "B-2 zlib-l1-pNPROC"
# DMR baseline: ~3350 MB/s (NPROC=32)
```

### B-3: zlib level 6 (default), NPROC threads, 512MB zero

```bash
run_pigz_compress ${CORPUS_DIR}/zero.bin 6 ${NPROC} "B-3 zlib-l6-pNPROC"
# DMR baseline: ~3350 MB/s (zlib-ng AVX2 keeps throughput high at l6)
```

### B-4: zlib level 9, NPROC threads, 512MB zero

```bash
run_pigz_compress ${CORPUS_DIR}/zero.bin 9 ${NPROC} "B-4 zlib-l9-pNPROC"
# DMR baseline: ~3500 MB/s
```

### B-5: zlib level 1, 1 thread, text corpus (realistic ratio)

```bash
run_pigz_compress ${CORPUS_DIR}/text.bin 1 1 "B-5 zlib-l1-p1-text"
# Report ratio: pigz -l output on compressed file
pigz -1 -p1 -k -c ${CORPUS_DIR}/text.bin > /tmp/text_l1.gz
pigz -l /tmp/text_l1.gz
# Expected ratio: 2.0–2.5× on doc/man pages
```

### B-6: zlib level 6, NPROC threads, text corpus

```bash
run_pigz_compress ${CORPUS_DIR}/text.bin 6 ${NPROC} "B-6 zlib-l6-pNPROC-text"
```

### B-7: zlib level 9, NPROC threads, text corpus

```bash
run_pigz_compress ${CORPUS_DIR}/text.bin 9 ${NPROC} "B-7 zlib-l9-pNPROC-text"
```

### B-8 through B-10: Decompression — single and multi-thread

```bash
# Compress reference files first
pigz -1 -p1 -k -c ${CORPUS_DIR}/zero.bin > /tmp/zero_l1.gz
pigz -6 -p1 -k -c ${CORPUS_DIR}/text.bin > /tmp/text_l6.gz

# B-8: decompress zero corpus, 1 thread
run_pigz_decompress() {
    local GZ=$1 THREADS=$2 LABEL=$3
    local ORIG_MB=$(pigz -l ${GZ} | awk 'NR==2{print $2}' | awk '{printf "%.0f", $1/1048576}')
    local START=$(date +%s%N)
    pigz -d -p${THREADS} -k -c ${GZ} > /dev/null
    local END=$(date +%s%N)
    local ELAPSED_S=$(echo "scale=3; (${END} - ${START}) / 1000000000" | bc)
    local TPUT=$(echo "scale=1; ${ORIG_MB} / ${ELAPSED_S}" | bc)
    echo "[${LABEL}] ${TPUT} MB/s decompress (${ELAPSED_S}s, ${THREADS}T)"
}

run_pigz_decompress /tmp/zero_l1.gz 1 "B-8 decomp-zero-p1"
# DMR baseline: ~9300 MB/s (DEFLATE decomp is memory-bandwidth-limited)

run_pigz_decompress /tmp/zero_l1.gz ${NPROC} "B-9 decomp-zero-pNPROC"
# NOTE: pigz decompress is effectively single-threaded for DEFLATE streams

run_pigz_decompress /tmp/text_l6.gz 1 "B-10 decomp-text-p1"
```

### B-11 through B-15: Thread scaling (1, 2, 4, 8, NPROC)

```bash
CORPUS=${CORPUS_DIR}/zero.bin
for THREADS in 1 2 4 8 ${NPROC}; do
    TAG="B-$(( 10 + THREADS == 1 ? 1 : THREADS == 2 ? 2 : THREADS == 4 ? 3 : THREADS == 8 ? 4 : 5 ))"
    run_pigz_compress ${CORPUS} 1 ${THREADS} "${TAG} zlib-l1-p${THREADS}"
done
# Expected scaling: nearly linear 1 → 4T, diminishing 4 → NPROC
```

---

## Group C — zstd Compression / Decompression (18 subtests)

zstd has a built-in `-b` benchmark mode (same as lz4). Output includes compress MB/s,
decompress MB/s, and ratio in one line.

### C-1 through C-9: Level sweep on text corpus

```bash
CORPUS=${CORPUS_DIR}/text.bin
echo "=== zstd level 1-9 sweep, text corpus ===" | tee ${SESSION_DIR}/zstd_text_sweep.log
zstd -b1 -e9 ${CORPUS} 2>&1 | tee -a ${SESSION_DIR}/zstd_text_sweep.log
```

DMR measured baseline (text corpus, 7.5 MB):

| Level | Compress MB/s | Decompress MB/s | Ratio |
|---|---|---|---|
| 1 | 331 | 1322 | 2.93× |
| 2 | 261 | 1201 | 3.18× |
| 3 | 227 | 1249 | 3.40× |
| 4 | 207 | 1256 | 3.44× |
| 5 | 138 | 1177 | 3.56× |
| 6 | 95 | 1251 | 3.70× |
| 7 | 82 | 1287 | 3.77× |
| 8 | 63 | 1327 | 3.82× |
| 9 | 63 | 1332 | 3.85× |

### C-10 through C-12: Random and zero corpora at level 1, 3, 6

```bash
for CORPUS_NAME in random zero; do
    for LEVEL in 1 3 6; do
        CORPUS=${CORPUS_DIR}/${CORPUS_NAME}.bin
        echo "--- zstd level ${LEVEL} / ${CORPUS_NAME} ---"
        zstd -b${LEVEL} ${CORPUS} 2>&1 | tail -1
    done
done 2>&1 | tee ${SESSION_DIR}/zstd_corpora_sweep.log
```

### C-13: zstd with --threads (multi-threaded compress)

```bash
# zstd -T uses pthreads internally — level 3 is default, NPROC threads
{ time zstd -3 -T${NPROC} -k -c ${CORPUS_DIR}/zero.bin > /dev/null; } 2>&1
# Compare to single-thread -T1
{ time zstd -3 -T1     -k -c ${CORPUS_DIR}/zero.bin > /dev/null; } 2>&1
```

### C-14 through C-18: Decompress speed at multiple levels

```bash
# Compress reference files
zstd -1 -k -o /tmp/text_zstd_l1.zst   ${CORPUS_DIR}/text.bin 2>/dev/null
zstd -3 -k -o /tmp/text_zstd_l3.zst   ${CORPUS_DIR}/text.bin 2>/dev/null
zstd -6 -k -o /tmp/text_zstd_l6.zst   ${CORPUS_DIR}/text.bin 2>/dev/null
zstd -9 -k -o /tmp/text_zstd_l9.zst   ${CORPUS_DIR}/text.bin 2>/dev/null

# Decompress via bench mode (most accurate)
for FILE in /tmp/text_zstd_l1.zst /tmp/text_zstd_l3.zst /tmp/text_zstd_l6.zst /tmp/text_zstd_l9.zst; do
    echo -n "decomp ${FILE}: "
    zstd -d -b ${FILE} 2>&1 | tail -1
done
```

---

## Running a Single Subtest (example)

```bash
# lz4 level 1 — text corpus
SESSION_ID=${SESSION_ID:-dev}
mkdir -p ./results/${SESSION_ID}/bench/compression
CORPUS_DIR=/tmp/compression_bench
corpus=${CORPUS_DIR}/text.bin

# Optionally start EMON
CODEC=lz4 LEVEL=1 THREADS=1
perf stat -e cycles,instructions,LLC-load-misses --interval-print 2000 -x , \
  -o ./results/${SESSION_ID}/bench/compression/emon_lz4_l1_1t.csv \
  -- sleep 3600 &
EMON_PID=$!

# Run subtest
lz4 -b1 ${corpus} 2>&1 | tee ./results/${SESSION_ID}/bench/compression/lz4_l1_text.log

# Stop EMON
kill ${EMON_PID} 2>/dev/null; wait ${EMON_PID} 2>/dev/null
```

---

## Running the Full Sweep (all groups)

```bash
SESSION_ID=${SESSION_ID:-$(date +%Y%m%dT%H%M%S)}
CORPUS_DIR=/tmp/compression_bench
OUT=${SESSION_DIR:-./results/${SESSION_ID}/bench/compression}
mkdir -p ${OUT}

# 1. Corpus generation (~10s)
dd if=/dev/urandom bs=1M count=512 of=${CORPUS_DIR}/random.bin 2>/dev/null &
dd if=/dev/zero   bs=1M count=512 of=${CORPUS_DIR}/zero.bin   2>/dev/null &
find /usr/share/doc /usr/share/man -type f 2>/dev/null | xargs cat 2>/dev/null \
  | head -c 67108864 > ${CORPUS_DIR}/text.bin
wait

# 2. Group A — lz4
echo "--- Group A: lz4 sweep ---" | tee ${OUT}/group_A_lz4.log
for LEVEL in 1 2 3 4 5 6 7 8 9; do
    echo -n "A-${LEVEL} lz4 l${LEVEL} text: "
    lz4 -b${LEVEL} ${CORPUS_DIR}/text.bin 2>&1 | grep "#"
done | tee -a ${OUT}/group_A_lz4.log

lz4 -b1 ${CORPUS_DIR}/random.bin 2>&1 | tail -1 | tee -a ${OUT}/group_A_lz4.log
lz4 -b1 ${CORPUS_DIR}/zero.bin   2>&1 | tail -1 | tee -a ${OUT}/group_A_lz4.log
lz4 -b1 -e9 ${CORPUS_DIR}/text.bin 2>&1 | tee -a ${OUT}/group_A_lz4.log

# 3. Group B — pigz/zlib (selected subtests, full thread sweep)
echo "--- Group B: pigz/zlib sweep ---" | tee ${OUT}/group_B_pigz.log
for THREADS in 1 2 4 8 ${NPROC}; do
    START=$(date +%s%N)
    pigz -1 -p${THREADS} -k -c ${CORPUS_DIR}/zero.bin > /dev/null
    END=$(date +%s%N)
    ELAPSED=$(echo "scale=3; (${END} - ${START}) / 1000000000" | bc)
    TPUT=$(echo "scale=1; 512 / ${ELAPSED}" | bc)
    echo "zlib l1 p${THREADS}: ${TPUT} MB/s"
done | tee -a ${OUT}/group_B_pigz.log

for LEVEL in 1 6 9; do
    START=$(date +%s%N)
    pigz -${LEVEL} -p${NPROC} -k -c ${CORPUS_DIR}/zero.bin > /dev/null
    END=$(date +%s%N)
    ELAPSED=$(echo "scale=3; (${END} - ${START}) / 1000000000" | bc)
    TPUT=$(echo "scale=1; 512 / ${ELAPSED}" | bc)
    echo "zlib l${LEVEL} pNPROC: ${TPUT} MB/s"
done | tee -a ${OUT}/group_B_pigz.log

# 4. Group C — zstd
echo "--- Group C: zstd sweep ---" | tee ${OUT}/group_C_zstd.log
zstd -b1 -e9 ${CORPUS_DIR}/text.bin 2>&1 | tee -a ${OUT}/group_C_zstd.log
zstd -3 -T${NPROC} -k -c ${CORPUS_DIR}/zero.bin > /dev/null 2>&1
echo "zstd l3 T${NPROC}: $({ time zstd -3 -T${NPROC} -k -c ${CORPUS_DIR}/zero.bin > /dev/null; } 2>&1 | grep real)"
```

---

## Parsing Results

### lz4 built-in bench output

```bash
# Parse lz4 -b output: "level#file : orig -> compressed (ratio), C MB/s, D MB/s"
grep "#" ${OUT}/group_A_lz4.log | while read LINE; do
    LEVEL=$(echo $LINE | grep -oP '^\s*\K[0-9]+')
    COMPRESS=$(echo $LINE | grep -oP ',\s*\K[0-9.]+(?= MB/s\s*,)')
    DECOMP=$(echo $LINE | grep -oP ',\s*[0-9.]+\s*MB/s\s*,\s*\K[0-9.]+(?= MB/s)')
    RATIO=$(echo $LINE | grep -oP '\(\K[0-9.]+(?=\))')
    echo "L${LEVEL}: compress=${COMPRESS} MB/s  decompress=${DECOMP} MB/s  ratio=${RATIO}"
done
```

### zstd built-in bench output

```bash
# Parse zstd -b output: "level#file : orig -> compressed (xRatio), C MB/s, D MB/s"
grep "#" ${OUT}/group_C_zstd.log | while read LINE; do
    LEVEL=$(echo $LINE | grep -oP '^\s*\K[0-9]+')
    COMPRESS=$(echo $LINE | grep -oP ',\s*\K[0-9.]+(?= MB/s,)')
    DECOMP=$(echo $LINE | grep -oP ',\s*[0-9.]+\s*MB/s,\s*\K[0-9.]+(?= MB/s)')
    RATIO=$(echo $LINE | grep -oP 'x\K[0-9.]+(?=\))')
    echo "L${LEVEL}: compress=${COMPRESS} MB/s  decompress=${DECOMP} MB/s  ratio=${RATIO}x"
done
```

### pigz throughput from timing

```bash
# Timings are calculated inline in the full-sweep script above.
# To post-process from log:
grep "MB/s" ${OUT}/group_B_pigz.log
```

---

## DMR Baseline Values (measured on 1S×32C DMR, kernel 6.18.0-dmr.bkc)

### lz4 — text corpus (doc/man pages, 7.9 MB, ~2× compressible)

| Level | Compress MB/s | Decompress MB/s | Ratio |
|---|---|---|---|
| 1 | 408 | 3609 | 1.99× |
| 2 | 408 | 3611 | 1.99× |
| 3 | 88 | 3402 | 2.65× |
| 4 | 70 | 3459 | 2.72× |
| 5 | 55 | 3475 | 2.76× |
| 6 | 43 | 3494 | 2.78× |
| 7 | 36 | 3515 | 2.79× |
| 8 | 31 | 3504 | 2.79× |
| 9 | 28 | 3531 | 2.80× |

### lz4 — extreme corpora (512 MB, level 1)

| Corpus | Compress MB/s | Decompress MB/s | Ratio |
|---|---|---|---|
| Random (incompressible) | ~19,000–21,000 | ~21,000 | 1.0× |
| Zero (maximally compressible) | ~15,600 | ~6,700 | 255× |

### pigz (zlib-ng) — 512MB zero corpus

| Level | Threads | Compress MB/s |
|---|---|---|
| 1 | 1 | ~2,160 |
| 1 | 32 | ~3,350 |
| 6 | 32 | ~3,350 |
| 9 | 32 | ~3,500 |

**Decompress (DEFLATE, single-threaded regardless of `-p`):**

| Threads | Decompress MB/s |
|---|---|
| 1 | ~9,300 |
| 32 | ~1,100 (actually serialised — no benefit) |

> **Note:** `pigz -d` spawns extra threads that still funnel through the single DEFLATE stream.
> Multi-thread decompress shows NO speedup; this is expected DEFLATE behaviour.

### zstd — text corpus (7.9 MB)

| Level | Compress MB/s | Decompress MB/s | Ratio |
|---|---|---|---|
| 1 | 331 | 1322 | 2.93× |
| 3 | 227 | 1249 | 3.40× |
| 6 | 95 | 1251 | 3.70× |
| 9 | 63 | 1332 | 3.85× |

---

## Pass Thresholds

| Codec | Metric | Threshold | Basis |
|---|---|---|---|
| lz4 l1 | Compress MB/s (text) | ≥ 300 | 75% of DMR measured 408 MB/s |
| lz4 l1 | Decompress MB/s (text) | ≥ 2,500 | 75% of 3,600 MB/s |
| lz4 l1 | Compress MB/s (random) | ≥ 10,000 | Real-world transport codecs |
| zlib l1 p1 | Compress MB/s | ≥ 1,500 | 70% of DMR 2,160 MB/s |
| zlib l1 pNPROC | Compress MB/s | ≥ 2,500 | 70% of 3,350 MB/s |
| zlib decomp p1 | Decompress MB/s | ≥ 6,000 | 65% of 9,300 MB/s |
| zstd l3 | Compress MB/s | ≥ 150 | 65% of 227 MB/s |
| zstd l3 | Decompress MB/s | ≥ 800 | 65% of 1,249 MB/s |
| zstd l1 | Ratio | ≥ 2.5× (text corpus) | Min useful storage ratio |

---

## Report Format

```
COMPRESSION TEST 105 — RESULTS
===============================
Platform   : <CPU model> <N>C  kernel <K>
Session    : <SESSION_ID>
Corpus dir : <CORPUS_DIR>

CODEC RESULTS
-------------
Group A — lz4
  A-1  lz4 l1  text     : <C> MB/s compress  <D> MB/s decompress  ratio <R>x  [PASS/FAIL]
  A-10 lz4 l1  random   : <C> MB/s compress  <D> MB/s decompress
  A-11 lz4 l1  zero     : <C> MB/s compress  <D> MB/s decompress  ratio 255x

Group B — pigz (zlib)
  B-1  zlib l1 p1        : <C> MB/s compress                             [PASS/FAIL]
  B-2  zlib l1 pNPROC    : <C> MB/s compress                             [PASS/FAIL]
  B-8  decomp p1         : <D> MB/s decompress                           [PASS/FAIL]

Group C — zstd
  C-3  zstd l3 text      : <C> MB/s compress  <D> MB/s decompress  ratio <R>x  [PASS/FAIL]
  C-1  zstd l1 text      : <C> MB/s compress  <D> MB/s decompress  <R>x ratio

EMON SIGNALS (if collected)
----------------------------
  IPC (compress phase)    : <value>   (expected: 0.8–1.2)
  IPC (decompress phase)  : <value>   (expected: 1.5–2.5)
  LLC miss %              : <value>%  (elevated if >10%)
  AVX-512 ops             : <count>   (confirms zlib-ng/zstd vectorisation)
  CPU migrations          : <count>   (expected: near zero)

SCORECARD
---------
SUBTEST          MEASURED    THRESHOLD   STATUS
────────────────────────────────────────────────
lz4 l1 compress  <C> MB/s   ≥300 MB/s   ✅ / ❌
lz4 l1 decomp    <D> MB/s   ≥2500 MB/s  ✅ / ❌
zlib l1 p1 comp  <C> MB/s   ≥1500 MB/s  ✅ / ❌
zlib l1 pN comp  <C> MB/s   ≥2500 MB/s  ✅ / ❌
zlib decomp p1   <D> MB/s   ≥6000 MB/s  ✅ / ❌
zstd l3 comp     <C> MB/s   ≥150 MB/s   ✅ / ❌
zstd l3 decomp   <D> MB/s   ≥800 MB/s   ✅ / ❌
────────────────────────────────────────────────
VERDICT: PASS / FAIL — <summary>
```

---

## Platform Notes (DMR)

- **zlib-ng:** Installed as `python3` `zlib` v1.3.1.zlib-ng — uses AVX2/SSE4.2. The `pigz` binary
  links system `libz.so.1` which may NOT be zlib-ng. Verify with `ldd $(which pigz) | grep libz`.
  If `libz.so.1 → /usr/lib64/libz.so.1`, check `rpm -qi zlib` — on CentOS 10 this is zlib-ng 1.3.1.

- **lz4:** Runs entirely in L3 when corpus ≤ 45 MB. For transport-scale throughput (random corpus)
  the bottleneck is memory bandwidth (~96 GB/s DRAM read BW), not CPU decode speed.

- **pigz decompress bottleneck:** DEFLATE back-reference chains are inherently sequential — adding
  threads does NOT accelerate decompress. Observed 9,300 MB/s on p1 is zlib-ng scalar INFLATE speed
  (single-core throughput capped by branch predictor, not memory).

- **zstd vs lz4 trade-off:** zstd l3 achieves 3.4× ratio vs lz4 l1's 2.0× ratio on text, at the
  cost of ~45% lower compress speed. For storage applications: use lz4 for hot-tier (latency), zstd
  for warm/cold-tier (space).

- **CPU utilisation:** lz4 and zlib decompress are single-core operations. Use `taskset -c 0` for
  reproducible results on NUMA-1-node systems like DMR.

- **Corpus sensitivity:** lz4/zstd built-in `-b` benchmarks use an in-memory loop (no I/O).
  pigz benchmarks via `time` include one pass of file I/O through the Linux page cache — results
  may appear faster than expected because the corpus is cached after the first run.
  Add `echo 3 > /proc/sys/vm/drop_caches && sync` before each pigz run for cold-cache results.
