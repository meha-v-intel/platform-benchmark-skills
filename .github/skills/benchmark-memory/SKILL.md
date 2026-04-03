---
name: benchmark-memory
description: "Run DMR memory micro-benchmarks: memory latency via pointer-chasing (multichase), memory bandwidth via PKB multichase multiload, memory latency-bandwidth curve via MLC. Use when: measuring DRAM latency, measuring memory bandwidth, running MLC, checking memory subsystem performance, latency-bandwidth curve."
argument-hint: "[latency|bandwidth|latency-bw-curve|all]"
allowed-tools: Bash
---

# DMR Memory Benchmarks

Runs memory latency (multichase), memory bandwidth (MLC), and latency-BW curve (MLC sweep).
Argument: `$ARGUMENTS` — `latency`, `bandwidth`, `latency-bw-curve`, or `all` (default).

## Prerequisites
```bash
# Check tools
which multichase || echo "multichase needed — build via PKB or standalone"
which mlc || ls /root/mlc 2>/dev/null || echo "MLC needed — download from Intel"
# THP and governor
echo always > /sys/kernel/mm/transparent_hugepage/enabled
cpupower frequency-set -g performance
```

## 1. Memory Latency (~2 min)
```bash
# Sweep working set sizes to confirm DRAM is reached
for size in 256m 512m 1g 2g; do
    echo -n "WS=$size: "
    numactl --localalloc multichase -c simple -m $size -s 512 -t 1 | tail -1
done
```
Use 2g result. Pass ≤ 139 ns. GNR: 116 ns.

## 2. Memory Bandwidth (~3 min)
**BKM tool: PerfKitBenchmarker (PKB) multichase multiload.** The BKM does not provide a standalone command — run via PKB with `multichase_benchmarks: multiload` and varying `multiload_thread_count` (1, 8, 16, 32). See `MEMORY_BANDWIDTH_PKB_BKM_NEW_BIOS.txt` for the full YAML config.

GNR reference: 1T→16.3 GB/s, 8T→92.7 GB/s, 16T→110.7 GB/s. Full-system (480T GNR): 872 GB/s.

## 3. Memory Latency-BW Curve (~40 min)
**BKM script**: `scripts/run_mlc_lat_bw.sh` (set `MAX_CORES=32` and `MLC` path for this system before running)

```bash
# Run sweep script (MAX_CORES=32 for this system)
MLC=${MLC:-/root/mlc}
mkdir -p /data/mlc_res && rm -rf /data/mlc_res/*
for i in $(seq 1 32); do
    numactl -m 0 $MLC --loaded_latency -e -b1g -t50 -T -k"1-${i}" -d0 -W2 \
         >> /data/mlc_res/bw_mlc_${i}.log 2>&1 &
    sleep 20
    numactl -m 0 $MLC --idle_latency -b2g -c0 -r -t20 > /data/mlc_res/lat_mlc_${i}.log
    lat=$(grep frequency /data/mlc_res/lat_mlc_${i}.log | awk '{print $9}')
    wait
    bw=$(grep -E '^[0-9]+\s+[0-9]+' /data/mlc_res/bw_mlc_${i}.log | tail -1 | awk '{print $3}')
    echo "$i $bw $lat" >> /data/mlc_res/lat_bw.data
    echo "cores=$i BW=${bw}MB/s LAT=${lat}ns"
done
```
Pass: latency increase ≤ 15% at 70% of peak BW. GNR: +28.6% (failed). DMR expected flatter.

## Report Format
```
MEMORY BENCHMARK RESULTS
========================
Memory Latency   : PASS  — 2GiB: XXX ns (threshold: ≤139 ns, GNR: 116 ns, delta: ±X%)
Memory Bandwidth : PASS  — All-reads: XXXX GBps (threshold: ≥1454 GBps, GNR: 158 GB/s/socket)
Lat-BW Curve     : PASS  — Peak XXXX GBps, idle XXX ns, @70%BW: XXX ns (+X.X%, ≤15%)
```
