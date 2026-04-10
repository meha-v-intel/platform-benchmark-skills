---
name: storage-hashing
description: "Hashing throughput benchmark for Test 107. Use when: measuring SHA-256 throughput, SHA-512 throughput, SHA-NI CPU acceleration, CRC32C hardware checksum speed, xxHash throughput, xxh3 AVX-512 hashing, MurmurHash3 speed, MeowHash AESNI throughput, wyhash rapidhash throughput, SMHasher3 speed test, hash function benchmarking, NVMe CRC32C checksum, ZFS block checksum, dedup fingerprinting, object key hashing, storage checksum validation."
argument-hint: "[openssl|smhasher3|all] [--hash sha256|sha512|xxh3|crc32c|all] [--size <bytes>]"
allowed-tools: Bash
---

# Storage Hashing — Test 107

Measures hash function throughput (MB/s / GB/s) and small-key latency (cycles/hash)
across two tool sets:

- **OpenSSL speed** — SHA-256 and SHA-512 26-point buffer sweep (1 B → 1 GiB)
  Tests SHA-NI hardware acceleration, per-call overhead, and large-buffer throughput.
- **SMHasher3** — Speed test for CRC-32C, xxHash family, MurmurHash3, MeowHash,
  wyhash, rapidhash, SipHash, FNV, FarmHash, CityHash, MD5, SHA-1, SHA-2-256, and more.
  Measures both small-key cycles/hash and bulk bytes/cycle.

**Test 107 spec subtests:**

| Subtest group | Count | Tool | Status |
|---|---|---|---|
| SHA2-256 buffer sweep (1 B → 1 GiB) | 26 | OpenSSL speed | ✅ ELIGIBLE |
| SHA2-512 buffer sweep (1 B → 1 GiB) | 26 | OpenSSL speed | ✅ ELIGIBLE |
| CRC32C, MD5, SHA-1, SHA-2-*NI variants | ~60 | SMHasher3 | ✅ Built |
| xxHash32/64, xxh3-64/128 | ~12 | SMHasher3 | ✅ Built |
| Murmur, Farm, City, SipHash | ~25 | SMHasher3 | ✅ Built |
| FNV, MeowHash, wyhash, rapidhash | ~15 | SMHasher3 | ✅ Built |
| **Total** | **~164** | | |

---

## Variables

```bash
NPROC=$(nproc --all)
OPENSSL=$(which openssl)
SMHASHER=/root/smhasher3/build/SMHasher3
SESSION_DIR=./results/${SESSION_ID}/bench/hashing

# OpenSSL SHA sweep buffer sizes (26 points, same scale as AES-256-GCM sweep)
SHA_SIZES="1 2 4 8 16 32 64 128 256 512 1024 2048 4096 8192 16384 32768 65536
           131072 262144 524288 1048576 4194304 16777216 67108864 268435456 1073741824"
```

---

## Prerequisites

### OpenSSL (SHA subtests)

```bash
openssl version
# Expected: OpenSSL 3.5.x — SHA-NI hardware acceleration included

# Confirm SHA-NI CPU support
grep -c "sha_ni" /proc/cpuinfo
# Expected: non-zero (32 on DMR)

# If output is 0, SHA-256 and SHA-512 will run in software
# (~3–4× slower — document as "No SHA-NI" in report)
```

### SMHasher3 (all other hashes)

SMHasher3 must be built from source. It is not available via `dnf`.

```bash
# 1. Install build dependencies
dnf install -y cmake g++ git
# Ubuntu/Debian: apt-get install -y cmake g++ git

# 2. Clone
git clone --depth=1 https://gitlab.com/fwojcik/smhasher3.git /root/smhasher3

# 3. Build (C++11, ~5 min on 32 cores)
cd /root/smhasher3
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)

# 4. Verify
/root/smhasher3/build/SMHasher3 --list 2>&1 | wc -l
# Expected: ~336 hashes listed

# 5. Test binary
/root/smhasher3/build/SMHasher3 XXH3-64 --test=Speed --ncpu=1 2>&1 | grep "^Average"
# Expected: Average - ~14 cycles/hash (small keys)
```

