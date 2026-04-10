---
name: benchmark-hft
description: "Run Intel FSI HFT (High-Frequency Trading) benchmarks. Use when: measuring packet processing latency, running hft_rdtscp tests, testing thread-to-thread transfer latency, measuring network ping-pong latency, validating Solarflare ef_vi UDP latency, measuring TCP round-trip time with Onload kernel bypass, running eflatency, running sfnt-pingpong, measuring ½ RTT, validating HFT network stack, CTPIO cut-through latency, STAC-N1 sweep, HFT jitter."
argument-hint: "[compute|network|all]"
allowed-tools: Bash
---

# FSI HFT Benchmarks

Runs simulated HFT packet processing (single-node) and network ping-pong latency (two-node topology).  
Argument: `$ARGUMENTS` — `compute`, `network`, or `all` (default).

---

## CRITICAL: HFT Prerequisites

Before any HFT test, confirm all of the following. These are hard gates — do not proceed if any fail.

```bash
# Output directory — persistent; never /tmp/
OUTDIR=${BENCHMARK_OUTDIR:-/datafs/fsi-benchmarks}/$(date +%Y%m%dT%H%M)-hft
mkdir -p $OUTDIR/{bench/hft_compute,bench/hft_network,emon,monitor,sysconfig}
lscpu                        > $OUTDIR/sysconfig/cpu_info.txt
numactl --hardware           > $OUTDIR/sysconfig/numa_topology.txt
dmidecode -t 17 2>/dev/null  > $OUTDIR/sysconfig/dimm_info.txt
cpupower frequency-info      > $OUTDIR/sysconfig/cpupower.txt 2>&1
echo "Output dir: $OUTDIR"

# 1. SMI count must be zero
SMI_BEFORE=$(sudo rdmsr -a 0x34 2>/dev/null | head -1)
sleep 10
SMI_AFTER=$(sudo rdmsr -a 0x34 2>/dev/null | head -1)
echo "SMI delta: $((16#$SMI_AFTER - 16#$SMI_BEFORE))"   # Must be 0

# 2. CPU governor = performance
cpupower frequency-info | grep "The governor"   # expect: performance

# 3. isolcpus active (verify GRUB applied)
cat /proc/cmdline | grep isolcpus   # expect: isolcpus=1-<MAXCORE>

# 4. IOMMU disabled
cat /proc/cmdline | grep iommu   # expect: iommu=off intel_iommu=off

# 5. nohz active
cat /proc/cmdline | grep nohz   # expect: nohz=off

# 6. irqbalance stopped
systemctl is-active irqbalance   # expect: inactive

# 7. NIC baseline stats — saved to file for post-run delta comparison
IFACE=$(ip -o link show | awk -F': ' '!/lo/{print $2; exit}')
ethtool -S $IFACE 2>/dev/null | grep -E "rx.*drop|tx.*drop|missed|error" \
    | tee $OUTDIR/monitor/nic_baseline.txt \
    || echo "ethtool -S: unavailable for $IFACE"
```

If SMI delta > 0: **STOP**. Report as HFT-BLOCK. Recommend: disable patrol scrubbing in BIOS (`Socket Configuration → Memory Configuration → Patrol Scrub → Disable`) and runtime RAS SMIs.

---

## Part A — Simulated HFT Packet Processing (Single Node)

Tests thread-to-thread packet transfer latency after NIC RX. No network hardware required.

**Reference scripts:** https://github.com/intel-sandbox/financial-samples/tree/main/HFT

### Setup

```bash
# Build hft_rdtscp (if not already built)
ls ./hft_rdtscp 2>/dev/null || {
    git clone https://github.com/intel-sandbox/financial-samples.git
    cd financial-samples/HFT && make
    cp hft_rdtscp ~/
}

# Enable hugepages
echo 2048 > /proc/sys/vm/nr_hugepages
grep HugePages_Total /proc/meminfo   # expect: ≥ 2048

# Confirm highest core number
MAXCORE=$(nproc --all); echo "Max core: $((MAXCORE - 1))"
XYZ=$((MAXCORE - 1))
```

### Test A1 — hft_rdtscp 1r1w (1 reader, 1 writer)

Measures baseline single-thread latency.

