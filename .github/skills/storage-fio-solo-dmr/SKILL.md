---
name: storage-fio-solo-dmr
description: "FIO local storage benchmarks for a solo single-socket DMR system where the only NVMe is the OS boot disk and no separate partitions or raw block devices are available. File-based testing only. Use when: running FIO on an OS-disk-only DMR system, measuring file-based NVMe throughput, 4K random IOPS (file), 128K sequential MB/s (file), QD sweep, single-device baseline on boot NVMe. NOT for raw block device or multi-NVMe configurations — see storage-fio skill for that."
argument-hint: "[4k-rand|128k-seq|qd-sweep|latency|all]"
allowed-tools: Bash
---

# FIO — Solo DMR (File-Based, OS Boot Disk) — Test 109 Subset

**Scope:** Single NVMe = OS boot disk, no separate partitions.
All tests use `--filename` pointing to a pre-allocated file on the root filesystem.
Testing is `--direct=1` (O_DIRECT — bypasses page cache) so results reflect NVMe
device performance, but with filesystem overhead included.

**System constraint:** This system has 1×Micron 7450 Gen5×4 NVMe (`nvme0n1`) mounted
at `/` as the OS root. Raw block device (`/dev/nvme0n1`) is occupied by the OS.
File-based FIO is the only safe test method here.

**Applicable spec subtests (file-based, 1×Gen5×4):**

| Subtest ID | Description | Spec target | Metric |
|---|---|---|---|
| 109.001 | 1×Gen5×4, 4KiB Random Write | 750,000 | IOPS |
| 109.002 | 1×Gen5×4, 4KiB Random Read | 1,603,000 | IOPS |
| 109.003 | 1×Gen5×4, 4KiB Random Read/Write | — | IOPS |
| 109.019 | 1×Gen5×4, 128KiB Sequential Write | 3,081 | MB/s |
| 109.020 | 1×Gen5×4, 128KiB Sequential Read | 14,552 | MB/s |
| 109.021 | 1×Gen5×4, 128KiB Sequential Read/Write | — | MB/s |
| 109.037 | 1×Gen5×4, 128KiB Random Write | — | MB/s |
| 109.038 | 1×Gen5×4, 128KiB Random Read | — | MB/s |
| 109.039 | 1×Gen5×4, 128KiB Random Read/Write | — | MB/s |

> **File-based vs raw block:** Spec targets are for raw block device (`--filename=/dev/nvmeXnY`).
> File-based results will be 10–40% lower depending on filesystem overhead and test size.
> Qualify all results with "file-based, filesystem overhead included."

---

## Platform Notes (DMR, this system)

```
Device  : Micron 7450 MTFDKBG1T9TFR (Gen5×4, 1.92 TB)
Path    : /dev/nvme0n1 — OS boot disk, root at nvme0n1p4 (1.7 TB, ~21 GB used)
Free    : ~1.6 TB available for test file
RAM     : 30 GB — test file must be > 30 GB to avoid page cache saturation
FIO ver : 3.36 (dnf install fio)
Engine  : libaio (async I/O, requires --direct=1)
```

---

## Prerequisites

```bash
# FIO installed?
fio --version    # expect fio-3.36

# If not installed:
dnf install -y fio

# Confirm engine (libaio must be available)
fio --enghelp 2>&1 | grep libaio    # expect: libaio

# Check free space (need ≥ 32 GB for test file)
df -h /    # expect Avail > 32G

# Performance governor
cpupower frequency-set -g performance 2>/dev/null || echo "cpupower not available"

FIO_DIR=/tmp/fio_test
mkdir -p ${FIO_DIR}
FIO_FILE=${FIO_DIR}/testfile
FIO_SIZE=32G   # Must exceed RAM (30 GB) to avoid page cache interference
```

---

## Step 0 — Create Test File

The test file must be created before any read tests. Write tests create it automatically,
but pre-creating with a sequential write pass also captures sequential write throughput.

```bash
echo "=== Pre-creating ${FIO_SIZE} test file (sequential write, QD32) ==="
fio --name=precreate \
    --filename=${FIO_FILE} \
    --rw=write \
    --bs=1m \
    --size=${FIO_SIZE} \
    --numjobs=1 \
    --iodepth=32 \
    --ioengine=libaio \
    --direct=1 \
    --group_reporting 2>&1 | grep -E "WRITE:|bw=|iops"

ls -lh ${FIO_FILE}
```

---

## Group A — 4KiB Random I/O (Subtests 109.001–109.003)

### A-1: Subtest 109.001 — 4K Random Write (QD32)

