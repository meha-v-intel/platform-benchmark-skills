---
name: storage-encryption
description: "Run AES-256-GCM encryption throughput sweep for storage segment validation Test 104. Use when: measuring AES-256-GCM throughput, benchmarking TLS termination capacity, measuring encryption overhead for NVMe-oF, NFS-over-TLS, S3/object storage, Ceph msgr2, measuring CPU crypto throughput across buffer sizes, validating AES-NI utilization, sizing encryption capacity for storage workloads."
argument-hint: "[single <bytes>|sweep|all]"
allowed-tools: Bash
---

# AES-256-GCM Encryption Throughput (Storage Test 104)

Measures `openssl speed -evp aes-256-gcm` throughput across **26 buffer sizes** (1B → 1GiB).
The buffer-size sweep reveals the transition from latency-bound (small buffer, per-call overhead)
to throughput-bound (large buffer, AES-NI pipeline limited) — critical for sizing TLS termination
capacity and modeling encryption cost in any storage data path.

> **Scope:** Software AES-NI only (26 subtests). QAT hardware offload subtests require Intel
> QAT hardware (❌ not present on this system) and are not covered here.

Argument: `$ARGUMENTS` — `single <bytes>` to test one size, `sweep` or `all` for all 26.

## Variables

| Variable | Description | Example |
|---|---|---|
| `$LAB_HOST` | SSH target alias from `~/.ssh/config` | `lab-target` |
| `$OUTPUT_DIR` | Remote results directory | `/data/benchmarks/2026-04-08/` |
| `$NPROC` | Core count (used for multi-threaded variant) | `32` |

## Prerequisites

```bash
openssl version   # expect OpenSSL 3.x
# Confirm AES-NI is present on the CPU
grep -m1 "flags" /proc/cpuinfo | grep -o "aes\|avx512\|vaes" | tr '\n' ' '
# Expected: aes avx512 vaes (DMR has all three)

OUT=${OUTPUT_DIR:-/tmp/aes256gcm_results}
mkdir -p $OUT
```

> **DMR confirmed:** OpenSSL 3.5.1, AES-NI + AVX-512 + VAES extensions present.
> All 26 subtests are single-threaded by default. For multi-threaded peak throughput,
> add `-multi $NPROC` (see Platform Notes).

---

## The 26 Buffer Sizes

These 26 sizes span the full working set range from per-byte overhead to DRAM pressure:

| Phase | Buffer sizes | What it reveals |
|---|---|---|
| Per-call overhead | 1B, 2B, 4B, 8B, 16B, 64B | Cost of GCM init/tag per op dominates — throughput scales ~linearly with size |
| Ramp-up | 256B, 1KiB | Pipeline filling — approaching AES-NI throughput ceiling |
| L1/L2 plateau | 8KiB, 16KiB, 32KiB | AES-NI limited (~9–11 GB/s), data fits in L1/L2 |
| L3 plateau (peak) | 64KiB, 128KiB, 256KiB, 512KiB, 1MiB, 2MiB | True peak (~11.9 GB/s), data warm in L3 |
| LLC resident | 4MiB, 8MiB, 16MiB, 32MiB | Still within L3, minor variance |
| DRAM pressure | 64MiB, 128MiB, 256MiB, 512MiB, 1GiB | Working set exceeds L3 — throughput drops ~14% |

---

## Running a Single Subtest

```bash
# Syntax: openssl speed -evp aes-256-gcm -bytes <N> -seconds <T> [-mr]
#   -bytes N   : buffer size in bytes
#   -seconds T : test duration (default 3 for the full sweep, 2 for quick)
#   -mr        : machine-readable output (parse with awk below)

# Human-readable example (65536B = 64KiB):
openssl speed -evp aes-256-gcm -bytes 65536 -seconds 3

# Machine-readable: parse throughput in GB/s
openssl speed -evp aes-256-gcm -bytes 65536 -seconds 3 -mr 2>&1 \
    | grep "^+F:" | awk -F: '{printf "%.2f GB/s\n", $4/1000000000}'
```

