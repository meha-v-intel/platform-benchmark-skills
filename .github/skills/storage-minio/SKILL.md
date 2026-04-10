---
name: storage-minio
description: "MinIO S3 object storage benchmark using WARP for storage segment validation Test 117. Use when: benchmarking MinIO PUT/GET throughput, measuring object storage bandwidth, running S3 WARP sweeps, measuring 1KiB/4KiB/64KiB/1MiB/4MiB/16MiB/64MiB object performance, concurrency sweep 4→256 on MinIO, NonProd MinIO workload, Software Defined Storage benchmarking, validating S3-compatible storage."
argument-hint: "[put|get|put-sweep|get-sweep|all|1kib|64kib|1mib|64mib]"
allowed-tools: Bash
---

# MinIO WARP — Software Defined Storage: NonProd MinIO — Test 117

**Scope:** WARP S3 benchmark against a single-node MinIO server.
Covers 8 object sizes × 2 operations (Put/Get) × 7 concurrencies = 112 subtests,
plus 2 MLPerf subtests (117.113–117.114, out-of-scope for single-node solo system).

**Spec workload:** "Software Defined Storage: NonProd Minio"
**Tool:** WARP (github.com/minio/warp) — S3 benchmark by MinIO
**MinIO deployment:** Single-node, single-drive (`/data/minio`), loopback (localhost)

---

## Spec Subtest Map — Test 117

| Subtest range | Object size | Operations | Concurrencies |
|---|---|---|---|
| 117.001–117.014 | 1KiB | Put C4→C256, Get C4→C256 | 4,8,16,32,64,128,256 |
| 117.015–117.028 | 4KiB | Put C4→C256, Get C4→C256 | 4,8,16,32,64,128,256 |
| 117.029–117.042 | 16KiB | Put C4→C256, Get C4→C256 | 4,8,16,32,64,128,256 |
| 117.043–117.056 | 64KiB | Put C4→C256, Get C4→C256 | 4,8,16,32,64,128,256 |
| 117.057–117.070 | 1MiB | Put C4→C256, Get C4→C256 | 4,8,16,32,64,128,256 |
| 117.071–117.084 | 4MiB | Put C4→C256, Get C4→C256 | 4,8,16,32,64,128,256 |
| 117.085–117.098 | 16MiB | Put C4→C256, Get C4→C256 | 4,8,16,32,64,128,256 |
| 117.099–117.112 | 64MiB | Put C4→C256, Get C4→C256 | 4,8,16,32,64,128,256 |
| 117.113 | n/a | MLPerf Storage / TF_ObjectStorage (Training) | Full System |
| 117.114 | n/a | MLPerf Storage / TF_ObjectStorage (Inference) | Full System |

> **MLPerf (117.113–117.114):** Requires multi-node, multi-drive MinIO cluster + GPU training
> workload. Not runnable on a single-socket solo DMR without distributed MinIO.
> Mark those subtests as ❌ NOT ELIGIBLE for solo single-socket configurations.

---

## Platform Notes (DMR, this system)

```
System  : 1S×32C×1T, 30GiB RAM, CentOS Stream 10, kernel 6.18.0-dmr.bkc
NVMe    : Micron 7450 MTFDKBG1T9TFR (Gen5×4, 1.92 TB) — OS boot disk at /dev/nvme0n1
MinIO   : /data/minio — NVMe root filesystem partition, ~1.6 TB free
MinIO   : DEVELOPMENT.GOGET build (go install github.com/minio/minio@latest)
WARP    : dev build (go install github.com/minio/warp@latest)
Go      : 1.26.1 (Red Hat 1.26.1-1.el10)
Network : loopback (lo) — localhost:9000 → no NIC bottleneck
```

> **Single-node MinIO note:** This is a single-node, single-drive MinIO deployment.
> The spec's "Full System" tests will be bottlenecked by:
> 1. **PUT:** NVMe write throughput (~1.1 GB/s for large objects; ~3K RPC/s for small)
> 2. **GET:** RAM page cache (~8 GB/s for large objects; ~44K RPC/s for small at C32)
> Multi-node MinIO with multiple NVMe drives would show proportionally higher throughput.

---

## Prerequisites

### Step 1 — Install Go ≥ 1.24

