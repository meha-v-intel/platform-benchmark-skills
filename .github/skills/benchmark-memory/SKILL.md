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

# Output directory — persistent; never /tmp/
OUTDIR=${BENCHMARK_OUTDIR:-/datafs/benchmarks}/$(date +%Y%m%dT%H%M)-memory
mkdir -p $OUTDIR/{bench/mlc,emon,monitor,sysconfig}
lscpu                        > $OUTDIR/sysconfig/cpu_info.txt
numactl --hardware           > $OUTDIR/sysconfig/numa_topology.txt
dmidecode -t 17 2>/dev/null  > $OUTDIR/sysconfig/dimm_info.txt
cpupower frequency-info      > $OUTDIR/sysconfig/cpupower.txt 2>&1
echo "Output dir: $OUTDIR"

# DIMM presence and spec verification
dmidecode -t 17 2>/dev/null \
    | grep -E "Size|Type:|Speed:|Configured Memory Speed|Bank Locator|Part Number" \
    | grep -v "No Module" \
    || echo "dmidecode: unavailable — cannot verify DIMM population"

# NUMA remote-access baseline (expect all zeros before test)
numastat -c 2>/dev/null || numastat 2>/dev/null | head -20
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
mkdir -p $OUTDIR/bench/mlc && rm -rf $OUTDIR/bench/mlc/*

# Start perf stat to capture LLC/TLB miss rates across the entire sweep
perf stat -a \
    -e LLC-loads,LLC-load-misses,dTLB-loads,dTLB-load-misses,\
L1-dcache-loads,L1-dcache-load-misses \
    --interval-print 10000 \
    -o $OUTDIR/emon/perf_stat.txt \
    -- sleep 9999 2>/dev/null &
PERF_PID=$!

for i in $(seq 1 32); do
    numactl -m 0 $MLC --loaded_latency -e -b1g -t50 -T -k"1-${i}" -d0 -W2 \
         >> $OUTDIR/bench/mlc/bw_mlc_${i}.log 2>&1 &
    sleep 20
    numactl -m 0 $MLC --idle_latency -b2g -c0 -r -t20 > $OUTDIR/bench/mlc/lat_mlc_${i}.log
    lat=$(grep frequency $OUTDIR/bench/mlc/lat_mlc_${i}.log | awk '{print $9}')
    wait
    bw=$(grep -E '^[0-9]+\s+[0-9]+' $OUTDIR/bench/mlc/bw_mlc_${i}.log | tail -1 | awk '{print $3}')
    echo "$i $bw $lat" >> $OUTDIR/bench/mlc/lat_bw.data
    echo "cores=$i BW=${bw}MB/s LAT=${lat}ns"
done

kill $PERF_PID 2>/dev/null; wait $PERF_PID 2>/dev/null || true

# RAPL DRAM energy (memory subsystem power efficiency)
perf stat -a -e power/energy-dram/ -- sleep 5 2>&1 | grep energy-dram \
    || echo "RAPL DRAM energy: unavailable"

# NUMA remote-access delta (should be near zero with --localalloc)
echo "--- NUMA remote access post-sweep ---"
numastat -c 2>/dev/null || numastat 2>/dev/null | head -20
```
Pass: latency increase ≤ 15% at 70% of peak BW. GNR: +28.6% (failed). DMR expected flatter.
Flag if `numastat` shows significant remote node hits — indicates NUMA binding issue.

## Mandatory Reports

After every memory benchmark run, write `deep_dive_report.md` and `tuning_recommendations.md` to `$OUTDIR/`. Follow the template in [run-benchmark/SKILL.md](../run-benchmark/SKILL.md#mandatory-reports).

The **Monitoring Telemetry** section of the deep dive must include:

| File | Monitoring tool | Metrics |
|---|---|---|
| `$OUTDIR/sysconfig/cpu_info.txt` | lscpu | CPU model, LLC size |
| `$OUTDIR/sysconfig/dimm_info.txt` | dmidecode -t 17 | DIMM speed and population |
| `$OUTDIR/sysconfig/cpupower.txt` | cpupower | Governor, boost |
| `$OUTDIR/emon/perf_stat.txt` | perf stat | LLC miss rate, dTLB misses, L1D miss rate across sweep |
| `$OUTDIR/monitor/numastat_pre.txt` | numastat | NUMA remote accesses before test |
| `$OUTDIR/monitor/numastat_post.txt` | numastat | NUMA remote accesses after test (delta expected = 0) |
| `$OUTDIR/bench/mlc/lat_bw.data` | MLC | Latency (ns) vs bandwidth (MB/s) per core count |
| `$OUTDIR/bench/mlc/lat_mlc_N.log` | MLC --idle_latency | DRAM latency at N active cores |
| `$OUTDIR/bench/mlc/bw_mlc_N.log` | MLC --loaded_latency | Memory bandwidth at N active cores |

## Report Format
```
MEMORY BENCHMARK RESULTS
========================
DIMM Config      : N × DDR5-XXXXX (dmidecode -t 17)
Memory Latency   : PASS  — 2GiB: XXX ns (threshold: ≤139 ns, GNR: 116 ns, delta: ±X%)
Memory Bandwidth : PASS  — All-reads: XXXX GBps (threshold: ≥1454 GBps, GNR: 158 GB/s/socket)
Lat-BW Curve     : PASS  — Peak XXXX GBps, idle XXX ns, @70%BW: XXX ns (+X.X%, ≤15%)
LLC Miss Rate    : X.X%  (perf stat — high rate suggests working set > LLC)
DRAM Energy      : X.X J / 5s  (RAPL power/energy-dram)
NUMA Remote Hits : N  (expect 0 — non-zero means binding misconfiguration)
```