```bash
RESULTS_DIR=$OUTDIR/bench/hft_compute
mkdir -p $RESULTS_DIR

# Start turbostat to monitor frequency stability during compute tests
turbostat --interval 1 --show Avg_MHz,Bzy_MHz,Busy%,PkgWatt \
    > $RESULTS_DIR/turbostat_hft.txt 2>/dev/null &
TURBO_PID=$!

# Continuous SMI monitor — detect any SMIs that occur during test (not just baseline)
SMI_START=$(rdmsr -a 0x34 2>/dev/null | head -1)

echo "=== hft_rdtscp 1r1w — 5 runs ===" | tee $RESULTS_DIR/hft_1r1w.log
for run in 1 2 3 4 5; do
    echo -n "Run $run: "
    ./hft_rdtscp -h hugepages -b -l 10 -s 64 -i 0,2-${XYZ} -w 2 2>&1 | tail -1 | tee -a $RESULTS_DIR/hft_1r1w.log
done
```

Parse mean and std-dev across 5 runs. Report format: `avg XXX ns ± XX ns`.

### Test A2 — hft_rdtscp 24r1w (24 readers, 1 writer)

Measures latency under reader contention.

```bash
echo "=== hft_rdtscp 24r1w — 5 runs ===" | tee $RESULTS_DIR/hft_24r1w.log
for run in 1 2 3 4 5; do
    echo -n "Run $run: "
    ./hft_rdtscp -h hugepages -b -l 10 -s 64 -i 0,25-${XYZ} -w 25 2>&1 | tail -1 | tee -a $RESULTS_DIR/hft_24r1w.log
done
```

### Test A3 — hft_rdtscp 24r3w (24 readers, 3 writers)

Measures latency under combined reader and writer contention.

```bash
echo "=== hft_rdtscp 24r3w — 5 runs ===" | tee $RESULTS_DIR/hft_24r3w.log
for run in 1 2 3 4 5; do
    echo -n "Run $run: "
    ./hft_rdtscp -h hugepages -b -l 10 -s 64 -i 0,25-${XYZ} -w 25-27 2>&1 | tail -1 | tee -a $RESULTS_DIR/hft_24r3w.log
done
```

### Compute Results Parsing

```bash
# Stop turbostat and SMI monitors after all compute tests complete
kill $TURBO_PID 2>/dev/null; wait $TURBO_PID 2>/dev/null || true

# SMI delta during entire compute test window
SMI_END=$(rdmsr -a 0x34 2>/dev/null | head -1)
SMI_DURING=$((16#${SMI_END:-0} - 16#${SMI_START:-0}))
[ "$SMI_DURING" -gt 0 ] && echo "WARN: $SMI_DURING SMI(s) occurred during hft_rdtscp tests" \
    || echo "SMI during test: 0 (clean)"

# Frequency stability check
awk 'NR>1 && $2~/[0-9]/{if($2>mx)mx=$2; if(mn==0||$2<mn)mn=$2} \
     END{if(mx>0) printf "Freq during test: min=%.0f max=%.0f MHz — %s\n", mn, mx, \
         (mx-mn)/mx>0.05 ? "WARN: >5% droop (possible power/thermal throttle)" : "stable"}' \
    $RESULTS_DIR/turbostat_hft.txt 2>/dev/null || true

# NIC drop check — compare to baseline captured in prerequisites
IFACE=$(ip -o link show | awk -F': ' '!/lo/{print $2; exit}')
echo "--- NIC stats delta (drops since baseline) ---"
ethtool -S $IFACE 2>/dev/null | grep -E "rx.*drop|tx.*drop|missed|error" \
    | tee $OUTDIR/monitor/nic_post.txt || true
diff $OUTDIR/monitor/nic_baseline.txt $OUTDIR/monitor/nic_post.txt 2>/dev/null \
    | grep '^[<>]' | awk '{print "  NIC delta:", $0}' \
    || echo "  NIC delta: baseline unavailable"

# Extract avg ± std for each test
for test in 1r1w 24r1w 24r3w; do
    echo -n "hft_rdtscp $test: "
    awk '{sum+=$1; sumsq+=$1^2; n++} END {
        avg=sum/n; std=sqrt(sumsq/n - avg^2);
        printf "avg %.1f ns ± %.1f ns (n=%d)\n", avg, std, n
    }' $RESULTS_DIR/hft_${test}.log
done
```

**Pass/Fail:** Compare against LZ KPI rows 3 (LLC hit variability) and row 6 (single-thread per-core perf).  
Latency degradation from 1r1w → 24r3w exceeding 3× suggests LLC thrashing or NUMA migration — trigger Tier-2 profiling.

---

## Part B — Network Latency (Requires Two Solarflare Systems)

**Topology check:**

