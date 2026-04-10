---
name: storage-erasure-coding
description: "Erasure coding throughput benchmark for Test 106. Use when: measuring Reed-Solomon encode throughput, RS decode bandwidth, erasure coding performance, ISA-L erasure code benchmark, GF-256 parity computation, object storage EC validation, Ceph/HDFS/MinIO erasure coding sizing, distributed storage parity benchmark, 10+4 erasure coding, Reed-Solomon AVX-512 performance."
argument-hint: "[encode|decode|all] [-k <data_shards>] [-p <parity_shards>] [-s <buffer_size>]"
allowed-tools: Bash
---

# Storage Erasure Coding — Test 106

Measures Reed-Solomon erasure coding throughput (MB/s) using Intel ISA-L
(`erasure_code_perf`) — the CPU-native GF-256 AVX-512 implementation that underpins
Ceph, HDFS, and MinIO object store EC paths.

**Primary subtests (Test 106 spec):**

| Subtest | Config | Metric |
|---|---|---|
| RS 10+4 encode | k=10, p=4, 1 MB/shard | Bandwidth MB/s |
| RS 10+4 decode | k=10, p=4, up to 4 shard errors | Bandwidth MB/s |

Extended subtests cover RS 4+2, 8+3, 12+4 and buffer-size sweeps.

---

## Variables

```bash
NPROC=$(nproc --all)
ISA_L_DIR=/root/isa-l
EC_PERF=${ISA_L_DIR}/erasure_code/erasure_code_perf
SESSION_DIR=./results/${SESSION_ID}/bench/erasure-coding

BENCHMARK_TIME=3   # seconds per run (hardcoded in binary — BENCHMARK_TIME define)
```

---

## Prerequisites

### Build ISA-L from source

ISA-L is not available via `dnf` as a standalone benchmark tool. Build from source once
per machine. The library is installed system-wide; the `erasure_code_perf` binary stays
in the source tree.

```bash
# 1. Install build dependencies
dnf install -y autoconf automake libtool nasm yasm git
# Ubuntu/Debian equivalent:
# apt-get install -y autoconf automake libtool nasm yasm git

# 2. Clone ISA-L
cd /root
git clone --depth=1 https://github.com/intel/isa-l.git
cd isa-l

# 3. Build
./autogen.sh
./configure --prefix=/usr/local
make -j$(nproc)

# 4. Install library (needed for any programs that link against libisal)
make install
ldconfig

# 5. Build the perf benchmarks (not built by default install)
make erasure_code/erasure_code_perf \
     erasure_code/erasure_code_base_perf \
     erasure_code/gf_vect_mul_perf

# 6. Verify
${ISA_L_DIR}/erasure_code/erasure_code_perf -k 4 -p 2 -e 1 -s 1M 2>&1 | tail -4
# Expected output: encode_warm ... MB/s, decode_warm ... MB/s, done all: Pass
```

### Verify AVX-512 support

```bash
grep -c "avx512" /proc/cpuinfo | head -1
# Expected: non-zero — ISA-L auto-selects the best ISA at runtime via ec_multibinary
lscpu | grep -i "avx512"
# Expected on DMR: avx512f avx512bw avx512vl avx512dq gfni
```

ISA-L's `ec_multibinary` dispatcher selects the best path at runtime:
`AVX-512 GFNI` > `AVX-512` > `AVX2` > `AVX` > `SSE` > scalar.
On DMR with GFNI support, the GFNI path is used — fastest possible.

---

## Group A — RS 10+4 (Primary Test 106 Subtests, 6 subtests)

The canonical erasure coding configuration used in Ceph RADOS and HDFS.
- k=10 data shards, p=4 parity shards → tolerates any 4 simultaneous shard failures.
- `erasure_code_perf` always runs both encode and decode in one invocation.
- `-e` sets the number of simulated erasures for the decode phase (must be ≥ 1).

### A-1: RS 10+4 encode + decode, 1 error, 1 MB/shard (standard subtest)

```bash
mkdir -p ${SESSION_DIR}
timeout 15 ${EC_PERF} -k 10 -p 4 -e 1 -s 1M 2>&1 | tee ${SESSION_DIR}/rs10p4_e1_1M.log
```

Expected output (DMR measured):
```
Testing with 10 data buffers and 4 parity buffers (num errors = 1, in [ 4 ])
erasure_code_perf: 14x1048576 1
erasure_code_encode_warm: runtime = 3000830 usecs, bandwidth 106826 MB in 3.0s = 35599 MB/s
erasure_code_decode_warm: runtime = 3062647 usecs, bandwidth 158008 MB in 3.1s  = 51592 MB/s
done all: Pass
```