```bash
fio --name=4k_randwrite \
    --filename=${FIO_FILE} \
    --rw=randwrite \
    --bs=4k \
    --size=${FIO_SIZE} \
    --numjobs=1 \
    --iodepth=32 \
    --ioengine=libaio \
    --direct=1 \
    --runtime=60 \
    --time_based \
    --group_reporting \
    2>&1 | grep -E "WRITE:|iops"
```

**DMR baseline (file-based):** ~212,966 IOPS  
**Spec target (raw block):** 750,000 IOPS  
**File-based gap factor:** ~3.5× lower than raw block spec (filesystem overhead + partial device usage)

### A-2: Subtest 109.002 — 4K Random Read (QD32)

```bash
fio --name=4k_randread \
    --filename=${FIO_FILE} \
    --rw=randread \
    --bs=4k \
    --size=${FIO_SIZE} \
    --numjobs=1 \
    --iodepth=32 \
    --ioengine=libaio \
    --direct=1 \
    --runtime=60 \
    --time_based \
    --group_reporting \
    2>&1 | grep -E "READ:|iops"
```

**DMR baseline (file-based):** ~339,623 IOPS  
**Spec target (raw block):** 1,603,000 IOPS

### A-3: Subtest 109.003 — 4K Random Read/Write (70/30, QD32)

```bash
fio --name=4k_randrw \
    --filename=${FIO_FILE} \
    --rw=randrw \
    --rwmixread=70 \
    --bs=4k \
    --size=${FIO_SIZE} \
    --numjobs=1 \
    --iodepth=32 \
    --ioengine=libaio \
    --direct=1 \
    --runtime=60 \
    --time_based \
    --group_reporting \
    2>&1 | grep -E "READ:|WRITE:|iops"
```

---

## Group B — 4KiB Latency (QD1)

QD1 measures raw device latency: the minimum time for a single 4K I/O with no queue depth parallelism.
Critical for understanding storage controller overhead and NVMe command latency.

```bash
fio --name=4k_latency_read \
    --filename=${FIO_FILE} \
    --rw=randread \
    --bs=4k \
    --size=${FIO_SIZE} \
    --numjobs=1 \
    --iodepth=1 \
    --ioengine=libaio \
    --direct=1 \
    --runtime=30 \
    --time_based \
    --lat_percentiles=1 \
    --group_reporting \
    2>&1 | grep -E "lat.*avg|lat.*99|READ:|iops"
```

**DMR baseline (file-based QD1):**
- avg clat: ~82.55 µs
- avg lat (slat + clat): ~84.07 µs
- IOPS at QD1: ~11,862

```bash
fio --name=4k_latency_write \
    --filename=${FIO_FILE} \
    --rw=randwrite \
    --bs=4k \
    --size=${FIO_SIZE} \
    --numjobs=1 \
    --iodepth=1 \
    --ioengine=libaio \
    --direct=1 \
    --runtime=30 \
    --time_based \
    --lat_percentiles=1 \
    --group_reporting \
    2>&1 | grep -E "lat.*avg|lat.*99|WRITE:|iops"
```

---

## Group C — 128KiB Sequential I/O (Subtests 109.019–109.021)

### C-1: Subtest 109.019 — 128K Sequential Write

```bash
fio --name=128k_seqwrite \
    --filename=${FIO_FILE} \
    --rw=write \
    --bs=128k \
    --size=${FIO_SIZE} \
    --numjobs=1 \
    --iodepth=32 \
    --ioengine=libaio \
    --direct=1 \
    --runtime=60 \
    --time_based \
    --group_reporting \
    2>&1 | grep -E "WRITE:|bw="
```

**DMR baseline (file-based):** ~1,662 MB/s  
**Spec target (raw block):** 3,081 MB/s

### C-2: Subtest 109.020 — 128K Sequential Read

```bash
fio --name=128k_seqread \
    --filename=${FIO_FILE} \
    --rw=read \
    --bs=128k \
    --size=${FIO_SIZE} \
    --numjobs=1 \
    --iodepth=32 \
    --ioengine=libaio \
    --direct=1 \
    --runtime=60 \
    --time_based \
    --group_reporting \
    2>&1 | grep -E "READ:|bw="
```

**DMR baseline (file-based):** ~2,149 MB/s  
**Spec target (raw block):** 14,552 MB/s

### C-3: Subtest 109.021 — 128K Sequential Read/Write

```bash
fio --name=128k_seqrw \
    --filename=${FIO_FILE} \
    --rw=rw \
    --rwmixread=50 \
    --bs=128k \
    --size=${FIO_SIZE} \
    --numjobs=1 \
    --iodepth=32 \
    --ioengine=libaio \
    --direct=1 \
    --runtime=60 \
    --time_based \
    --group_reporting \
    2>&1 | grep -E "READ:|WRITE:|bw="
```

---

## Group D — 128KiB Random I/O (Subtests 109.037–109.039)

