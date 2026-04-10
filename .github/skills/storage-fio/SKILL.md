---
name: storage-fio
description: "FIO local NVMe storage benchmarks for storage segment validation Tests 109–113. Use when: running FIO on a dedicated NVMe partition or raw block device, measuring 4K random IOPS, 128K sequential MB/s, multi-NVMe scaling (1x to 24x), queue depth sweep, mixed read/write workloads, composite FIO + iperf3 workloads (Tests 110–113). Requires: dedicated NVMe partition or raw block device not used as OS disk, or multiple NVMe drives. For OS-boot-disk-only systems, use storage-fio-solo-dmr instead."
argument-hint: "[4k-rand|128k-seq|qd-sweep|multi-nvme <N>|composite|all] [--device /dev/nvmeXnY]"
allowed-tools: Bash
---

# FIO — Local Storage Tests 109–113 (Raw Block / Dedicated Partition)

**Scope:** Tests 109–113 from `Storage_Segment_Validation_v0.5.xlsx`.
- **Test 109** — Single-device and multi-device FIO (1×, 2×, 4×, 8×, 16×, 24× NVMe)
- **Tests 110–113** — Composite workloads combining FIO + iperf3 / application-level I/O
  (not documented here — requires second machine + 400GbE NIC; see `storage-iperf3`)

> ⚠️ **Prerequisites:** This skill requires a dedicated storage device.
> On a solo DMR system with only an OS boot NVMe, use **`storage-fio-solo-dmr`** instead.
> The spec targets below are for raw block device (`--filename=/dev/nvmeXnY --direct=1`).

---

## Hardware Requirements

| Config | Required | Spec target — 4K rand read | 128K seq read |
|---|---|---|---|
| 1×Gen5×4 NVMe | Dedicated non-OS NVMe or partition | 1,603,000 IOPS | 14,552 MB/s |
| 2×Gen5×4 NVMe | 2× dedicated NVMe | — | — |
| 4×Gen5×4 NVMe | 4× dedicated NVMe | 7,580,000 IOPS | 58,209 MB/s |
| 8×Gen5×4 NVMe | 8× dedicated NVMe | ~2.2M IOPS | ~106 GB/s |
| 16×Gen5×4 NVMe | 16× dedicated NVMe | — | — |
| 24×Gen5×4 NVMe | 24× dedicated NVMe | — | — |
| 1×Gen6×4 NVMe | Dedicated non-OS Gen6 NVMe | 5,526,000 IOPS | 28,054 MB/s |
| 4×Gen6×4 NVMe | 4× dedicated Gen6 NVMe | 22,328,000 IOPS | — |
| 8×Gen6×4 NVMe | 8× dedicated Gen6 NVMe | 44,638,000 IOPS | — |

---

## Variables

```bash
# Set before running — must point to a NON-OS device or partition
NVME_DEVICES=(/dev/nvme1n1)          # Array — add devices for multi-NVMe tests
NDEVICES=${#NVME_DEVICES[@]}

# For multi-device tests: all devices joined as colon-separated string
NVME_MULTI="${NVME_DEVICES[*]// /:}"  # e.g. /dev/nvme1n1:/dev/nvme2n1

SESSION_ID=${SESSION_ID:-$(date +%Y%m%dT%H%M%S)}
OUT=./results/${SESSION_ID}/bench/fio
mkdir -p ${OUT}

NPROC=$(nproc)
```

---

## Prerequisites

```bash
# FIO installed?
fio --version   # expect fio-3.36+

# If not:
dnf install -y fio   # CentOS/RHEL
# apt-get install -y fio   # Ubuntu/Debian

# Confirm libaio engine
fio --enghelp 2>&1 | grep libaio

# CRITICAL: Confirm target device is NOT the OS boot disk
lsblk -o NAME,SIZE,MOUNTPOINT,MODEL | grep -v loop
# Ensure NVME_DEVICES entries have no MOUNTPOINT listed

# Check device is accessible
dd if=${NVME_DEVICES[0]} of=/dev/null bs=1M count=1 2>&1 | grep -E "1048576|error"

# Performance config
cpupower frequency-set -g performance
systemctl stop irqbalance

# Set I/O scheduler to none/mq-deadline for NVMe
for DEV in "${NVME_DEVICES[@]}"; do
    DEVNAME=$(basename ${DEV})
    echo mq-deadline > /sys/block/${DEVNAME}/queue/scheduler 2>/dev/null \
        || echo none > /sys/block/${DEVNAME}/queue/scheduler 2>/dev/null \
        || echo "scheduler set skipped for ${DEV}"
    cat /sys/block/${DEVNAME}/queue/scheduler
done
```