```bash
# Check if Go is installed
go version

# If not installed (CentOS Stream 10 / RHEL 10):
dnf install -y golang

# Verify Go 1.26+
go version   # expect: go version go1.26.x linux/amd64
```

### Step 2 — Build MinIO from Source

The `minio/minio` GitHub repository was archived Feb 2026 and is source-only.
Build from source using `go install`:

```bash
export GOPATH=$HOME/go
export PATH=$PATH:$GOPATH/bin

# Build MinIO (~2-3 minutes, ~150MB binary)
go install github.com/minio/minio@latest

# Verify
~/go/bin/minio --version
# expect: minio version DEVELOPMENT.GOGET ...
```

### Step 3 — Build WARP from Source

```bash
# Build WARP S3 benchmark tool (~1-2 minutes)
go install github.com/minio/warp@latest

# Verify
~/go/bin/warp --version
# expect: warp version (dev) - (dev)
```

### Step 4 — Build MinIO Client (mc) — optional

```bash
# Optional: mc for bucket management and server admin
go install github.com/minio/mc@latest
~/go/bin/mc --version
```

### Step 5 — Prepare MinIO Data Directory

```bash
# Create data directory on NVMe
mkdir -p /data/minio

# Confirm location and free space
df -h /data/minio
```

### Step 6 — Start MinIO Server

```bash
export MINIO_ROOT_USER=minioadmin
export MINIO_ROOT_PASSWORD=minioadmin

# Start MinIO (foreground for testing, nohup for persistent run)
nohup ~/go/bin/minio server /data/minio \
  --address :9000 \
  --console-address :9001 \
  > /tmp/minio.log 2>&1 &

echo "MinIO PID: $!"

# Wait and health check
sleep 4 && curl -sf http://localhost:9000/minio/health/live && echo "MinIO is UP"
```

**Verify with mc (if installed):**

```bash
~/go/bin/mc alias set local http://localhost:9000 minioadmin minioadmin
~/go/bin/mc admin info local
```

**To restart MinIO after reboot:**

```bash
export MINIO_ROOT_USER=minioadmin
export MINIO_ROOT_PASSWORD=minioadmin
nohup ~/go/bin/minio server /data/minio --address :9000 --console-address :9001 > /tmp/minio.log 2>&1 &
curl -sf http://localhost:9000/minio/health/live && echo "UP"
```

---

## Benchmark Commands

### Common WARP flags

```bash
export GOPATH=$HOME/go
export PATH=$PATH:$GOPATH/bin
WARP=~/go/bin/warp
WHOST="--host=localhost:9000 --access-key=minioadmin --secret-key=minioadmin"
WFLAGS="$WHOST --no-color --autoterm --duration=30s"
```

---

### Group A — 1KiB Objects (Subtests 117.001–117.014)

#### Put — 117.001–117.007

```bash
for CONC in 4 8 16 32 64 128 256; do
  echo "=== PUT 1KiB C${CONC} ==="
  $WARP put $WFLAGS --obj.size=1KiB --concurrent=$CONC
  echo ""
done
```

#### Get — 117.008–117.014

```bash
for CONC in 4 8 16 32 64 128 256; do
  echo "=== GET 1KiB C${CONC} ==="
  $WARP get $WFLAGS --obj.size=1KiB --concurrent=$CONC --objects=5000
  echo ""
done
```

---

### Group B — 4KiB Objects (Subtests 117.015–117.028)

#### Put — 117.015–117.021

```bash
for CONC in 4 8 16 32 64 128 256; do
  echo "=== PUT 4KiB C${CONC} ==="
  $WARP put $WFLAGS --obj.size=4KiB --concurrent=$CONC
  echo ""
done
```

#### Get — 117.022–117.028

```bash
for CONC in 4 8 16 32 64 128 256; do
  echo "=== GET 4KiB C${CONC} ==="
  $WARP get $WFLAGS --obj.size=4KiB --concurrent=$CONC --objects=2500
  echo ""
done
```

---

### Group C — 16KiB Objects (Subtests 117.029–117.042)

```bash
for CONC in 4 8 16 32 64 128 256; do
  echo "=== PUT 16KiB C${CONC} ==="
  $WARP put $WFLAGS --obj.size=16KiB --concurrent=$CONC
  echo ""
done

for CONC in 4 8 16 32 64 128 256; do
  echo "=== GET 16KiB C${CONC} ==="
  $WARP get $WFLAGS --obj.size=16KiB --concurrent=$CONC --objects=2500
  echo ""
done
```