**Binary location after build:** `/root/smhasher3/build/SMHasher3` (44 MB, statically linked)

```bash
mkdir -p ${SESSION_DIR}
```

---

## Group A — SHA-2 Buffer Sweep via OpenSSL (52 subtests)

Sweeps SHA-256 and SHA-512 across 26 buffer sizes from 1 B to 1 GiB.
Small sizes measure **per-call overhead** (cycles/hash); large sizes measure
**bulk throughput** (SHA-NI / AVX-512 pipeline saturation).

### A-1 through A-26: SHA-256 buffer sweep

```bash
mkdir -p ${SESSION_DIR}
echo "=== SHA-256 buffer sweep ===" | tee ${SESSION_DIR}/sha256_sweep.log

for SIZE in ${SHA_SIZES}; do
    RESULT=$(${OPENSSL} speed -evp sha256 -bytes ${SIZE} -seconds 3 -mr 2>&1 | grep "^+F:")
    BPS=$(echo "${RESULT}" | awk -F: '{print $4}')
    GBPS=$(python3 -c "print(f'{${BPS}/1e9:.3f}')")
    echo "  ${SIZE} bytes: ${BPS} B/s  = ${GBPS} GB/s" | tee -a ${SESSION_DIR}/sha256_sweep.log
done
```

### A-27 through A-52: SHA-512 buffer sweep

```bash
echo "=== SHA-512 buffer sweep ===" | tee ${SESSION_DIR}/sha512_sweep.log

for SIZE in ${SHA_SIZES}; do
    RESULT=$(${OPENSSL} speed -evp sha512 -bytes ${SIZE} -seconds 3 -mr 2>&1 | grep "^+F:")
    BPS=$(echo "${RESULT}" | awk -F: '{print $4}')
    GBPS=$(python3 -c "print(f'{${BPS}/1e9:.3f}')")
    echo "  ${SIZE} bytes: ${BPS} B/s  = ${GBPS} GB/s" | tee -a ${SESSION_DIR}/sha512_sweep.log
done
```

### Parse OpenSSL sweep output

```bash
# Peak throughput (largest buffer):
grep "1073741824" ${SESSION_DIR}/sha256_sweep.log
grep "1073741824" ${SESSION_DIR}/sha512_sweep.log

# Throughput at 4K (NVMe sector-equivalent):
grep "^  4096 " ${SESSION_DIR}/sha256_sweep.log
grep "^  4096 " ${SESSION_DIR}/sha512_sweep.log
```

---

## Group B — SMHasher3 Speed Tests: CRC + Cryptographic (14 subtests)

### B-1: CRC-32C (hardware-accelerated, Castagnoli polynomial)

```bash
timeout 60 ${SMHASHER} CRC-32C --test=Speed --ncpu=1 2>&1 \
    | tee ${SESSION_DIR}/CRC-32C.log \
    | grep -E "^Average|GiB/sec" | head -5
```

DMR baseline: **17.16 cycles/hash** (small keys) | **34.42 GiB/s** bulk

### B-2: MD5

```bash
timeout 60 ${SMHASHER} MD5 --test=Speed --ncpu=1 2>&1 \
    | tee ${SESSION_DIR}/MD5.log \
    | grep -E "^Average|GiB/sec" | head -5
```

DMR baseline: **149.41 cycles/hash** small | **1.55 GiB/s** bulk

### B-3: SHA-1

```bash
timeout 90 ${SMHASHER} SHA-1 --test=Speed --ncpu=1 2>&1 \
    | tee ${SESSION_DIR}/SHA-1.log \
    | grep "^Average"
# NOTE: SHA-1 bulk test runs >60s in SMHasher3; use OpenSSL for bulk throughput
# OpenSSL SHA-1 @ 1MB: ~1.724 GB/s (DMR)
```

DMR baseline: **114.62 cycles/hash** small (SMHasher3) | **1.724 GB/s** @ 1MB (OpenSSL)

