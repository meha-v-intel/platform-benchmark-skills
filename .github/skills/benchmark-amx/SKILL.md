---
name: benchmark-amx
description: "Run DMR AMX performance benchmark using oneDNN benchdnn. Use when: measuring AMX throughput, benchmarking BF16 TFLOPS, INT8 TOPS, testing matrix multiply performance, validating AMX tiles, AI inference baseline."
argument-hint: "[iso-core|full-system|all]"
allowed-tools: Bash
---

# DMR AMX Performance Benchmark

Measures Intel AMX BF16 and INT8 throughput via oneDNN benchdnn convolution operator.
Argument: `iso-core` (8C, matches GNR BKM), `full-system` (all 32C), or `all` (default: both).

## Find / Build benchdnn
```bash
BENCHDNN=$(find /root -name benchdnn -type f 2>/dev/null | head -1)
if [ -z "$BENCHDNN" ]; then
    echo "Building oneDNN..."
    dnf install -y cmake gcc-c++ git
    cd /root && git clone --depth 1 https://github.com/oneapi-src/oneDNN.git
    mkdir -p oneDNN/build && cd oneDNN/build
    cmake .. -DCMAKE_BUILD_TYPE=Release -DDNNL_CPU_RUNTIME=OMP
    make -j$(nproc) benchdnn
    BENCHDNN=/root/oneDNN/build/tests/benchdnn/benchdnn
fi
export LD_LIBRARY_PATH=$(dirname $BENCHDNN)/../../src:$LD_LIBRARY_PATH
echo "benchdnn: $BENCHDNN"
```

## Step 2 — Confirm NUMA topology and baseline power state
```bash
numactl --hardware

# Turbostat idle snapshot — confirm frequency scaling active and establish power baseline
which turbostat 2>/dev/null || dnf install -y kernel-tools
turbostat --interval 2 --num_iterations 1 --Summary 2>/dev/null \
    | grep -E "Avg_MHz|Bzy_MHz|Busy%|PkgWatt|Pkg%pc6" \
    || echo "turbostat: unavailable — install kernel-tools"
```
Iso-core CPUs selected from NUMA node 0. On GNR BKM: `ISO_CORES=0,2,4,6,8,10,12,14`

## Environment
```bash
export DNNL_MAX_CPU_ISA=AMX
export KMP_BLOCKTIME=0
export OMP_PROC_BIND=close
export OMP_PLACES=cores

# Output directory — persistent; never /tmp/
OUTDIR=${BENCHMARK_OUTDIR:-/datafs/benchmarks}/$(date +%Y%m%dT%H%M)-amx
mkdir -p $OUTDIR/{bench,emon,monitor,sysconfig}
lscpu                        > $OUTDIR/sysconfig/cpu_info.txt
numactl --hardware           > $OUTDIR/sysconfig/numa_topology.txt
dmidecode -t 17 2>/dev/null  > $OUTDIR/sysconfig/dimm_info.txt
cpupower frequency-info      > $OUTDIR/sysconfig/cpupower.txt 2>&1
rdmsr -a 0x34 2>/dev/null    > $OUTDIR/sysconfig/smi_baseline.txt
echo "Output dir: $OUTDIR"
```