```bash
# Required env vars
: "${PING_HOST:?Set PING_HOST=<ping system IP or alias>}"
: "${PONG_HOST:?Set PONG_HOST=<pong system IP or alias>}"
: "${PING_IFACE:?Set PING_IFACE=<NIC interface on ping system>}"
: "${PONG_IFACE:?Set PONG_IFACE=<NIC interface on pong system>}"

# Verify Solarflare NIC
lspci | grep -qi "solarflare\|xilinx" || { echo "SKIP: Solarflare NIC not found"; exit 0; }

# Verify Onload loaded
ls /dev/onload 2>/dev/null || { echo "WARN: Onload not loaded — run: modprobe onload"; }

# Verify link
ethtool $PING_IFACE | grep -E "Speed|Link detected"
ssh $PONG_HOST ethtool $PONG_IFACE | grep -E "Speed|Link detected"
```

Set variables before running. If either system is unreachable or NIC absent, skip with `SKIPPED — topology not available`.

**Reference scripts:** https://github.com/intel-sandbox/applications.benchmarking.financial-services/tree/main/network_latency  
See README.md → "Tests For Segment Validation" section for full setup.

### Test B1 — UDP Latency and Jitter (eflatency, ef_vi CTPIO cut-through)

Measures 99th percentile ½ RTT for UDP, payload sizes 0–1584 bytes.

```bash
NET_DIR=$OUTDIR/bench/hft_network
mkdir -p $NET_DIR

# Start pong side (run on PONG_HOST via SSH in background)
ssh $PONG_HOST "cd ~/financial-services/network_latency && \
    sudo EF_CTPIO=1 EF_CTPIO_MODE=cut-through \
    eflatency --server --interface $PONG_IFACE --port 9000" &

sleep 2

# Run ping side (5 runs per the test plan)
echo "=== eflatency UDP CTPIO cut-through — 5 runs ===" | tee $NET_DIR/eflatency.log
for run in 1 2 3 4 5; do
    echo "--- Run $run ---" | tee -a $NET_DIR/eflatency.log
    sudo EF_CTPIO=1 EF_CTPIO_MODE=cut-through \
        eflatency --client $PONG_HOST --interface $PING_IFACE \
        --port 9000 --size 0,64,1584 --percentile 99 \
        2>&1 | tee -a $NET_DIR/eflatency.log
    sleep 1
done
```

Parse: 99th percentile ½ RTT per payload size. Calculate avg ± std-dev across 5 runs.

### Test B2 — TCP Latency and Jitter (sfnt-pingpong, Onload CTPIO cut-through)

Measures 99th percentile ½ RTT for TCP, payload sizes 1–65536 bytes.

```bash
# Start pong side
ssh $PONG_HOST "cd ~/financial-services/network_latency && \
    sudo onload --profile=latency \
    sfnt-pingpong --server tcp $PONG_IFACE 9001" &

sleep 2

echo "=== sfnt-pingpong TCP Onload — 5 runs ===" | tee $NET_DIR/sfnt_pingpong.log
for run in 1 2 3 4 5; do
    echo "--- Run $run ---" | tee -a $NET_DIR/sfnt_pingpong.log
    sudo onload --profile=latency \
        sfnt-pingpong --client tcp $PONG_HOST:9001 \
        --sizes 1,64,1024,8192,65536 --percentile 99 \
        2>&1 | tee -a $NET_DIR/sfnt_pingpong.log
    sleep 1
done
```

### Test B3 — UDP Latency Across Throughput Levels (STAC-N1)

Tests 66-byte UDP ef_vi across 100K–1M msgs/sec (100K increments).

```bash
# BKM: https://github.com/shui1/stac-n-test-harness.mirror/blob/ef-vi-segval/README.md
# The test automatically performs 5 runs per throughput level

echo "=== STAC-N1 UDP throughput sweep ===" | tee $NET_DIR/stac_n1.log
# Run per BKM instructions — script handles 5 runs automatically
sudo ./run_stac_n1.sh \
    --interface $PING_IFACE \
    --remote $PONG_HOST \
    --msg-rates 100000,200000,300000,400000,500000,600000,700000,800000,900000,1000000 \
    --size 66 \
    2>&1 | tee -a $NET_DIR/stac_n1.log

# Calculate average and std-dev per throughput level from the 5 automatic runs
echo "Parsing STAC-N1 results..."
awk '/msg_rate|p99_halfRTT/' $NET_DIR/stac_n1.log
```

**Pass criteria:** Latency remains stable (< 5% variance) across all throughput levels. Jitter at 1M msgs/sec should not exceed ×3 the 100K msgs/sec baseline.

---

## HFT Report Format