---

## Group A — 4KiB Random I/O, Single Device (Subtests 109.001–109.003)

### A-1: 109.001 — 4K Random Write, 1×Gen5×4, QD512 (spec: 750K IOPS)

```bash
DEV=${NVME_DEVICES[0]}
fio --name=109_001_4k_randwrite \
    --filename=${DEV} \
    --rw=randwrite \
    --bs=4k \
    --numjobs=1 \
    --iodepth=512 \
    --ioengine=libaio \
    --direct=1 \
    --runtime=60 \
    --time_based \
    --group_reporting \
    2>&1 | tee ${OUT}/109.001_4k_randwrite.log | grep -E "WRITE:|iops"
```

**Spec:** 750,000 IOPS  |  **Pass:** ≥ 600,000 IOPS

### A-2: 109.002 — 4K Random Read, 1×Gen5×4, QD512 (spec: 1,603K IOPS)

```bash
DEV=${NVME_DEVICES[0]}
fio --name=109_002_4k_randread \
    --filename=${DEV} \
    --rw=randread \
    --bs=4k \
    --numjobs=1 \
    --iodepth=512 \
    --ioengine=libaio \
    --direct=1 \
    --runtime=60 \
    --time_based \
    --group_reporting \
    2>&1 | tee ${OUT}/109.002_4k_randread.log | grep -E "READ:|iops"
```

**Spec:** 1,603,000 IOPS  |  **Pass:** ≥ 1,280,000 IOPS

### A-3: 109.003 — 4K Random Read/Write (70/30), 1×Gen5×4, QD512

```bash
DEV=${NVME_DEVICES[0]}
fio --name=109_003_4k_randrw \
    --filename=${DEV} \
    --rw=randrw \
    --rwmixread=70 \
    --bs=4k \
    --numjobs=1 \
    --iodepth=512 \
    --ioengine=libaio \
    --direct=1 \
    --runtime=60 \
    --time_based \
    --group_reporting \
    2>&1 | tee ${OUT}/109.003_4k_randrw.log | grep -E "READ:|WRITE:|iops"
```

---

## Group B — 4KiB Random I/O, Multi-Device Scale (Subtests 109.004–109.018)

Multi-device tests require `NVME_DEVICES` array to have the appropriate number of devices.
FIO `--filename` accepts colon-separated device paths for multi-device striping.

```bash
# Check you have the required device count before running
echo "Devices configured: ${NDEVICES}"
echo "Devices: ${NVME_DEVICES[*]}"

# Generic multi-device 4K randread test (replace N_DEVS and DEVICE_LIST)
run_multi_4k_randread() {
    local DESC=$1
    local DEVLIST=$2  # colon-separated
    local NUMJOBS=$3
    echo "--- ${DESC} ---"
    fio --name=${DESC} \
        --filename=${DEVLIST} \
        --rw=randread \
        --bs=4k \
        --numjobs=${NUMJOBS} \
        --iodepth=512 \
        --ioengine=libaio \
        --direct=1 \
        --runtime=60 \
        --time_based \
        --group_reporting \
        2>&1 | grep -E "READ:|iops"
}
```

| Subtest | Config | Spec target |
|---|---|---|
| 109.004 | 2×Gen5×4, 4K rand write | — |
| 109.005 | 2×Gen5×4, 4K rand read | — |
| 109.007 | 4×Gen5×4, 4K rand write | 2,401,000 IOPS |
| 109.008 | 4×Gen5×4, 4K rand read | 7,580,000 IOPS |
| 109.010 | 8×Gen5×4, 4K rand write | ~2,211,000 IOPS |
| 109.011 | 8×Gen5×4, 4K rand read | ~2,228,000 IOPS |