### A-2: RS 10+4, 4 errors (maximum parity — hardest decode)

```bash
timeout 15 ${EC_PERF} -k 10 -p 4 -e 4 -s 1M 2>&1 | tee ${SESSION_DIR}/rs10p4_e4_1M.log
```

DMR measured: encode ~37,406 MB/s | decode ~37,439 MB/s

### A-3: RS 10+4, 1 error, 128 KB/shard (small-shard / HDD-tier EC)

```bash
timeout 15 ${EC_PERF} -k 10 -p 4 -e 1 -s 128K 2>&1 | tee ${SESSION_DIR}/rs10p4_e1_128K.log
```

### A-4: RS 10+4, 1 error, 4 MB/shard (large-object / NVMe-tier EC)

```bash
timeout 15 ${EC_PERF} -k 10 -p 4 -e 1 -s 4M 2>&1 | tee ${SESSION_DIR}/rs10p4_e1_4M.log
```

DMR measured (4 MB): encode ~33,371 MB/s | decode ~51,843 MB/s

### A-5: RS 10+4 — encode-only throughput (no recovery path)

The binary always runs decode with `-e ≥ 1`. To isolate encode, use `-e 1` and read
only the `encode_warm` line.

```bash
timeout 15 ${EC_PERF} -k 10 -p 4 -e 1 -s 1M 2>&1 | grep "encode_warm"
```

### A-6: RS 10+4 base (scalar/SSE fallback — regression check)

```bash
timeout 15 ${ISA_L_DIR}/erasure_code/erasure_code_base_perf 2>&1 | tee ${SESSION_DIR}/rs_base_perf.log
# erasure_code_base_perf uses the C scalar path, no AVX.
# If this is significantly faster than AVX variant, CPUID dispatch is broken.
```

---

## Group B — RS Config Sweep (8 subtests)

Tests additional Reed-Solomon configurations used in production object stores.

| Config | Use case |
|---|---|
| 4+2 | Small cluster (Ceph default for < 5 OSD) |
| 8+3 | Balanced throughput / overhead |
| 10+4 | Standard Ceph pool / HDFS default |
| 12+4 | High-density NVMe nodes |

### B-1 through B-4: Encode + decode, 1 error, 1 MB/shard

```bash
for CONFIG in "4 2" "8 3" "10 4" "12 4"; do
    K=$(echo $CONFIG | cut -d' ' -f1)
    P=$(echo $CONFIG | cut -d' ' -f2)
    LABEL="rs${K}p${P}"
    echo "--- ${LABEL} ---"
    timeout 15 ${EC_PERF} -k ${K} -p ${P} -e 1 -s 1M 2>&1 \
        | tee ${SESSION_DIR}/${LABEL}_e1_1M.log \
        | grep -E "encode_warm|decode_warm|Pass|Fail"
    echo ""
done
```

DMR measured baselines:

| Config | Encode MB/s | Decode MB/s |
|---|---|---|
| RS 4+2 | 55,437 | 64,009 |
| RS 8+3 | 42,491 | 50,990 |
| RS 10+4 | 35,599 | 51,592 |
| RS 12+4 | 34,434 | 50,510 |

### B-5 through B-8: Maximum parity errors per config

```bash
for CONFIG in "4 2 2" "8 3 3" "10 4 4" "12 4 4"; do
    K=$(echo $CONFIG | awk '{print $1}')
    P=$(echo $CONFIG | awk '{print $2}')
    E=$(echo $CONFIG | awk '{print $3}')
    LABEL="rs${K}p${P}_emax"
    echo "--- ${LABEL} (e=${E}) ---"
    timeout 15 ${EC_PERF} -k ${K} -p ${P} -e ${E} -s 1M 2>&1 \
        | tee ${SESSION_DIR}/${LABEL}_1M.log \
        | grep -E "encode_warm|decode_warm|Pass|Fail"
    echo ""
done
```

---

## Group C — Buffer Size Sweep for RS 10+4 (6 subtests)

Varies shard size from 64K to 16M to characterise cache effects on EC throughput.