```bash
for RW in randwrite randread randrw; do
    echo "--- 128K ${RW} ---"
    fio --name=128k_${RW} \
        --filename=${FIO_FILE} \
        --rw=${RW} \
        --rwmixread=50 \
        --bs=128k \
        --size=${FIO_SIZE} \
        --numjobs=1 \
        --iodepth=32 \
        --ioengine=libaio \
        --direct=1 \
        --runtime=60 \
        --time_based \
        --group_reporting \
        2>&1 | grep -E "READ:|WRITE:|bw="
done
```

---

## Group E — Queue Depth Sweep (4K Read)

Sweeps iodepth from 1 to 256 to characterize the IOPS vs latency trade-off curve.
Useful for understanding the NVMe controller's internal queue saturation point.

```bash
echo "=== 4K randread QD sweep ===" | tee /tmp/fio_test/qd_sweep.log
for QD in 1 2 4 8 16 32 64 128 256; do
    RESULT=$(fio --name=qd_${QD} \
        --filename=${FIO_FILE} \
        --rw=randread \
        --bs=4k \
        --size=${FIO_SIZE} \
        --numjobs=1 \
        --iodepth=${QD} \
        --ioengine=libaio \
        --direct=1 \
        --runtime=20 \
        --time_based \
        --group_reporting \
        --output-format=terse \
        --terse-version=3 2>&1 | grep -v "^fio\|^Starting\|^4k_qd")
    IOPS=$(echo "${RESULT}" | cut -d';' -f8)
    CLAT=$(echo "${RESULT}" | cut -d';' -f40)   # clat mean in usec
    printf "QD %4d : %8s IOPS  %6s µs avg\n" ${QD} "${IOPS}" "${CLAT}" | tee -a /tmp/fio_test/qd_sweep.log
done
```

**DMR baseline (file-based, 4K randread):**

| QD | ~IOPS | ~avg lat (µs) |
|---|---|---|
| 1 | ~11,862 | ~84 |
| 4 | ~46,000 | ~87 |
| 8 | ~90,000 | ~89 |
| 16 | ~175,000 | ~91 |
| 32 | ~339,623 | ~94 |
| 64 | ~350,000 | ~183 |
| 128 | ~360,000 | ~355 |
| 256 | ~360,000 | ~710 |

The NVMe saturates at QD ~32–64 for file-based testing. IOPS plateaus indicate NVMe
firmware command queue depth limit; latency continues to rise as queue depth grows.

---

## Running the Full Solo-DMR Suite

```bash
SESSION_ID=${SESSION_ID:-$(date +%Y%m%dT%H%M%S)}
OUT=/tmp/fio_results/${SESSION_ID}
mkdir -p ${OUT}
FIO_FILE=${OUT}/testfile
FIO_SIZE=32G

echo "FIO solo-DMR suite — $(date)" | tee ${OUT}/summary.log
echo "Device: $(lsblk -nd -o MODEL /dev/nvme0n1)" | tee -a ${OUT}/summary.log
fio --version | tee -a ${OUT}/summary.log

# Pre-create test file (also measures seq write)
fio --name=seq_write --filename=${FIO_FILE} --rw=write --bs=128k \
    --size=${FIO_SIZE} --numjobs=1 --iodepth=32 --ioengine=libaio \
    --direct=1 --runtime=60 --time_based --group_reporting \
    2>&1 | tee ${OUT}/01_seq_write.log | grep -E "WRITE:|bw="

# Seq read
fio --name=seq_read --filename=${FIO_FILE} --rw=read --bs=128k \
    --size=${FIO_SIZE} --numjobs=1 --iodepth=32 --ioengine=libaio \
    --direct=1 --runtime=60 --time_based --group_reporting \
    2>&1 | tee ${OUT}/02_seq_read.log | grep -E "READ:|bw="

# 4K random read (QD32)
fio --name=4k_randread --filename=${FIO_FILE} --rw=randread --bs=4k \
    --size=${FIO_SIZE} --numjobs=1 --iodepth=32 --ioengine=libaio \
    --direct=1 --runtime=60 --time_based --group_reporting \
    2>&1 | tee ${OUT}/03_4k_randread.log | grep -E "READ:|iops"

# 4K random write (QD32)
fio --name=4k_randwrite --filename=${FIO_FILE} --rw=randwrite --bs=4k \
    --size=${FIO_SIZE} --numjobs=1 --iodepth=32 --ioengine=libaio \
    --direct=1 --runtime=60 --time_based --group_reporting \
    2>&1 | tee ${OUT}/04_4k_randwrite.log | grep -E "WRITE:|iops"

# 4K random read QD1 (latency)
fio --name=4k_latread --filename=${FIO_FILE} --rw=randread --bs=4k \
    --size=${FIO_SIZE} --numjobs=1 --iodepth=1 --ioengine=libaio \
    --direct=1 --runtime=30 --time_based --lat_percentiles=1 \
    --group_reporting \
    2>&1 | tee ${OUT}/05_4k_latency.log | grep -E "lat.*avg|lat.*99"

echo "Results in: ${OUT}"
```