---

### Group D — 64KiB Objects (Subtests 117.043–117.056)

```bash
for CONC in 4 8 16 32 64 128 256; do
  echo "=== PUT 64KiB C${CONC} ==="
  $WARP put $WFLAGS --obj.size=64KiB --concurrent=$CONC
  echo ""
done

for CONC in 4 8 16 32 64 128 256; do
  echo "=== GET 64KiB C${CONC} ==="
  $WARP get $WFLAGS --obj.size=64KiB --concurrent=$CONC --objects=2500
  echo ""
done
```

---

### Group E — 1MiB Objects (Subtests 117.057–117.070)

```bash
for CONC in 4 8 16 32 64 128 256; do
  echo "=== PUT 1MiB C${CONC} ==="
  $WARP put $WFLAGS --obj.size=1MiB --concurrent=$CONC
  echo ""
done

for CONC in 4 8 16 32 64 128 256; do
  echo "=== GET 1MiB C${CONC} ==="
  $WARP get $WFLAGS --obj.size=1MiB --concurrent=$CONC --objects=500
  echo ""
done
```

---

### Group F — 4MiB Objects (Subtests 117.071–117.084)

```bash
for CONC in 4 8 16 32 64 128 256; do
  echo "=== PUT 4MiB C${CONC} ==="
  $WARP put $WFLAGS --obj.size=4MiB --concurrent=$CONC
  echo ""
done

for CONC in 4 8 16 32 64 128 256; do
  echo "=== GET 4MiB C${CONC} ==="
  $WARP get $WFLAGS --obj.size=4MiB --concurrent=$CONC --objects=500
  echo ""
done
```

---

### Group G — 16MiB Objects (Subtests 117.085–117.098)

```bash
for CONC in 4 8 16 32 64 128 256; do
  echo "=== PUT 16MiB C${CONC} ==="
  $WARP put $WFLAGS --obj.size=16MiB --concurrent=$CONC
  echo ""
done

for CONC in 4 8 16 32 64 128 256; do
  echo "=== GET 16MiB C${CONC} ==="
  $WARP get $WFLAGS --obj.size=16MiB --concurrent=$CONC --objects=200
  echo ""
done
```

---

### Group H — 64MiB Objects (Subtests 117.099–117.112)

```bash
for CONC in 4 8 16 32 64 128 256; do
  echo "=== PUT 64MiB C${CONC} ==="
  $WARP put $WFLAGS --obj.size=64MiB --concurrent=$CONC
  echo ""
done

for CONC in 4 8 16 32 64 128 256; do
  echo "=== GET 64MiB C${CONC} ==="
  $WARP get $WFLAGS --obj.size=64MiB --concurrent=$CONC --objects=50
  echo ""
done
```

---

### Full Automated Sweep (All 112 WARP Subtests)

```bash
export GOPATH=$HOME/go && export PATH=$PATH:$GOPATH/bin
WARP=~/go/bin/warp
WHOST="--host=localhost:9000 --access-key=minioadmin --secret-key=minioadmin"
WFLAGS="$WHOST --no-color --autoterm --duration=30s"

SIZES=("1KiB" "4KiB" "16KiB" "64KiB" "1MiB" "4MiB" "16MiB" "64MiB")
# GET object pool sizes (pre-populated objects per size to avoid starving GET)
declare -A OBJCOUNT=([1KiB]=5000 [4KiB]=2500 [16KiB]=2500 [64KiB]=2500 [1MiB]=500 [4MiB]=500 [16MiB]=200 [64MiB]=50)
CONCS=(4 8 16 32 64 128 256)

# Check MinIO is running first
curl -sf http://localhost:9000/minio/health/live || { echo "ERROR: MinIO not running"; exit 1; }

echo "=== MinIO WARP Full Sweep — $(hostname) — $(date) ==="
echo "Platform: $(nproc) cores, $(free -h | awk '/Mem/{print $2}') RAM"
echo ""

for SIZE in "${SIZES[@]}"; do
  for CONC in "${CONCS[@]}"; do
    echo "--- PUT ${SIZE} C${CONC} ---"
    $WARP put $WFLAGS --obj.size=$SIZE --concurrent=$CONC
    echo ""
  done
  for CONC in "${CONCS[@]}"; do
    echo "--- GET ${SIZE} C${CONC} ---"
    $WARP get $WFLAGS --obj.size=$SIZE --concurrent=$CONC --objects=${OBJCOUNT[$SIZE]}
    echo ""
  done
done

echo "=== Sweep complete ==="
```