> **NOTE:** These subtests require 2, 4, 8, 16, or 24 dedicated NVMe drives.
> This section is a skeleton — fill in when hardware is available.

---

## Group C — 128KiB Sequential I/O, Single Device (Subtests 109.019–109.021)

### C-1: 109.019 — 128K Sequential Write, 1×Gen5×4 (spec: 3,081 MB/s)

```bash
DEV=${NVME_DEVICES[0]}
fio --name=109_019_128k_seqwrite \
    --filename=${DEV} \
    --rw=write \
    --bs=128k \
    --numjobs=1 \
    --iodepth=32 \
    --ioengine=libaio \
    --direct=1 \
    --runtime=60 \
    --time_based \
    --group_reporting \
    2>&1 | tee ${OUT}/109.019_128k_seqwrite.log | grep -E "WRITE:|bw="
```

**Spec:** 3,081 MB/s  |  **Pass:** ≥ 2,460 MB/s (80%)

### C-2: 109.020 — 128K Sequential Read, 1×Gen5×4 (spec: 14,552 MB/s)

```bash
DEV=${NVME_DEVICES[0]}
fio --name=109_020_128k_seqread \
    --filename=${DEV} \
    --rw=read \
    --bs=128k \
    --numjobs=1 \
    --iodepth=32 \
    --ioengine=libaio \
    --direct=1 \
    --runtime=60 \
    --time_based \
    --group_reporting \
    2>&1 | tee ${OUT}/109.020_128k_seqread.log | grep -E "READ:|bw="
```

**Spec:** 14,552 MB/s  
> Note: 14,552 MB/s assumes 4× Gen5×4 PCIe lanes aggregated. A single device with ×4 lanes
> has a theoretical PCIe Gen5×4 max of ~14 GB/s — this spec appears to be for a 4×PCIe
> configuration. Single device raw block expected: ~7,000 MB/s (Micron 7450 spec).

**Pass (1× device):** ≥ 5,600 MB/s (80% of Micron 7450 7,000 MB/s rated)

### C-3: 109.021 — 128K Sequential RW (50/50), 1×Gen5×4

```bash
DEV=${NVME_DEVICES[0]}
fio --name=109_021_128k_seqrw \
    --filename=${DEV} \
    --rw=rw \
    --rwmixread=50 \
    --bs=128k \
    --numjobs=1 \
    --iodepth=32 \
    --ioengine=libaio \
    --direct=1 \
    --runtime=60 \
    --time_based \
    --group_reporting \
    2>&1 | tee ${OUT}/109.021_128k_seqrw.log | grep -E "READ:|WRITE:|bw="
```

---

## Group D — Queue Depth Sweep (4K Read, Single Device)

```bash
DEV=${NVME_DEVICES[0]}
echo "=== QD sweep — 4K randread ===" | tee ${OUT}/qd_sweep.log
for QD in 1 2 4 8 16 32 64 128 256 512 1024; do
    RESULT=$(fio --name=qd_${QD} --filename=${DEV} --rw=randread --bs=4k \
        --numjobs=1 --iodepth=${QD} --ioengine=libaio --direct=1 \
        --runtime=20 --time_based --output-format=terse --terse-version=3 \
        --group_reporting 2>&1 | grep -v "^fio\|^Starting\|^qd_")
    IOPS=$(echo "${RESULT}" | cut -d';' -f8)
    CLAT=$(echo "${RESULT}" | cut -d';' -f40)
    printf "QD %5d : %10s IOPS  %8s µs\n" ${QD} "${IOPS}" "${CLAT}" | tee -a ${OUT}/qd_sweep.log
done
```

---

## Group E — 128KiB Random I/O, Multi-Device Scale (Subtests 109.037–109.054)

```bash
# Skeleton — fill in device list when hardware is available
# Subtests 109.037-039: 1× device
# Subtests 109.040-042: 2× devices
# Subtests 109.043-045: 4× devices
# Subtests 109.046-048: 8× devices
# ...
```

---

## EMON Collection — Storage I/O Workload