```bash
SESSION_DIR=${SESSION_DIR:-./results/${SESSION_ID}/bench/erasure-coding}
mkdir -p ${SESSION_DIR}

echo "RS 10+4 buffer-size sweep" | tee ${SESSION_DIR}/rs10p4_buffer_sweep.log
echo "SIZE       ENCODE_MB/s   DECODE_MB/s" | tee -a ${SESSION_DIR}/rs10p4_buffer_sweep.log

for SIZE in 64K 256K 1M 4M 8M 16M; do
    LINE=$(timeout 15 ${EC_PERF} -k 10 -p 4 -e 1 -s ${SIZE} 2>&1 \
           | awk '/encode_warm/{e=$NF} /decode_warm/{d=$NF} END{printf "%-10s %-13s %s\n","'"${SIZE}"'",e,d}')
    echo "${LINE}" | tee -a ${SESSION_DIR}/rs10p4_buffer_sweep.log
done
```

Expected trend: throughput drops ~5–15% as shard size grows beyond LLC (45 MB total on DMR
means 10×4MB=40MB approaches LLC capacity — small cache effect visible at 4M+).

---

## Group D — GF Arithmetic Micro-benchmark (1 subtest)

Validates the Galois Field multiply primitive speed. This is the inner loop of all
Reed-Solomon operations. Deviation from baseline indicates ISA dispatch failure.

### D-1: GF vector multiply throughput

```bash
timeout 15 ${ISA_L_DIR}/erasure_code/gf_vect_mul_perf 2>&1 | tee ${SESSION_DIR}/gf_vect_mul.log
```

DMR measured:
```
gf_vect_mul_warm: runtime = 3000474 usecs, bandwidth 79730 MB in 3.0s = 26573 MB/s
```

If this is < 10,000 MB/s → AVX-512 GFNI not active; check `grep gfni /proc/cpuinfo`.

---

## Running a Single Subtest (quick validation)

```bash
# One-liner — RS 10+4 primary encode+decode, no session tracking
cd /root/isa-l
timeout 15 erasure_code/erasure_code_perf -k 10 -p 4 -e 1 -s 1M 2>&1

# With EMON collection (perf stat wrapper)
EMON_EVENTS="cycles,instructions,cache-misses,LLC-load-misses,cpu-migrations"
perf stat -e ${EMON_EVENTS} --interval-print 2000 -x , \
    -o /tmp/ec_emon.csv -- sleep 3600 &
EMON_PID=$!

timeout 15 erasure_code/erasure_code_perf -k 10 -p 4 -e 1 -s 1M 2>&1

kill ${EMON_PID} 2>/dev/null; wait ${EMON_PID} 2>/dev/null
```

---

## Running the Full Sweep

```bash
SESSION_ID=${SESSION_ID:-$(date +%Y%m%dT%H%M%S)}
EC_PERF=/root/isa-l/erasure_code/erasure_code_perf
OUT=./results/${SESSION_ID}/bench/erasure-coding
mkdir -p ${OUT}

echo "=== Group A: RS 10+4 primary ===" | tee ${OUT}/summary.log

for E in 1 4; do
    for SIZE in 1M 4M; do
        timeout 15 ${EC_PERF} -k 10 -p 4 -e ${E} -s ${SIZE} 2>&1 \
            | tee ${OUT}/rs10p4_e${E}_${SIZE}.log \
            | grep -E "encode_warm|decode_warm|Pass|Fail" \
            | sed "s/^/[10+4 e=${E} ${SIZE}] /"
    done
done | tee -a ${OUT}/summary.log

echo "" | tee -a ${OUT}/summary.log
echo "=== Group B: Config sweep ===" | tee -a ${OUT}/summary.log

for CONFIG in "4 2" "8 3" "10 4" "12 4"; do
    K=$(echo $CONFIG | awk '{print $1}')
    P=$(echo $CONFIG | awk '{print $2}')
    timeout 15 ${EC_PERF} -k ${K} -p ${P} -e 1 -s 1M 2>&1 \
        | tee ${OUT}/rs${K}p${P}_e1_1M.log \
        | grep -E "encode_warm|decode_warm" \
        | sed "s/^/[${K}+${P}] /"
done | tee -a ${OUT}/summary.log

echo "" | tee -a ${OUT}/summary.log
echo "=== Group C: Buffer size sweep ===" | tee -a ${OUT}/summary.log
echo "SIZE       ENCODE_MB/s   DECODE_MB/s" | tee -a ${OUT}/summary.log

for SIZE in 64K 256K 1M 4M 8M 16M; do
    LINE=$(timeout 15 ${EC_PERF} -k 10 -p 4 -e 1 -s ${SIZE} 2>&1 \
           | awk '/encode_warm/{e=$NF} /decode_warm/{d=$NF} END{printf "%-10s %-13s %s\n","'"${SIZE}"'",e,d}')
    echo "${LINE}" | tee -a ${OUT}/summary.log
done

echo "" | tee -a ${OUT}/summary.log
echo "=== Group D: GF multiply primitive ===" | tee -a ${OUT}/summary.log
timeout 15 /root/isa-l/erasure_code/gf_vect_mul_perf 2>&1 | tee ${OUT}/gf_vect_mul.log \
    | grep -E "warm|Pass|Fail"
```