**Human-readable output format:**
```
Doing AES-256-GCM ops for 3s on 65536 size blocks: 353607 AES-256-GCM ops in 1.99s
The 'numbers' are in 1000s of bytes per second processed.
type          65536 bytes
AES-256-GCM   11645220.28k
```
The trailing `k` = kilobytes/sec. Value × 1000 = bytes/sec. Divide by 1e9 for GB/s.

**Machine-readable `+F:` line format:**
```
+F:<idx>:<algorithm>:<bytes_per_sec>
+F:25:AES-256-GCM:11650522440
```
`$4` = bytes/sec. Parse with `awk -F: '{printf "%.2f GB/s", $4/1000000000}'`.

---

## Running the Full 26-Subtest Sweep

```bash
OUT=${OUTPUT_DIR:-/tmp/aes256gcm_results}
mkdir -p $OUT
SWEEP_LOG=$OUT/aes256gcm_sweep.txt
> $SWEEP_LOG   # clear/create

echo "# AES-256-GCM buffer sweep — $(date) — $(openssl version)" | tee -a $SWEEP_LOG
echo "# bufsize_bytes  throughput_GBs" | tee -a $SWEEP_LOG

for bs in 1 2 4 8 16 64 256 1024 \
          8192 16384 32768 65536 131072 262144 \
          524288 1048576 2097576 4194304 8388608 16777216 33554432 \
          67108864 134217728 268435456 536870912 1073741824; do
    result=$(openssl speed -evp aes-256-gcm -bytes $bs -seconds 3 -mr 2>&1 \
             | grep "^+F:" | awk -F: '{printf "%.4f", $4/1000000000}')
    echo "$bs  $result" | tee -a $SWEEP_LOG
done

echo "Sweep complete. Results: $SWEEP_LOG"
```

**Total runtime:** ~26 × 3s = ~80 seconds (single-threaded).

---

## Parsing Results

```bash
SWEEP_LOG=${OUTPUT_DIR:-/tmp/aes256gcm_results}/aes256gcm_sweep.txt

# Print table with human-friendly size labels
awk 'NF==2 && $1+0>0 {
    bs=$1+0; tp=$2+0
    if      (bs >= 1073741824) label="1GiB"
    else if (bs >= 536870912)  label="512MiB"
    else if (bs >= 268435456)  label="256MiB"
    else if (bs >= 134217728)  label="128MiB"
    else if (bs >= 67108864)   label="64MiB"
    else if (bs >= 33554432)   label="32MiB"
    else if (bs >= 16777216)   label="16MiB"
    else if (bs >= 8388608)    label="8MiB"
    else if (bs >= 4194304)    label="4MiB"
    else if (bs >= 2097576)    label="~2MiB"
    else if (bs >= 1048576)    label="1MiB"
    else if (bs >= 524288)     label="512KiB"
    else if (bs >= 262144)     label="256KiB"
    else if (bs >= 131072)     label="128KiB"
    else if (bs >= 65536)      label="64KiB"
    else if (bs >= 32768)      label="32KiB"
    else if (bs >= 16384)      label="16KiB"
    else if (bs >= 8192)       label="8KiB"
    else if (bs >= 1024)       label="1KiB"
    else                       label=bs"B"
    printf "%-10s %s GB/s\n", label, tp
}' $SWEEP_LOG

# Extract peak (max throughput):
awk 'NF==2 && $1+0>0 {print $2}' $SWEEP_LOG | sort -n | tail -1

# Check if any size is below the minimum threshold (9.0 GB/s for ≥64KiB buffers):
awk 'NF==2 && $1+0>=65536 && $2+0 < 9.0 {print "FAIL:", $1, $2, "GB/s"}' $SWEEP_LOG
```

---

## DMR Baseline — All 26 Subtests