## Iso-core test (8 cores — comparable to GNR BKM)
```bash
ISO_CORES=0,1,2,3,4,5,6,7
export OMP_NUM_THREADS=8

# Start turbostat and RAPL monitors in background — span both BF16 and INT8 runs
turbostat --interval 1 --show Avg_MHz,Bzy_MHz,Busy%,PkgWatt,CorWatt,CoreTmp \
    > $OUTDIR/monitor/turbostat.txt 2>/dev/null &
TURBO_PID=$!

# RAPL energy — package + core counters
perf stat -a -e power/energy-pkg/,power/energy-cores/ \
    -o $OUTDIR/monitor/rapl.txt \
    -- sleep 9999 2>/dev/null &
RAPL_PID=$!

echo "=== BF16 iso-core ==="
numactl --physcpubind=$ISO_CORES --membind=0 \
    $BENCHDNN --mode=P --conv --dt=bf16 \
    ic128oc128ih56oh56kh3ph1n32 2>/dev/null | tee $OUTDIR/bench/amx_bf16_iso.txt

echo "=== INT8 iso-core ==="
numactl --physcpubind=$ISO_CORES --membind=0 \
    $BENCHDNN --mode=P --conv --dt=s8 \
    ic128oc128ih56oh56kh3ph1n32 2>/dev/null | tee $OUTDIR/bench/amx_int8_iso.txt

kill $TURBO_PID $RAPL_PID 2>/dev/null; wait $TURBO_PID $RAPL_PID 2>/dev/null || true

# Verify AMX instructions actually executed (not VNNI fallback)
perf stat -a --no-big-num \
    -e fp_arith_inst_retired.512b_packed_bf16,fp_arith_inst_retired.1024b_packed_bf16,\
amx_tile_retired.tilezero,amx_tile_retired.tilelconfig \
    -- numactl --physcpubind=$ISO_CORES --membind=0 \
       $BENCHDNN --mode=P --conv --dt=bf16 \
       ic128oc128ih56oh56kh3ph1n32 2>&1 | tee $OUTDIR/emon/amx_perf_verify.txt \
    || echo "AMX perf events: unavailable on this kernel"
```

## Iso-core 30% utilization test (OMP_NUM_THREADS=2 — BKM steps 5–6)
```bash
export OMP_NUM_THREADS=2

echo "=== BF16 iso-core 30% ==="
numactl --physcpubind=$ISO_CORES --membind=0 \
    $BENCHDNN --mode=P --conv --dt=bf16 \
    ic128oc128ih56oh56kh3ph1n32 2>/dev/null | tee $OUTDIR/bench/amx_bf16_iso_30pct.txt

echo "=== INT8 iso-core 30% ==="
numactl --physcpubind=$ISO_CORES --membind=0 \
    $BENCHDNN --mode=P --conv --dt=s8 \
    ic128oc128ih56oh56kh3ph1n32 2>/dev/null | tee $OUTDIR/bench/amx_int8_iso_30pct.txt
```
GNR reference: BF16 ~4.2 TFLOPS, INT8 ~8.1 TOPS

## Full-system test (32 cores — BKM steps 7–8)
```bash
export OMP_NUM_THREADS=32
export OMP_PROC_BIND=spread

echo "=== BF16 full-system ==="
numactl --interleave=all \
    $BENCHDNN --mode=P --conv --dt=bf16 \
    ic256oc256ih56oh56kh3ph1n64 2>/dev/null | tee $OUTDIR/bench/amx_bf16_full.txt

echo "=== INT8 full-system ==="
numactl --interleave=all \
    $BENCHDNN --mode=P --conv --dt=s8 \
    ic256oc256ih56oh56kh3ph1n64 2>/dev/null | tee $OUTDIR/bench/amx_int8_full.txt
```