> **Expected runtime:** ~30 minutes total (112 tests × ~15s each with autoterm).
> MinIO autocleans the benchmark bucket after each run.

---

### Saving Benchmark Data for Analysis

```bash
# Save raw benchmark data to compressed JSON for later analysis
$WARP put $WFLAGS --obj.size=1MiB --concurrent=32 \
  --benchdata=/tmp/warp_1mib_c32

# Analyze saved data
$WARP analyze /tmp/warp_1mib_c32-*.json.zst
```

---

## DMR Live Baselines (Single-Node, Single-Drive, Localhost)

Measured on: **DMR 1S×32C×1T, 30GiB RAM, Micron 7450 Gen5×4 NVMe, loopback**
MinIO: DEVELOPMENT.GOGET | WARP: dev | Date: 2026-04-10

| Object Size | Op | Concurrency | Throughput | IOPS/obj/s | Avg Latency | Notes |
|---|---|---|---|---|---|---|
| 1 KiB | PUT | 4 | 1.80 MiB/s | 1,848 obj/s | 2.2 ms | NVMe metadata-write limited |
| 1 KiB | PUT | 32 | 3.02 MiB/s | 3,092 obj/s | 10.5 ms | Server saturated ~3K RPC/s |
| 1 KiB | GET | 4 | 6.05 MiB/s | 6,196 obj/s | 0.6 ms | Page cache hit |
| 1 KiB | GET | 32 | 42.87 MiB/s | 43,899 obj/s | 0.7 ms | Page cache — 14× faster than PUT |
| 1 MiB | PUT | 32 | 1,064 MiB/s | 1,064 obj/s | 30.1 ms | ~NVMe seq write limit |
| 1 MiB | GET | 32 | 8,067 MiB/s | 8,067 obj/s | 4.0 ms | Page cache — ~RAM bandwidth |
| 64 MiB | PUT | 4 | 1,102 MiB/s | 17 obj/s | 232 ms | Matches FIO seq write |
| 64 MiB | GET | 4 | 8,370 MiB/s | 131 obj/s | 30.6 ms | Page cache ~8 GiB/s |

**Key observations from DMR single-node baselines:**

1. **Small-object PUT** is CPU/metadata bound: server saturates at ~3,000–3,100 obj/s for 1KiB regardless of concurrency above C32.
2. **Small-object GET** scales with concurrency: C32 is 7× faster than C4 for 1KiB (43K vs 6K obj/s), served entirely from 30 GiB page cache.
3. **Large-object PUT** is NVMe write-bound: 1MiB and 64MiB both converge to ~1,100 MiB/s matching the Micron 7450 sustained write rate.
4. **Large-object GET** is RAM-bound: ~8 GiB/s for 64MiB objects — reflects DDR5 bandwidth serving the page cache.
5. Multi-node MinIO with 4–8 NVMe drives would show roughly proportional PUT improvements; GET would scale until network becomes the bottleneck.

---

## Results Interpretation

### Reading WARP Output

```
Report: PUT. Concurrency: 32. Ran: 16s
 * Average: 1063.92 MiB/s, 1063.92 obj/s
 * Reqs: Avg: 30.1ms, 50%: 29.8ms, 90%: 40.6ms, 99%: 54.4ms, Fastest: 6.1ms, Slowest: 81.9ms, StdDev: 8.5ms
```

| Field | Meaning |
|---|---|
| `Average MiB/s` | Sustained throughput across test duration |
| `obj/s` | Object operations per second |
| `Reqs: Avg` | Mean request latency (end-to-end) |
| `50%/90%/99%` | Latency percentiles |
| `TTFB` | Time-to-first-byte (GET only) — network + server processing, before data transfer |

### Concurrency saturation patterns

- **Small objects (< 64 KiB):** PUT saturates around C32 (CPU/metadata bound).
  Increasing concurrency beyond C32 does not increase throughput, only raises latency.
  GET scales further — 30 GiB page cache + fast loopback allows high concurrency.