```
HFT BENCHMARK RESULTS — <PLATFORM> — <TIMESTAMP>
=================================================
Prerequisites
  SMI gate         : PASS — 0 SMIs (10s window)    [or FAIL — N SMIs DETECTED]
  CPU governor     : PASS — performance
  isolcpus active  : PASS — isolcpus=1-<N>
  IOMMU disabled   : PASS — iommu=off

HFT COMPUTE (single-node, hft_rdtscp)
  1r1w             : PASS — avg XXX ns ± X.X ns (5 runs)
  24r1w            : PASS — avg XXX ns ± X.X ns
  24r3w            : PASS — avg XXX ns ± X.X ns
  Latency ratio 24r3w/1r1w: X.Xx  [flag if > 3×]

HFT NETWORK (two-node, Solarflare)      [or: SKIPPED — topology not available]
  eflatency UDP 64B 99%    : PASS — XXX ns ½RTT (avg 5 runs)
  sfnt-pingpong TCP 64B 99%: PASS — XXX ns ½RTT (avg 5 runs)
  STAC-N1 100K msgs/sec    : PASS — XXX ns ½RTT
  STAC-N1 1M msgs/sec      : PASS — XXX ns ½RTT (variance: X.X%)

LZ KPI STATUS (see references/lz-kpis.md for full table)
  Row 1 PCIe Idle Read Latency : [not directly measured — see sysconfig BIOS notes]
  Row 3 LLC Hit Variability    : PASS/FAIL — derived from 1r1w vs 24r3w spread
  Row 6 Single-thread Perf     : PASS/FAIL — vs GNR reference run

TUNING RECOMMENDATIONS: [none | Tier-1 items listed | Tier-2 profiling needed]
```

---

## Tier-1 Tuning (HFT-Specific)

Triggered automatically when a test misses its threshold:

| Symptom | Root Cause | Fix |
|---|---|---|
| SMI > 0 | Memory patrol scrub, IPMI polling, runtime RAS | Disable patrol scrub; disable memory RAS SMIs in BIOS |
| hft_rdtscp latency high variance (> ±20% std) | C-state transitions during test | Verify `nohz=off` in GRUB; confirm `isolcpus` covers test cores |
| 24r3w latency > 3× 1r1w | LLC thrashing from 24 readers | Reduce reader core count; verify all cores are in same SNC cluster |
| eflatency latency elevated | CTPIO not in cut-through mode | Set `EF_CTPIO_MODE=cut-through`; verify Onload version ≥ 9.1 |
| High TCP latency vs UDP | Onload not active | Run with `onload --profile=latency`; check `onload_stackdump apps` |
| Latency spikes at high msg rate (STAC-N1) | NIC ring buffer overflow | `ethtool -G $IFACE rx 4096 tx 4096`; check `ethtool -S $IFACE \| grep drop` |
| Cross-core latency high (24r tests) | Threads crossing SNC boundary | Pin writer to core 0; pin readers to cores within same NUMA node |

## Mandatory Reports

After every HFT run, write `deep_dive_report.md` and `tuning_recommendations.md` to `$OUTDIR/`. Follow the template in [run-benchmark/SKILL.md](../run-benchmark/SKILL.md#mandatory-reports).

The **Monitoring Telemetry** section of the deep dive must include:

| File | Monitoring tool | Metrics |
|---|---|---|
| `$OUTDIR/sysconfig/cpu_info.txt` | lscpu | CPU model, ISA, LLC size |
| `$OUTDIR/sysconfig/cpupower.txt` | cpupower | Governor, boost, HWP state |
| `$OUTDIR/sysconfig/dimm_info.txt` | dmidecode -t 17 | DIMM population and speed |
| `$OUTDIR/monitor/nic_baseline.txt` | ethtool -S | NIC TX/RX drop counters before test |
| `$OUTDIR/monitor/nic_post.txt` | ethtool -S | NIC TX/RX drop counters after test (delta = drops during test) |
| `$OUTDIR/bench/hft_compute/turbostat_hft.txt` | turbostat | Freq (MHz), PkgWatt during hft_rdtscp tests |
| `$OUTDIR/bench/hft_compute/hft_1r1w.log` | hft_rdtscp | 1-reader 1-writer latency (ns) × 5 runs |
| `$OUTDIR/bench/hft_compute/hft_24r1w.log` | hft_rdtscp | 24-reader 1-writer latency (ns) × 5 runs |
| `$OUTDIR/bench/hft_compute/hft_24r3w.log` | hft_rdtscp | 24-reader 3-writer latency (ns) × 5 runs |
| `$OUTDIR/bench/hft_network/eflatency.log` | eflatency | UDP 99th% ½RTT per payload size × 5 runs |
| `$OUTDIR/bench/hft_network/sfnt_pingpong.log` | sfnt-pingpong | TCP 99th% ½RTT per payload size × 5 runs |
| `$OUTDIR/bench/hft_network/stac_n1.log` | STAC-N1 | UDP latency vs throughput sweep |