Measured on: DMR 1S × 32C, OpenSSL 3.5.1, AES-NI + AVX-512 + VAES, CentOS Stream 10.
Single-threaded (`openssl speed` default). Values are approximate (±2% run-to-run).

| # | Buffer size | Throughput | Phase | Notes |
|---|---|---|---|---|
| 104.001 | 1B | 8.4 MB/s | Per-call overhead | GCM tag + IV setup dominates |
| 104.002 | 2B | 16.8 MB/s | Per-call overhead | ~2× linear |
| 104.003 | 4B | 33.7 MB/s | Per-call overhead | ~2× linear |
| 104.004 | 8B | 67.7 MB/s | Per-call overhead | ~2× linear |
| 104.005 | 16B | 136.6 MB/s | Per-call overhead | ~2× linear |
| 104.006 | 64B | 537 MB/s | Ramp-up | Pipeline begins filling |
| 104.007 | 256B | 1.68 GB/s | Ramp-up | AES-NI active |
| 104.008 | 1KiB | 3.88 GB/s | Ramp-up | Approaching L1 ceiling |
| 104.009 | 8KiB | 9.41 GB/s | L1/L2 plateau | Fits in L1 — AES rounds pipelined |
| 104.010 | 16KiB | 10.52 GB/s | L2 plateau | |
| 104.011 | 32KiB | 11.30 GB/s | L2 plateau | |
| 104.012 | 64KiB | 11.65 GB/s | L3 plateau | |
| 104.013 | 128KiB | 11.80 GB/s | L3 plateau | |
| 104.014 | 256KiB | 11.88 GB/s | L3 plateau | |
| 104.015 | 512KiB | 11.93 GB/s | L3 plateau | |
| 104.016 | 1MiB | 11.95 GB/s | L3 plateau | |
| 104.017 | ~2MiB | **11.97 GB/s** | **Peak** | AES-NI throughput ceiling |
| 104.018 | 4MiB | 11.82 GB/s | L3 plateau | Minor variance |
| 104.019 | 8MiB | 11.93 GB/s | L3 plateau | |
| 104.020 | 16MiB | 11.89 GB/s | L3 plateau | |
| 104.021 | 32MiB | 11.91 GB/s | L3 plateau | |
| 104.022 | 64MiB | 11.38 GB/s | LLC eviction | Working set > L3 — DRAM reads begin |
| 104.023 | 128MiB | 11.01 GB/s | DRAM pressure | |
| 104.024 | 256MiB | 10.47 GB/s | DRAM pressure | |
| 104.025 | 512MiB | 10.26 GB/s | DRAM pressure | |
| 104.026 | 1GiB | 10.32 GB/s | DRAM pressure | Floor — full DRAM access pattern |

**Key observations:**
- **Peak:** ~11.97 GB/s at ~2MiB buffer (L3-resident, AES-NI fully pipelined)
- **LLC spill point:** ~64MiB — throughput drops ~5% here (L3 ≈ 54MB on DMR)
- **DRAM floor:** ~10.3 GB/s at 1GiB (14% below peak — DRAM bandwidth limits key schedule reads)
- **Small buffer cost:** 1KiB buffers = only 3.88 GB/s vs 11.97 GB/s peak — this is the overhead of per-record TLS (e.g. small HTTPS objects hit this zone)

---

## Pass Thresholds

| Buffer range | Threshold | Rationale |
|---|---|---|
| ≤ 16B | ≥ (size / 1B × 8.4) MB/s | Linear scaling expected — any deviation = AES-NI not active |
| 1KiB | ≥ 3.0 GB/s | AES-NI pipeline should be active by 1KiB |
| 8KiB–32KiB | ≥ 8.0 GB/s | L1/L2 cache zone — AES-NI should be nearly saturated |
| 64KiB–2MiB | ≥ 10.0 GB/s | L3-resident peak — below 10 GB/s indicates AES-NI not used |
| 4MiB–32MiB (**peak**) | ≥ 10.0 GB/s | Plateau zone |
| 64MiB–1GiB | ≥ 8.0 GB/s | DRAM pressure expected — large drop indicates memory bottleneck |