```bash
# Faster SHA-1 bulk via OpenSSL:
openssl speed -evp sha1 -bytes 1048576 -seconds 3 -mr 2>&1 | grep "^+F:" \
    | awk -F: '{printf "SHA-1 1MB: %.3f GB/s\n", $4/1e9}'
```

### B-4: SHA-2-256 (SHA-NI hardware path)

```bash
timeout 90 ${SMHASHER} SHA-2-256 --test=Speed --ncpu=1 2>&1 \
    | tee ${SESSION_DIR}/SHA-2-256.log \
    | grep -E "^Average|GiB/sec" | head -5
```

DMR baseline: **159.11 cycles/hash** small | **5.38 GiB/s** bulk

> Note: SMHasher3 SHA-2-256 is single-block SHA loop; for per-buffer-size sweep
> use Group A (OpenSSL). Peak OpenSSL SHA-256 @ 1 GiB = **2.627 GB/s**.

### B-5 through B-8: SipHash variants

```bash
for HASH in SipHash-1-3 SipHash-2-4 SipHash-1-3.folded SipHash-2-4.folded; do
    echo "--- ${HASH} ---"
    timeout 60 ${SMHASHER} ${HASH} --test=Speed --ncpu=1 2>&1 \
        | tee ${SESSION_DIR}/${HASH}.log \
        | grep -E "^Average|GiB/sec" | head -3
done
```

DMR baseline (SipHash-2-4): **43.98 cycles/hash** small | **4.04 GiB/s** bulk

---

## Group C — SMHasher3 Speed Tests: xxHash Family (6 subtests)

```bash
for HASH in XXH-32 XXH-64 XXH3-64 XXH3-64.regen XXH3-128 XXH3-128.regen; do
    echo "--- ${HASH} ---"
    timeout 60 ${SMHASHER} ${HASH} --test=Speed --ncpu=1 2>&1 \
        | tee ${SESSION_DIR}/${HASH//\//_}.log \
        | grep -E "^Average|GiB/sec" | head -3
done
```

DMR measured baselines (all AVX-512 paths):

| Hash | Small (cyc/hash) | Bulk (GiB/s) | ISA |
|---|---|---|---|
| XXH-32 | 18.17 | 19.91 | scalar |
| XXH-64 | 24.06 | 41.15 | scalar |
| XXH3-64 | 14.43 | 134.86 | avx512 |
| XXH3-128 | 17.18 | 134.42 | avx512 |

---

## Group D — SMHasher3 Speed Tests: MurmurHash / FarmHash / CityHash (9 subtests)

```bash
for HASH in MurmurHash3-32 MurmurHash3-128 MurmurHash2-64 \
            FarmHash-32.NT FarmHash-64.NA FarmHash-64.TE \
            CityHash-32 CityHash-64 CityHashCrc-128.seed1; do
    echo "--- ${HASH} ---"
    timeout 60 ${SMHASHER} ${HASH} --test=Speed --ncpu=1 2>&1 \
        | tee ${SESSION_DIR}/${HASH//\//_}.log \
        | grep -E "^Average|GiB/sec" | head -3
done
```

DMR measured baselines:

| Hash | Small (cyc/hash) | Bulk (GiB/s) |
|---|---|---|
| MurmurHash3-32 | 19.08 | 7.28 |
| MurmurHash3-128 | 19.38 | 18.08 |

---

## Group E — SMHasher3 Speed Tests: Modern Fast Hashes (8 subtests)

AES-NI and AVX-accelerated "application" hash functions — used in key-value stores,
dedup fingerprinting, and in-memory hash tables.

```bash
for HASH in wyhash wyhash.strict rapidhash rapidhash-micro \
            MeowHash FNV-1a-64 FNV-1a-32 aesnihash-peterrk; do
    echo "--- ${HASH} ---"
    timeout 60 ${SMHASHER} ${HASH} --test=Speed --ncpu=1 2>&1 \
        | tee ${SESSION_DIR}/${HASH//\//_}.log \
        | grep -E "^Average|GiB/sec" | head -3
done
```