---

## Parsing Results

### Extract encode and decode MB/s from a log file

```bash
parse_ec_log() {
    local LOG=$1
    local ENCODE=$(grep "encode_warm" ${LOG} | grep -oP '= \K[0-9.]+(?= MB/s)')
    local DECODE=$(grep "decode_warm" ${LOG} | grep -oP '= \K[0-9.]+(?= MB/s)')
    local PASS=$(grep -c "Pass" ${LOG})
    echo "encode=${ENCODE} MB/s  decode=${DECODE} MB/s  pass=${PASS}"
}

# Usage:
parse_ec_log ./results/${SESSION_ID}/bench/erasure-coding/rs10p4_e1_1M.log
```

### Batch parse all logs in a session

```bash
OUT=./results/${SESSION_ID}/bench/erasure-coding
echo "LOG                        ENCODE_MB/s   DECODE_MB/s   STATUS"
echo "──────────────────────────────────────────────────────────────"
for LOG in ${OUT}/*.log; do
    BASE=$(basename ${LOG} .log)
    ENCODE=$(grep "encode_warm" ${LOG} 2>/dev/null | grep -oP '= \K[0-9.]+(?= MB/s)' | tail -1)
    DECODE=$(grep "decode_warm" ${LOG} 2>/dev/null | grep -oP '= \K[0-9.]+(?= MB/s)' | tail -1)
    STATUS=$(grep -c "Pass" ${LOG} 2>/dev/null | awk '{print ($1>0)?"PASS":"FAIL"}')
    printf "%-26s %-13s %-13s %s\n" "${BASE}" "${ENCODE:-—}" "${DECODE:-—}" "${STATUS}"
done
```

---

## DMR Baseline Values (measured live on 1S×32C DMR, kernel 6.18.0-dmr.bkc)

ISA-L v2.x, AVX-512 GFNI dispatch, warm-cache (BENCHMARK_TIME=3s each).

### RS 10+4 — varying error count (1 MB/shard)

| Errors simulated | Encode MB/s | Decode MB/s | Status |
|---|---|---|---|
| e=1 (1 shard lost) | 35,599 | 51,592 | PASS |
| e=4 (all parity lost) | 37,406 | 37,439 | PASS |
| e=1, 4 MB/shard | 33,371 | 51,843 | PASS |

### RS config comparison (e=1, 1 MB/shard)

| Config | Encode MB/s | Decode MB/s |
|---|---|---|
| RS 4+2 | 55,437 | 64,009 |
| RS 8+3 | 42,491 | 50,990 |
| RS 10+4 | 35,599 | 51,592 |
| RS 12+4 | 34,434 | 50,510 |

> Encode throughput scales inversely with total shards (m = k + p): fewer shards = faster GF
> multiply loop. Decode is faster than encode when only 1 shard is recovered because only the
> missing shard's contribution is recomputed rather than all p parity shards.

### GF-256 multiply primitive

| Test | MB/s |
|---|---|
| gf_vect_mul_warm (AVX-512 GFNI) | 26,573 |

---

## Pass Thresholds

| Subtest | Metric | Threshold | Basis |
|---|---|---|---|
| RS 10+4 encode (e=1, 1M) | MB/s | ≥ 25,000 | 70% of DMR 35,599 MB/s |
| RS 10+4 decode (e=1, 1M) | MB/s | ≥ 36,000 | 70% of DMR 51,592 MB/s |
| RS 10+4 decode (e=4, 1M) | MB/s | ≥ 26,000 | 70% of DMR 37,439 MB/s |
| RS 4+2 encode (e=1, 1M) | MB/s | ≥ 38,000 | 70% of DMR 55,437 MB/s |
| GF vect mul | MB/s | ≥ 15,000 | 55% of AVX-512 GFNI baseline |
| All runs | done all | Pass | Binary self-verification |

---

## EMON Collection — Erasure Coding PMU Events