**FAIL indicators:**
- Any buffer ≥ 64KiB below 5.0 GB/s → AES-NI instructions not being used (check OpenSSL build flags, `grep aes /proc/cpuinfo`)
- Small buffers (1B) showing > 50 MB/s → hardware offload active unexpectedly, or buffer size interpretation error
- Large buffer (1GiB) throughput > 15% below small buffer plateau → abnormal DRAM latency (run MLC `--idle_latency` to diagnose)

---

## Report Format

```
AES-256-GCM ENCRYPTION SWEEP — Test 104 (Storage Segment Validation)
=====================================================================
System    : <CPU model>, <N>C, <OS>
OpenSSL   : 3.5.1 (AES-NI + AVX-512 + VAES)
Mode      : Software AES-NI, single-threaded

SUBTEST    BUFFER     THROUGHPUT    PHASE              STATUS
──────────────────────────────────────────────────────────────
104.001    1B         8.4 MB/s      per-call overhead  ✅ PASS
104.006    64B        537 MB/s      ramp-up             ✅ PASS
104.008    1KiB       3.88 GB/s     ramp-up             ✅ PASS
104.009    8KiB       9.41 GB/s     L1/L2 plateau       ✅ PASS
104.012    64KiB      11.65 GB/s    L3 plateau          ✅ PASS
104.017    ~2MiB      11.97 GB/s    PEAK                ✅ PASS
104.022    64MiB      11.38 GB/s    LLC eviction (-5%)  ✅ PASS
104.026    1GiB       10.32 GB/s    DRAM floor (-14%)   ✅ PASS
  ... (all 26 rows) ...
──────────────────────────────────────────────────────────────
Peak (AES-NI ceiling) : 11.97 GB/s at ~2MiB buffer
DRAM floor            : 10.32 GB/s at 1GiB buffer (14% below peak — expected)
AES-NI active         : YES (throughput > 10 GB/s at 64KiB+)

VERDICT: PASS — AES-NI fully utilized. Peak 11.97 GB/s exceeds 10.0 GB/s threshold.
         TLS termination capacity (1KiB records): ~3.9 GB/s per core.
         Bulk encryption capacity (large objects): ~10–12 GB/s per core.
```

---

## Platform Notes

- **Single-threaded by default.** `openssl speed` runs on 1 core. For total platform encryption throughput, multiply by core count or use `-multi $NPROC`:
  ```bash
  openssl speed -evp aes-256-gcm -bytes 65536 -seconds 3 -multi 32
  ```
  With `-multi 32` on DMR 32C, expect ~350–380 GB/s aggregate (32 × ~11.6 GB/s).

- **VAES (Vector AES) matters for large buffers.** DMR has VAES + AVX-512, which allows 4× AES pipelines per core. OpenSSL 3.5.1 automatically selects VAES when available — this is already reflected in the measured values.

- **Per-call overhead at small sizes is real.** A 1KiB TLS record (typical HTTPS object) encrypts at 3.88 GB/s vs the 11.97 GB/s bulk peak. For an HTTP server serving small objects, encrypt throughput is ~32% of the bulk figure — size this accordingly.

- **LLC spill at 64MiB is DMR-specific.** DMR L3 ≈ 54MB. Buffers > L3 force DRAM key schedule reads, dropping throughput ~14%. On a platform with larger L3 or HBM this boundary would shift.

- **`-bytes` flag sets the per-operation buffer, not total data.** OpenSSL runs as many operations as possible in `-seconds N`. The reported throughput is `ops × bytes / elapsed_time`.

- **`2097576` is the specified size (not a power of 2).** The test ID `104.017` uses this exact value as defined in the storage validation spec — it is ~2MiB but not 2^21 = 2097152. Both are in the L3 plateau zone.