DMR measured baselines:

| Hash | Small (cyc/hash) | Bulk (GiB/s) | ISA |
|---|---|---|---|
| wyhash | 13.77 | 43.32 | scalar |
| rapidhash | 14.67 | 79.64 | scalar |
| MeowHash | 30.70 | 115.61 | aesni |
| FNV-1a-64 | 32.03 | 1.94 | scalar |

> **MeowHash** at 115.61 GiB/s bulk is the fastest non-AVX-512 hash on DMR.
> Its throughput is limited by AES round instruction throughput, not memory bandwidth.

---

## Running a Single Subtest (quick validation)

```bash
# OpenSSL SHA-256 at one buffer size
openssl speed -evp sha256 -bytes 65536 -seconds 3 -mr 2>&1 | grep "^+F:" \
    | awk -F: '{printf "SHA-256 64K: %.3f GB/s\n", $4/1e9}'

# SMHasher3 speed for one hash
timeout 60 /root/smhasher3/build/SMHasher3 XXH3-64 --test=Speed --ncpu=1 2>&1 \
    | grep -E "^Average|GiB/sec"
```

---

## Running the Full Sweep

```bash
SESSION_ID=${SESSION_ID:-$(date +%Y%m%dT%H%M%S)}
SMHASHER=/root/smhasher3/build/SMHasher3
OUT=./results/${SESSION_ID}/bench/hashing
mkdir -p ${OUT}

SHA_SIZES="1 2 4 8 16 32 64 128 256 512 1024 2048 4096 8192 16384 32768 65536
           131072 262144 524288 1048576 4194304 16777216 67108864 268435456 1073741824"

# Group A: SHA-256 sweep
echo "--- SHA-256 sweep ---" | tee ${OUT}/sha256_sweep.log
for SIZE in ${SHA_SIZES}; do
    R=$(openssl speed -evp sha256 -bytes ${SIZE} -seconds 3 -mr 2>&1 | grep "^+F:" | awk -F: '{print $4}')
    echo "  ${SIZE}: $(python3 -c "print(f'{${R}/1e9:.3f}')") GB/s" | tee -a ${OUT}/sha256_sweep.log
done

# Group A: SHA-512 sweep
echo "--- SHA-512 sweep ---" | tee ${OUT}/sha512_sweep.log
for SIZE in ${SHA_SIZES}; do
    R=$(openssl speed -evp sha512 -bytes ${SIZE} -seconds 3 -mr 2>&1 | grep "^+F:" | awk -F: '{print $4}')
    echo "  ${SIZE}: $(python3 -c "print(f'{${R}/1e9:.3f}')") GB/s" | tee -a ${OUT}/sha512_sweep.log
done

# Groups B-E: SMHasher3 speed tests
HASHES=(
    CRC-32C MD5 SHA-1 SHA-2-256 SipHash-2-4
    XXH-32 XXH-64 XXH3-64 XXH3-128
    MurmurHash3-32 MurmurHash3-128
    wyhash rapidhash MeowHash FNV-1a-64
)
echo "--- SMHasher3 speed tests ---"
for H in "${HASHES[@]}"; do
    echo -n "  ${H}: "
    timeout 90 ${SMHASHER} "${H}" --test=Speed --ncpu=1 > ${OUT}/${H//\//_}.log 2>&1
    SMALL=$(grep "^Average" ${OUT}/${H//\//_}.log | grep "cycles" | awk '{print $3}')
    BULK=$(grep "GiB/sec" ${OUT}/${H//\//_}.log | head -1 | awk '{print $4, $5, $7, $8}')
    echo "${SMALL} cyc/hash  ${BULK}"
done | tee ${OUT}/smhasher3_summary.log
```

---

## Parsing Results

### Parse OpenSSL sweep log

```bash
# Extract all 26 entries as CSV: size_bytes,GB/s
awk '{match($1,/[0-9]+/,a); match($NF,/[0-9.]+/,b); print a[0]","b[0]}' \
    ./results/${SESSION_ID}/bench/hashing/sha256_sweep.log
```