```bash
STORAGE_EVENTS="cycles,instructions,cache-misses,LLC-load-misses,cpu-migrations"
perf list 2>/dev/null | grep -q "mem_load_retired.l3_miss" \
    && STORAGE_EVENTS="${STORAGE_EVENTS},mem_load_retired.l3_miss"

# Start EMON before FIO
nohup perf stat -e ${STORAGE_EVENTS} -a --interval-print 5000 \
    -o ${OUT}/emon_fio.txt sleep 86400 > /dev/null 2>&1 &
echo $! > ${OUT}/emon.pid
echo "EMON started (PID $(cat ${OUT}/emon.pid))"

# Run FIO tests here

# Stop EMON
kill -INT $(cat ${OUT}/emon.pid) 2>/dev/null && sleep 2
echo "EMON data: ${OUT}/emon_fio.txt"
```

---

## Report Format

```
FIO LOCAL STORAGE — Test 109
============================
Platform  : <CPU model>  <N>C  kernel <K>
Devices   : <N>× <model> (Gen<X>×4, <capacity>)
FIO       : <version>  engine: libaio  direct=1
Session   : <SESSION_ID>

SINGLE DEVICE (1×Gen5×4) RESULTS
----------------------------------
Subtest    Description                 Result         Spec      Status
109.001    4K randwrite QD512          <X> IOPS       750K      PASS/FAIL
109.002    4K randread  QD512          <X> IOPS       1,603K    PASS/FAIL
109.019    128K seq write              <X> MB/s       3,081     PASS/FAIL
109.020    128K seq read               <X> MB/s       14,552*   PASS/FAIL
           (*single device compared to 7,000 MB/s rated)

MULTI-DEVICE SCALING (if applicable)
--------------------------------------
4× NVMe:   4K randread                <X> IOPS       7,580K    PASS/FAIL
4× NVMe:   128K seq read              <X> MB/s       58,209    PASS/FAIL

VERDICT: PASS / FAIL
```

---

## FIO Parameter Reference

| Parameter | Typical value | Purpose |
|---|---|---|
| `--bs=4k` | 4096 B | NVMe sector-aligned, IOPS workload |
| `--bs=128k` | 131072 B | Sequential bandwidth workload |
| `--iodepth=32` | 32 | Queue depth for sequential (saturates most NVMe at ≥16) |
| `--iodepth=512` | 512 | Queue depth for random IOPS (saturates at ≥128 on most NVMe) |
| `--numjobs=1` | 1 | Single job for single-device; multiply for multi-NVMe tests |
| `--direct=1` | 1 | O_DIRECT — bypass page cache (required for valid NVMe measurement) |
| `--ioengine=libaio` | libaio | Linux async I/O — required for queue depth > 1 |
| `--runtime=60` | 60 s | Minimum 60s for stable IOPS reading on NVMe |
| `--time_based` | present | Run for full runtime even if file is exhausted |
| `--rwmixread=70` | 70 | 70% read / 30% write mixed workload |

---

## Multi-NVMe Setup Notes

When adding drives, confirm:

```bash
# List all NVMe devices
lsblk -d -o NAME,SIZE,MODEL | grep nvme

# Confirm PCIe generation and width
lspci -vv | grep -A5 "Non-Volatile"

# Check drive health before benchmarking
nvme smart-log /dev/nvme1n1 | grep -E "percentage_used|available_spare|unsafe_shutdowns"
```

For multi-device FIO, use `--filename` with colon-separated paths:
```bash
fio ... --filename=/dev/nvme1n1:/dev/nvme2n1:/dev/nvme3n1:/dev/nvme4n1
```
FIO stripes I/O across all listed devices. `numjobs=N` creates N worker threads per job.

---

## Upgrade Path from solo-dmr

If upgrading from a file-based (`storage-fio-solo-dmr`) run to raw block:

```bash
# Add a dedicated NVMe (not the OS disk)
# Verify it is NOT mounted
lsblk /dev/nvme1n1  # should show no MOUNTPOINT

# Run this skill with NVME_DEVICES=(/dev/nvme1n1)
# Compare results against DMR file-based baselines in storage-fio-solo-dmr
# Expected improvement on raw block vs file-based:
#   4K randread:   3–5× higher IOPS (339K → 1.0–1.6M)
#   128K seq read: 3–5× higher MB/s (2,149 → 6,000–7,000 MB/s)
```