- **Large objects (≥ 1 MiB):** Throughput is bandwidth-bound.
  C4 is often sufficient to saturate the NVMe/RAM path.
  Higher concurrency is needed on multi-drive setups to aggregate drive bandwidth.

### WARP autoterm behavior

WARP `--autoterm` terminates the benchmark when throughput is stable within 7.5% for ≥ 7 seconds.
This means tests may complete in 10–20 seconds rather than the full `--duration=30s`.
This is expected and produces accurate results. If you need fixed-duration measurements,
drop `--autoterm` and let the full `--duration` elapse.

---

## Single-node vs Multi-node Comparison

This system is a single-node MinIO deployment. The spec "Full System" target implies
a multi-node MinIO cluster. Indicative upgrade expectations:

| Config | PUT (1MiB) | GET (1MiB) | 1KiB PUT obj/s |
|---|---|---|---|
| 1-node, 1×NVMe (this DMR) | ~1,100 MiB/s | ~8,000 MiB/s (cache) | ~3,100 obj/s |
| 1-node, 4×NVMe (JBOD) | ~4,400 MiB/s | ~8,000 MiB/s (cache) | ~3,100 obj/s |
| 4-node, 4×NVMe each (distributed) | ~17,600 MiB/s | ~32,000 MiB/s | ~12,400 obj/s |

> GET throughput in a real deployment exceeds page cache when working set > RAM.
> At that point GET is also NVMe-read bound: 7,000 MB/s per Gen5×4 drive.

---

## MLPerf Subtests (117.113–117.114)

| Subtest | Tool | Requirement |
|---|---|---|
| 117.113 | MLPerf Storage / TF_ObjectStorage (Training) | MinIO cluster + GPU training workload + mlperf_storage Python harness |
| 117.114 | MLPerf Storage / TF_ObjectStorage (Inference) | Same as above + inference pipeline |

**Not eligible on solo single-socket DMR without:**
- Distributed MinIO (≥ 4 nodes × 4 drives each = 16 drives minimum recommended)
- NVIDIA GPU or Intel GPU for training workload
- `mlperf_storage` and TensorFlow installation

**To install mlperf_storage (when hardware is available):**

```bash
pip install mlperf-storage
# See: https://github.com/mlcommons/storage
```

---

## Cleanup

### Stop MinIO Server

```bash
# Find and kill MinIO process
pkill -f "minio server"

# Verify stopped
pgrep -a minio || echo "MinIO stopped"
```

### Remove Benchmark Data

```bash
# Remove test data directory (frees disk space)
rm -rf /data/minio/*

# Remove WARP benchmark data files
rm -f /tmp/warp-*.json.zst

# Remove Go binaries (optional)
rm -f ~/go/bin/minio ~/go/bin/warp
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `Unable to start server: Specified port is already in use` | MinIO is already running: `pgrep -a minio`. Kill if stale: `pkill -f "minio server"` |
| `Unable to connect to server` (WARP) | Check `curl -sf http://localhost:9000/minio/health/live` — if no output, MinIO is down |
| WARP shows no output when piped (`\| grep`) | WARP uses `\r` carriage returns for progress; run without piping. Save to file with `--benchdata` |
| `go: module not found` on install | Ensure network connectivity: `curl -I https://proxy.golang.org` |
| WARP autoterm fires after 3s | Normal — throughput stabilized quickly. Results are still valid |
| GET throughput > PUT throughput by 8× | Expected: GET reads from OS page cache. Real-world: scale out drives or exceed RAM |

---

## Quick Reference — Install Checklist

```bash
# 1. Go installed?
go version   # need ≥ 1.24

# 2. MinIO binary?
~/go/bin/minio --version

# 3. WARP binary?
~/go/bin/warp --version

# 4. Data directory?
ls /data/minio

# 5. MinIO running?
curl -sf http://localhost:9000/minio/health/live && echo "UP"

# 6. Quick smoke test (PUT 1KiB C4, 30s):
~/go/bin/warp put --host=localhost:9000 --access-key=minioadmin \
  --secret-key=minioadmin --no-color --autoterm --duration=30s \
  --obj.size=1KiB --concurrent=4
# Expect: ~1,800 obj/s, ~1.8 MiB/s on single-node DMR
```