### Parse SMHasher3 log for one hash

```bash
parse_smhasher() {
    local LOG=$1
    local SMALL=$(grep "^Average" ${LOG} | grep "cycles" | awk '{print $3}')
    local BULK_BPCY=$(grep "GiB/sec" ${LOG} | head -1 | awk '{print $4}')
    local BULK_GIBS=$(grep "GiB/sec" ${LOG} | head -1 | awk '{print $7}')
    echo "small=${SMALL} cyc/hash  bulk=${BULK_BPCY} B/cyc = ${BULK_GIBS} GiB/s"
}

parse_smhasher ./results/${SESSION_ID}/bench/hashing/XXH3-64.log
```

### List all available hashes in SMHasher3

```bash
/root/smhasher3/build/SMHasher3 --list 2>&1 | wc -l   # total: ~336
/root/smhasher3/build/SMHasher3 --list 2>&1 | grep -i "avx512\|aesni\|hwcrc"
# Shows hardware-accelerated hashes: XXH3, MeowHash, CRC-32C, FarmHash-SU
```

---

## DMR Baseline Values (measured live, 1S×32C, kernel 6.18.0-dmr.bkc)

### SHA-256 buffer sweep (OpenSSL 3.5.1, SHA-NI active)

| Size | Throughput |
|---|---|
| 1 B | 0.007 GB/s |
| 64 B | 0.418 GB/s |
| 256 B | 1.108 GB/s |
| 1 KB | 1.883 GB/s |
| 4 KB | 2.238 GB/s |
| 64 KB | 2.378 GB/s |
| 1 MB | 2.376 GB/s |
| 64 MB | 2.609 GB/s |
| **1 GiB** | **2.627 GB/s** |

SHA-256 plateaus at ~2.38 GB/s above 64 KB (L3-resident). Slight increase at 64 MB+
due to hardware prefetch pipeline filling — genuine SHA-NI behavior.

### SHA-512 buffer sweep (OpenSSL 3.5.1, SHA-NI active)

| Size | Throughput |
|---|---|
| 64 B | 0.234 GB/s |
| 1 KB | 0.603 GB/s |
| 4 KB | 0.693 GB/s |
| 64 KB | 0.727 GB/s |
| **1 GiB** | **0.729 GB/s** |