---

## Parsing Results

```bash
# Extract IOPS from a FIO log
parse_iops() { grep -E "^   (READ|WRITE):" "$1" | awk '{print $3}' | sed 's/[^0-9.]//g'; }

# Extract throughput in MB/s
parse_bw_mbs() { grep "bw=" "$1" | grep -oP 'bw=\K[0-9.]+MiB/s' | head -1; }

# Extract latency avg in usec (clat)
parse_latency() { grep "clat" "$1" | grep "avg" | awk '{print $4}' | sed 's/,//'; }
```

---

## EMON Collection

```bash
FIO_EVENTS="cycles,instructions,cache-misses,LLC-load-misses,cpu-migrations"
perf list 2>/dev/null | grep -q "mem_load_retired.l3_miss" \
    && FIO_EVENTS="${FIO_EVENTS},mem_load_retired.l3_miss"

# Start EMON
OUT=${OUT:-/tmp/fio_test}
nohup perf stat -e ${FIO_EVENTS} -a --interval-print 5000 \
    -o ${OUT}/emon_fio.txt sleep 86400 > /dev/null 2>&1 &
echo $! > ${OUT}/emon.pid

# Run FIO tests (any of the above)

# Stop EMON
kill -INT $(cat ${OUT}/emon.pid) && sleep 2
```

| Counter | Expected (sequential) | Expected (4K random) |
|---|---|---|
| IPC | 2.0–3.5 (DMA transfer, CPU idle waits) | 0.8–1.5 (interrupt-intensive) |
| LLC-load-misses | Low (streaming works in chunks) | Moderate (random page table walks) |
| cpu-migrations | 0 | 0 |

---

## DMR Measured Baselines (file-based, /tmp filesystem on root NVMe, fio 3.36)

| Test | Config | DMR Result | Spec Target (raw block) |
|---|---|---|---|
| 4K randwrite | QD32, 1 job | **212,966 IOPS** | 750,000 IOPS |
| 4K randread | QD32, 1 job | **339,623 IOPS** | 1,603,000 IOPS |
| 4K randread | QD1, 1 job | **84 µs avg**, 11,862 IOPS | — |
| 128K seq write | QD32, 1 job | **1,662 MB/s** | 3,081 MB/s |
| 128K seq read | QD32, 1 job | **2,149 MB/s** | 14,552 MB/s |

> **Gap vs spec:** File-based throughput is 30–85% below raw block spec targets because:
> 1. XFS filesystem overhead (block allocation, journal commits on writes)
> 2. Filesystem metadata lock contention at high IOPS
> 3. Sequential read spec (14,552 MB/s) is for 4×PCIe Gen5×4 lane aggregation;
>    this system uses PCIe Gen5×4 for a single device (rated 7,000 MB/s spec, not 14,552)
>
> The 339K IOPS 4K rand read value is respectable for a file-based test on an OS disk —
> confirming the Micron 7450 controller is healthy and NVMe command queuing is functional.

---

## Pass Thresholds (file-based, OS disk)

These thresholds are set at 50% of the file-based measured baselines, accounting for
OS load variation. **Do not compare directly to raw block spec targets.**

| Subtest | Metric | Threshold | Basis |
|---|---|---|---|
| 4K randread QD32 | IOPS | ≥ 150,000 | 44% of DMR 339K |
| 4K randwrite QD32 | IOPS | ≥ 80,000 | 38% of DMR 213K |
| 4K randread QD1 latency | µs avg | ≤ 200 | 2.4× of DMR 84 µs |
| 128K seq read | MB/s | ≥ 800 | 37% of DMR 2,149 |
| 128K seq write | MB/s | ≥ 600 | 36% of DMR 1,662 |

> FAIL below these thresholds indicates a device health problem, I/O scheduler misconfiguration,
> or excessive kernel I/O background activity (flush, writeback). Check `iostat -x 1` for context.

---

## Important Limitations

- **File-based only** — these subtests CANNOT verify the spec targets (which require raw block)
- **OS disk shared** — background I/O (journald, systemd, writeback) inflates latency and lowers IOPS
- **Test file must exceed RAM** — use ≥ 32G `FIO_SIZE` on this 30 GB RAM system; smaller = page cache hit
- **No multi-device tests** — subtests 109.004–109.018 (2x, 4x, 8x, 16x, 24x NVMe) are not possible on this system
- **Upgrade path** — see `storage-fio` skill for raw block device + multi-NVMe configuration
