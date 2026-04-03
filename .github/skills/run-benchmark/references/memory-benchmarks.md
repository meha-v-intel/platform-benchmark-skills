# Memory Benchmarks Reference

## Benchmarks Covered
- Memory Latency (multichase pointer-chasing)
- Memory Bandwidth (Intel MLC)
- Memory Latency-Bandwidth Curve (Intel MLC core sweep)

---

## Tool Status on This System

### multichase (for memory latency)
```bash
# Check if available
which multichase || echo "need to install via PKB or standalone build"
# Direct invocation (no PKB needed):
numactl --localalloc multichase -c simple -m 2G -s 512 -t 1
```

### Intel MLC (for bandwidth + latency-BW curve)
```bash
# Check if available
which mlc || ls /root/mlc 2>/dev/null || echo "need to download"
# Download from: https://www.intel.com/content/www/us/en/developer/articles/tool/intelr-memory-latency-checker.html
# Place at /root/mlc or /usr/local/bin/mlc
mlc --version   # expect: Intel Memory Latency Checker v3.12
```

---

## 1. Memory Latency (multichase pointer-chasing)

### Purpose
Measure round-trip DRAM latency via dependent pointer-chasing. Working set ≥ 2 GiB guarantees all accesses go to DRAM (not LLC).

### Prerequisites
```bash
# Enable THP (matches GNR BKM methodology)
echo always > /sys/kernel/mm/transparent_hugepage/enabled
cat /sys/kernel/mm/transparent_hugepage/enabled   # confirm "always"
cpupower frequency-set -g performance
```

### Commands
```bash
# Direct multichase (fastest, no PKB needed)
numactl --localalloc \
    multichase -c simple -m 2G -s 512 -t 1 \
    | tee /tmp/memory_latency.txt
```

### Sweep across working set sizes (matches BKM):
```bash
for size in 256m 512m 1g 2g; do
    echo -n "Working set $size: "
    numactl --localalloc multichase -c simple -m $size -s 512 -t 1 | tail -1
done
```

### Expected Output
```
256m → ~75 ns    (LLC hits)
512m → ~101 ns   (LLC boundary)
1g   → ~111 ns   (DRAM)
2g   → ~116 ns   (steady-state DRAM)   ← use this as the result
```

### Pass Criteria
- 2 GiB result ≤ 139 ns → **PASS**
- **GNR reference**: 116 ns (PKB multichase, THP=always, --localalloc)

---

## 2. Memory Bandwidth (Intel MLC)

### Purpose
Measure peak DRAM all-reads bandwidth. DMR target: ≥ 1454 GBps (full DDR5 spec).

### Commands
```bash
# All access patterns (all-reads is the primary KPI)
mlc --peak_injection_bandwidth 2>/dev/null | tee /tmp/memory_bandwidth.txt
```

### Expected Output Format
```
Intel(R) Memory Latency Checker - v3.12
Measuring Peak Injection Memory Bandwidths for the system
Bandwidths are in MB/sec (1 MB/sec = 1,000,000 Bytes/sec)
Using all the threads from each core if Hyper-threading is enabled
Using traffic with the following read-write ratios
ALL Reads        :      XXXXXXX.X
3:1 Reads-Writes :      XXXXXXX.X
2:1 Reads-Writes :      XXXXXXX.X
1:1 Reads-Writes :      XXXXXXX.X
Stream-triad like:      XXXXXXX.X
```

### Parse Result
```python
import re
text = open('/tmp/memory_bandwidth.txt').read()
m = re.search(r'ALL Reads\s*:\s*([\d.]+)', text)
bw_mbs = float(m.group(1))
bw_gbps = bw_mbs / 1000
print(f"All-reads bandwidth: {bw_gbps:.1f} GBps")
print(f"Pass (≥1454 GBps): {bw_gbps >= 1454}")
```

### Pass Criteria
- All-reads ≥ 1454 GBps → **PASS**
- **GNR reference**: ~158 GB/s per-socket with MLC (GNR 2-socket total higher)

---

## 3. Memory Latency-Bandwidth Curve (MLC core sweep)

### Purpose
Measure latency as bandwidth increases. Pass = latency stays within 15% of idle up to 70% of peak BW. Runtime ~40 min on this 32-core system.

### Commands
```bash
mkdir -p /data/mlc_res && rm -rf /data/mlc_res/*

MLC=/root/mlc   # adjust path if needed
RESULTS=/data/mlc_res
MAX_CORES=32    # all cores on this DMR system (GNR used 199)

echo "Starting MLC lat-BW sweep (MAX_CORES=$MAX_CORES)..."
for i in $(seq 1 $MAX_CORES); do
    cpu_list="1-${i}"

    # Start bandwidth stress
    $MLC --loaded_latency -e -b1g -t50 -T \
         -k"${cpu_list}" -d0 -W2 \
         >> ${RESULTS}/bw_mlc_${i}.log 2>&1 &
    bw_pid=$!

    sleep 20  # let BW load stabilize

    # Measure idle latency on core 0
    $MLC --idle_latency -b2g -c0 -r -t20 \
         > ${RESULTS}/latency_mlc_${i}.log

    lat=$(grep -i frequency ${RESULTS}/latency_mlc_${i}.log | awk '{print $NF}')
    wait $bw_pid
    bw=$(grep -E '^[0-9]+\s+[0-9]+' ${RESULTS}/bw_mlc_${i}.log | tail -1 | awk '{print $3}')

    echo "$i $bw $lat" >> ${RESULTS}/lat_bw.data
    echo "cores=$i  BW=${bw}MB/s  LAT=${lat}ns"
done
echo "Done. Results: ${RESULTS}/lat_bw.data"
```

### Parse and Evaluate
```python
import re

data = []
for line in open('/data/mlc_res/lat_bw.data'):
    parts = line.split()
    if len(parts) == 3:
        try:
            data.append((int(parts[0]), float(parts[1]), float(parts[2])))
        except ValueError:
            continue

idle_lat = data[0][2]   # latency at 1 loaded core ≈ idle latency
peak_bw  = max(r[1] for r in data) / 1000   # GBps
target_bw = peak_bw * 0.70

# Find latency at 70% BW
at_70pct = [(bw/1000, lat) for _, bw, lat in data if bw/1000 <= target_bw]
lat_at_70 = at_70pct[-1][1] if at_70pct else idle_lat

pct_increase = (lat_at_70 - idle_lat) / idle_lat * 100
passed = pct_increase <= 15

print(f"Peak BW: {peak_bw:.1f} GBps")
print(f"Idle latency: {idle_lat:.0f} ns")
print(f"Latency at 70% BW ({target_bw:.0f} GBps): {lat_at_70:.0f} ns (+{pct_increase:.1f}%)")
print(f"Pass (≤15% increase): {passed}")
```

### GNR Reference
- Peak BW: ~158 GB/s (per-socket MLC)
- Idle latency: ~126 ns
- Latency at 70% BW: ~162 ns (+28.6% — GNR **fails** this criterion)
- DMR expected to show flatter curve

---

## Reporting Format

```
MEMORY BENCHMARK RESULTS
========================
Memory Latency      : PASS  — 2GiB: XXX ns (threshold: ≤139 ns, GNR: 116 ns, delta: +X.X%)
Memory Bandwidth    : PASS  — All-reads: XXXX GBps (threshold: ≥1454 GBps, GNR: 158 GB/s/socket)
Mem Lat-BW Curve    : PASS  — Peak: XXXX GBps, idle lat: XXX ns,
                               lat@70%BW: XXX ns (+X.X% increase, threshold: ≤15%)
```