SHA-512 plateau at ~0.729 GB/s — roughly 3.6× slower than SHA-256 at large buffers
(SHA-512 processes 128-byte blocks vs SHA-256's 64-byte blocks but with more rounds).

### SMHasher3 Speed Results (small-key avg + bulk @ alignment 7)

| Hash | Small (cyc/hash) | Bulk (GiB/s) | ISA | Category |
|---|---|---|---|---|
| wyhash | 13.77 | 43.32 | scalar | Fast non-crypto |
| XXH3-64 | 14.43 | 134.86 | avx512 | Fast non-crypto |
| XXH3-128 | 17.18 | 134.42 | avx512 | Fast non-crypto |
| rapidhash | 14.67 | 79.64 | scalar | Fast non-crypto |
| CRC-32C | 17.16 | 34.42 | hwcrc_x64 | Checksum |
| XXH-32 | 18.17 | 19.91 | scalar | Fast non-crypto |
| MurmurHash3-32 | 19.08 | 7.28 | scalar | Fast non-crypto |
| MurmurHash3-128 | 19.38 | 18.08 | scalar | Fast non-crypto |
| XXH-64 | 24.06 | 41.15 | scalar | Fast non-crypto |
| MeowHash | 30.70 | 115.61 | aesni | AES-based |
| FNV-1a-64 | 32.03 | 1.94 | scalar | Simple hash |
| SipHash-2-4 | 43.98 | 4.04 | ssse3 | Crypto-strength |
| SHA-1 | 114.62 | ~1.72¹ | x64 | Cryptographic |
| MD5 | 149.41 | 1.55 | scalar | Cryptographic |
| SHA-2-256 | 159.11 | 5.38 | x64 | Cryptographic |

¹ SHA-1 bulk from `openssl speed -evp sha1 -bytes 1048576`; SMHasher3 SHA-1 bulk test
  takes >90 s and was not completed.

> **Key insight:** XXH3-64/XXH3-128 at **134+ GiB/s** exceed DRAM bandwidth (DMR peak
> ~96 GB/s) because the benchmark is warm-cache (262 KB buffer fits in L2). Real storage
> workloads will be memory-bound at ~2–4× DRAM bandwidth = ~24–48 GB/s effective. CRC-32C
> at 34.4 GiB/s is the fastest practical checksum for NVMe-over-Fabrics workloads.

---

## Pass Thresholds

| Subtest | Metric | Threshold | Basis |
|---|---|---|---|
| SHA-256 @ 64 KB (bulk plateau) | GB/s | ≥ 1.8 | 75% of DMR 2.378 GB/s |
| SHA-256 @ 1 GiB | GB/s | ≥ 1.9 | 75% of DMR 2.627 GB/s |
| SHA-512 @ 64 KB | GB/s | ≥ 0.5 | 70% of DMR 0.727 GB/s |
| CRC-32C bulk | GiB/s | ≥ 20 | 58% of DMR 34.4 GiB/s |
| XXH3-64 bulk | GiB/s | ≥ 80 | 60% of DMR 134.9 GiB/s |
| XXH3-64 small-key | cyc/hash | ≤ 25 | 1.7× of DMR 14.43 |
| wyhash small-key | cyc/hash | ≤ 22 | 1.6× of DMR 13.77 |
| MeowHash bulk | GiB/s | ≥ 70 | 60% of DMR 115.6 GiB/s |

> **SHA-256 threshold rationale:** Any system with SHA-NI should exceed 1.8 GB/s.
> Below 0.5 GB/s indicates SHA-NI is not active (check `grep sha_ni /proc/cpuinfo`).

---

## EMON Collection — Hashing Workload PMU Events

```bash
EMON_EVENTS="cycles,instructions,cache-misses,LLC-load-misses,\
cpu-migrations,fp_arith_inst_retired.512b_packed_single,\
mem_load_retired.l3_miss"

perf stat -e ${EMON_EVENTS} --interval-print 2000 -x , \
    -o ${SESSION_DIR}/emon_sha256.csv -- sleep 3600 &
EMON_PID=$!

# Run SHA-256 sweep while EMON collects
for SIZE in 4096 65536 1048576; do
    openssl speed -evp sha256 -bytes ${SIZE} -seconds 3 -mr 2>&1 | grep "^+F:"
done

kill ${EMON_PID} 2>/dev/null; wait ${EMON_PID} 2>/dev/null
```

| Counter | Expected (SHA-256) | Expected (XXH3) | FAIL indicator |
|---|---|---|---|
| IPC | 1.5–2.5 (SHA-NI tight loop) | 2.0–3.5 (AVX-512) | < 1.0 (no HW accel) |
| LLC miss % | < 5% (buffer ≤ 45 MB L3) | < 5% | > 15% (buffer > L3) |
| `fp_arith_inst_retired.512b_packed_single` | 0 (SHA uses SHA-NI, not AVX-FP) | > 0 (XXH3 AVX-512) | — |
| `cpu-migrations` | near 0 | near 0 | > 10 |

---

## Report Format

```
HASHING TEST 107 — RESULTS
============================
Platform  : <CPU model> <N>C  kernel <K>
OpenSSL   : <version>   SHA-NI: <yes/no>
SMHasher3 : <version>   hashes: <N>
Session   : <SESSION_ID>

SHA-2 SWEEP RESULTS
-------------------
SHA-256 @ 4K   : <X> GB/s   [PASS / FAIL]
SHA-256 @ 64K  : <X> GB/s   (plateau)  [PASS / FAIL]
SHA-256 @ 1GiB : <X> GB/s   [PASS / FAIL]
SHA-512 @ 4K   : <X> GB/s
SHA-512 @ 64K  : <X> GB/s   (plateau)  [PASS / FAIL]

SMHASHER3 SPEED SUMMARY
------------------------
Hash               Small       Bulk        Status
XXH3-64            <X> cyc     <X> GiB/s   [PASS/FAIL]
CRC-32C            <X> cyc     <X> GiB/s   [PASS/FAIL]
MeowHash           <X> cyc     <X> GiB/s   [PASS/FAIL]
wyhash             <X> cyc                 [PASS/FAIL]
rapidhash          <X> cyc                 [PASS/FAIL]
MurmurHash3-128    <X> cyc     <X> GiB/s
SipHash-2-4        <X> cyc     <X> GiB/s
SHA-2-256          <X> cyc     <X> GiB/s
MD5                <X> cyc     <X> GiB/s

SCORECARD
---------
SUBTEST               MEASURED     THRESHOLD    STATUS
──────────────────────────────────────────────────────
SHA-256 @ 64K         <X> GB/s     ≥1.8 GB/s    ✅ / ❌
SHA-256 @ 1GiB        <X> GB/s     ≥1.9 GB/s    ✅ / ❌
SHA-512 @ 64K         <X> GB/s     ≥0.5 GB/s    ✅ / ❌
CRC-32C bulk          <X> GiB/s    ≥20 GiB/s    ✅ / ❌
XXH3-64 bulk          <X> GiB/s    ≥80 GiB/s    ✅ / ❌
XXH3-64 small         <X> cyc      ≤25 cyc      ✅ / ❌
MeowHash bulk         <X> GiB/s    ≥70 GiB/s    ✅ / ❌
──────────────────────────────────────────────────────
VERDICT: PASS / FAIL — <summary>
```

---

## Platform Notes (DMR)

- **SHA-NI:** Intel SHA Extensions (sha1msg*, sha256msg*, sha256rnds2 instructions) are
  active on DMR. OpenSSL 3.x auto-detects and uses them. Confirmed: `sha_ni` in
  `/proc/cpuinfo` on all 32 cores. SHA-256 peak ~2.6 GB/s, SHA-512 peak ~0.73 GB/s.

- **SHA-256 vs SHA-512 asymmetry:** SHA-NI only accelerates SHA-256 and SHA-224.
  SHA-512 uses a software path (wider 64-bit words, no SHA-NI equivalent). This explains
  the 3.6× throughput gap. Intel Sapphire Rapids / DMR do not have SHA-512 NI extensions.

- **XXH3 AVX-512:** SMHasher3 reports `avx512` ISA for XXH3-64/128. The 134 GiB/s bulk
  figure is warm-cache (262 KB loop). Real dedup fingerprinting workloads are memory-bound —
  expect 2–5 GB/s effective throughput on a SAN/object store workload.

- **MeowHash AESNI:** Uses 8×AES rounds per 256-byte block — not encryption quality, but
  exploits AES instruction throughput. At 115 GiB/s it outperforms XXH-64 by 2.8×.
  Used in applications where AES throughput is available and crypto quality is not required.

- **CRC-32C hardware (hwcrc_x64):** Uses `crc32q` instruction. Relevant for NVMe and
  iSCSI checksums. 17 cycles per small hash, 34 GiB/s bulk — well above PCIe Gen5 NVMe
  line rate (~14 GB/s for the Micron 7450 sequential write).

- **SMHasher3 bulk test duration:** The bulk speed test for cryptographic hashes
  (SHA-1, MD5, SHA-2-256) runs through 8 alignment variants × extended length tests and
  can take 2–4 minutes per hash. Use `timeout 120` or use `openssl speed -evp` for
  equivalent bulk throughput numbers in seconds.

- **SMHasher3 binary path:** `/root/smhasher3/build/SMHasher3` (44 MB, static).
  Total hashes available: 336 (`--list`). For a full hash quality + speed run use
  `SMHasher3 <hashname>` without `--test=Speed` to also run distribution/collision tests.