## Parse and Report
```python
import re, sys, subprocess, os

outdir = sys.argv[1] if len(sys.argv) > 1 else os.environ.get('OUTDIR', '/datafs/benchmarks/amx_latest')

def parse_gflops(path):
    try:
        text = open(path).read()
        m = re.search(r'(\d+\.?\d*)\s*GFLOPS', text, re.IGNORECASE)
        return float(m.group(1)) if m else None
    except FileNotFoundError:
        return None

def parse_rapl(path):
    """Extract Joules from perf stat RAPL output."""
    try:
        text = open(path).read()
        m = re.search(r'([\d,.]+)\s+Joules\s+power/energy-pkg/', text)
        return float(m.group(1).replace(',','')) if m else None
    except FileNotFoundError:
        return None

bf16_iso  = parse_gflops(f'{outdir}/bench/amx_bf16_iso.txt')
int8_iso  = parse_gflops(f'{outdir}/bench/amx_int8_iso.txt')
bf16_full = parse_gflops(f'{outdir}/bench/amx_bf16_full.txt')
int8_full = parse_gflops(f'{outdir}/bench/amx_int8_full.txt')
pkg_joules = parse_rapl(f'{outdir}/monitor/rapl.txt')

GNR_BF16_ISO = 12600   # GFLOPS (12.6 TFLOPS)
GNR_INT8_ISO = 22900   # TOPS  (22.9 TOPS)

print("AMX BENCHMARK RESULTS")
print("=" * 50)
if bf16_iso:
    delta = (bf16_iso - GNR_BF16_ISO) / GNR_BF16_ISO * 100
    status = "PASS" if bf16_iso > GNR_BF16_ISO else "FAIL"
    print(f"BF16 iso-core (8C): {bf16_iso:.0f} GFLOPS  (GNR: 12600, delta: {delta:+.1f}%) — {status}")
    if pkg_joules:
        print(f"  Power efficiency: {bf16_iso/pkg_joules*1e3:.1f} GFLOPS/W  (lower energy = better)")
if int8_iso:
    delta = (int8_iso - GNR_INT8_ISO) / GNR_INT8_ISO * 100
    status = "PASS" if int8_iso > GNR_INT8_ISO else "FAIL"
    print(f"INT8 iso-core (8C): {int8_iso:.0f} TOPS    (GNR: 22900, delta: {delta:+.1f}%) — {status}")
if bf16_full:
    print(f"BF16 full (32C):    {bf16_full:.0f} GFLOPS  (informational — GNR was 240C)")
if int8_full:
    print(f"INT8 full (32C):    {int8_full:.0f} TOPS    (informational)")

# Frequency droop check from turbostat log
try:
    freqs = [float(l.split()[1]) for l in open(f'{outdir}/monitor/turbostat.txt')
             if len(l.split()) > 1 and l.split()[1].replace('.','').isdigit()]
    if freqs:
        print(f"Freq during AMX: min={min(freqs):.0f} max={max(freqs):.0f} MHz "
              f"— {'WARN: droop > 5%' if (max(freqs)-min(freqs))/max(freqs)>0.05 else 'stable'}")
except (FileNotFoundError, ValueError, IndexError):
    pass
```

## Pass Criteria
- BF16 iso-core > 12.6 TFLOPS (12,600 GFLOPS) → PASS
- INT8 iso-core > 22.9 TOPS (22,900 TOPS) → PASS
- Full-system: informational (different core count vs GNR 240T)

## Mandatory Reports

After every AMX run, write `deep_dive_report.md` and `tuning_recommendations.md` to `$OUTDIR/`. Follow the template in [run-benchmark/SKILL.md](../run-benchmark/SKILL.md#mandatory-reports).

The **Monitoring Telemetry** section of the deep dive must include:

| File | Monitoring tool | Metrics |
|---|---|---|
| `$OUTDIR/sysconfig/cpu_info.txt` | lscpu | CPU model, AMX feature flags |
| `$OUTDIR/sysconfig/dimm_info.txt` | dmidecode -t 17 | DIMM speed and population |
| `$OUTDIR/sysconfig/cpupower.txt` | cpupower | Governor, boost state |
| `$OUTDIR/sysconfig/smi_baseline.txt` | rdmsr 0x34 | SMI count before run |
| `$OUTDIR/monitor/turbostat.txt` | turbostat | Freq (MHz), PkgWatt, CoreTmp during benchdnn |
| `$OUTDIR/monitor/rapl.txt` | perf stat RAPL | Package + core energy (Joules) |
| `$OUTDIR/bench/amx_bf16_iso.txt` | benchdnn | BF16 GFLOPS — iso-core 8C |
| `$OUTDIR/bench/amx_int8_iso.txt` | benchdnn | INT8 TOPS — iso-core 8C |
| `$OUTDIR/bench/amx_bf16_full.txt` | benchdnn | BF16 GFLOPS — full system |
| `$OUTDIR/bench/amx_int8_full.txt` | benchdnn | INT8 TOPS — full system |
| `$OUTDIR/emon/amx_perf_verify.txt` | perf stat | AMX tile events — confirms AMX used (not VNNI fallback) |