```bash
EMON_EVENTS="cycles,instructions,cache-misses,LLC-load-misses,\
cpu-migrations,fp_arith_inst_retired.512b_packed_single,\
mem_load_retired.l3_miss"

perf stat -e ${EMON_EVENTS} --interval-print 2000 -x , \
    -o ${SESSION_DIR}/emon_rs10p4.csv -- sleep 3600 &
EMON_PID=$!

timeout 15 ${EC_PERF} -k 10 -p 4 -e 1 -s 1M 2>&1 | tee ${SESSION_DIR}/rs10p4_emon_run.log

kill ${EMON_PID} 2>/dev/null; wait ${EMON_PID} 2>/dev/null
```

| Counter | Expected (DMR EC) | FAIL indicator |
|---|---|---|
| IPC | 1.5 – 2.5 (tight GF loop) | < 1.0 (dispatch not vectorised) |
| LLC miss % | < 5% (warm-cache test; 14×1MB = 14MB < 45MB L3) | > 20% (working set spilled) |
| `fp_arith_inst_retired.512b_packed_single` | > 0 (AVX-512 GFNI active) | = 0 (scalar fallback) |
| `cpu-migrations` | near 0 | > 10 (OS noise, use `taskset -c 0`) |

---

## Report Format

```
ERASURE CODING TEST 106 — RESULTS
===================================
Platform : <CPU model> <N>C  kernel <K>
ISA-L    : <version from git describe or ls isa-l/Release_notes.txt>
ISA path : AVX-512 GFNI (confirmed via fp_arith_inst_retired > 0)
Session  : <SESSION_ID>

PRIMARY SUBTESTS
----------------
RS 10+4 encode (e=1, 1MB) : <C> MB/s   [PASS / FAIL]
RS 10+4 decode (e=1, 1MB) : <D> MB/s   [PASS / FAIL]
RS 10+4 decode (e=4, 1MB) : <D> MB/s   [PASS / FAIL]

CONFIG SWEEP (e=1, 1MB/shard)
------------------------------
RS 4+2  encode: <C> MB/s  decode: <D> MB/s
RS 8+3  encode: <C> MB/s  decode: <D> MB/s
RS 10+4 encode: <C> MB/s  decode: <D> MB/s
RS 12+4 encode: <C> MB/s  decode: <D> MB/s

GF PRIMITIVE
------------
gf_vect_mul_warm : <V> MB/s   [PASS / FAIL]

EMON SIGNALS (if collected)
----------------------------
IPC             : <value>   (expected: 1.5–2.5)
LLC miss %      : <value>%  (elevated if >10%; working set > L3)
AVX-512 ops     : <count>   (confirms GFNI path active)
CPU migrations  : <count>   (expected: near zero)

SCORECARD
---------
SUBTEST               MEASURED     THRESHOLD    STATUS
──────────────────────────────────────────────────────
RS 10+4 encode        <C> MB/s     ≥25000 MB/s  ✅ / ❌
RS 10+4 decode e=1    <D> MB/s     ≥36000 MB/s  ✅ / ❌
RS 10+4 decode e=4    <D> MB/s     ≥26000 MB/s  ✅ / ❌
GF vect mul           <V> MB/s     ≥15000 MB/s  ✅ / ❌
──────────────────────────────────────────────────────
VERDICT: PASS / FAIL — <summary>
```

---

## Platform Notes (DMR)

- **ISA dispatch:** ISA-L calls `ec_multibinary` at startup which CPUID-probes for
  `AVX-512 GFNI` first. On DMR this resolves to `gf_6vect_mad_avx512_gfni` (the fastest path).
  Running on an older system without GFNI will silently fall back to AVX-512 (no GFNI), then
  AVX2, etc. — throughput degrades ~30–50% at each tier.

- **Warm vs cold cache:** The builtin benchmark is warm-cache (loops over a small in-memory
  dataset). Use `-s 4M` to approach cache-spill territory: 10+4 = 14 shards × 4 MB = 56 MB
  > DMR L3 (45 MB). Expect ~5–10% encode throughput drop.

- **Encode vs decode asymmetry:** When only 1 shard is lost (e=1), decode only computes 1
  missing shard; encode always computes all p=4 parity shards. Decode is therefore faster
  for low error counts. With e=p=4, both encode and decode are similarly loaded.

- **Single-threaded baseline:** `erasure_code_perf` is single-threaded. Real object stores
  stripe EC across multiple threads / cores. The DMR 32-core node can sustain ~32×
  single-thread throughput in a fully parallelised EC path.

- **Binary self-test:** `done all: Pass` confirms bit-exact decode recovery. A `Fail` at
  any buffer size indicates a hardware or software correctness issue (not just perf).

- **ISA-L version on this system:**

```bash
cd /root/isa-l && git describe --tags 2>/dev/null || head -2 Release_notes.txt
```
