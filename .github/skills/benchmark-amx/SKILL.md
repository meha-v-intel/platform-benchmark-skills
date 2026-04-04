---
name: benchmark-amx
description: "Run DMR AMX performance benchmark using oneDNN benchdnn. Use when: measuring AMX throughput, benchmarking BF16 TFLOPS, INT8 TOPS, testing matrix multiply performance, validating AMX tiles, AI inference baseline, deep learning inference, LLM serving, neural network throughput, GenAI workload, transformer model performance, AI accelerator validation, machine learning workload sizing."
argument-hint: "[iso-core|full-system|all]"
allowed-tools: Bash
---

# DMR AMX Performance Benchmark

Measures Intel AMX BF16 and INT8 throughput via oneDNN benchdnn convolution operator.
Argument: `iso-core` (8C, matches GNR BKM), `full-system` (all 32C), or `all` (default: both).

## Variables

| Variable | Description | Example |
|---|---|---|
| `$LAB_HOST` | SSH target alias from `~/.ssh/config` | `lab-target` |
| `$OUTPUT_DIR` | Remote results directory | `/tmp/benchmarks/2026-04-04/` |
| `$NPROC` | Core count discovered at runtime | `32` |
| `$WORK_DIR` | Home directory on remote machine | `/root` |

Set by the agent before invoking this skill. See `AGENT.md`.

## Find / Build benchdnn
```bash
BENCHDNN=$(find ${WORK_DIR:-/root} -name benchdnn -type f 2>/dev/null | head -1)
if [ -z "$BENCHDNN" ]; then
    echo "Building oneDNN..."
    dnf install -y cmake gcc-c++ git
    cd ${WORK_DIR:-/root} && git clone --depth 1 https://github.com/oneapi-src/oneDNN.git
    mkdir -p oneDNN/build && cd oneDNN/build
    cmake .. -DCMAKE_BUILD_TYPE=Release -DDNNL_CPU_RUNTIME=OMP
    make -j$(nproc) benchdnn
    BENCHDNN=/root/oneDNN/build/tests/benchdnn/benchdnn
fi
export LD_LIBRARY_PATH=$(dirname $BENCHDNN)/../../src:$LD_LIBRARY_PATH
echo "benchdnn: $BENCHDNN"
```

## Step 2 — Confirm NUMA topology
```bash
numactl --hardware
```
Iso-core CPUs selected from NUMA node 0. On GNR BKM: `ISO_CORES=0,2,4,6,8,10,12,14`

## Environment
```bash
export DNNL_MAX_CPU_ISA=AMX
export KMP_BLOCKTIME=0
export OMP_PROC_BIND=close
export OMP_PLACES=cores
```

## Iso-core test (8 cores — comparable to GNR BKM)
```bash
ISO_CORES=0,1,2,3,4,5,6,7
export OMP_NUM_THREADS=8

echo "=== BF16 iso-core ==="
numactl --physcpubind=$ISO_CORES --membind=0 \
    $BENCHDNN --mode=P --conv --dt=bf16 \
    ic128oc128ih56oh56kh3ph1n32 2>/dev/null | tee /tmp/amx_bf16_iso.txt

echo "=== INT8 iso-core ==="
numactl --physcpubind=$ISO_CORES --membind=0 \
    $BENCHDNN --mode=P --conv --dt=s8 \
    ic128oc128ih56oh56kh3ph1n32 2>/dev/null | tee /tmp/amx_int8_iso.txt
```

## Iso-core 30% utilization test (OMP_NUM_THREADS=2 — BKM steps 5–6)
```bash
export OMP_NUM_THREADS=2

echo "=== BF16 iso-core 30% ==="
numactl --physcpubind=$ISO_CORES --membind=0 \
    $BENCHDNN --mode=P --conv --dt=bf16 \
    ic128oc128ih56oh56kh3ph1n32 2>/dev/null | tee /tmp/amx_bf16_iso_30pct.txt

echo "=== INT8 iso-core 30% ==="
numactl --physcpubind=$ISO_CORES --membind=0 \
    $BENCHDNN --mode=P --conv --dt=s8 \
    ic128oc128ih56oh56kh3ph1n32 2>/dev/null | tee /tmp/amx_int8_iso_30pct.txt
```
GNR reference: BF16 ~4.2 TFLOPS, INT8 ~8.1 TOPS

## Full-system test (32 cores — BKM steps 7–8)
```bash
export OMP_NUM_THREADS=$NPROC
export OMP_PROC_BIND=spread

echo "=== BF16 full-system ==="
numactl --interleave=all \
    $BENCHDNN --mode=P --conv --dt=bf16 \
    ic256oc256ih56oh56kh3ph1n64 2>/dev/null | tee /tmp/amx_bf16_full.txt

echo "=== INT8 full-system ==="
numactl --interleave=all \
    $BENCHDNN --mode=P --conv --dt=s8 \
    ic256oc256ih56oh56kh3ph1n64 2>/dev/null | tee /tmp/amx_int8_full.txt
```

## Parse and Report
```python
import re, sys

def parse_gflops(path):
    try:
        text = open(path).read()
        m = re.search(r'(\d+\.?\d*)\s*GFLOPS', text, re.IGNORECASE)
        return float(m.group(1)) if m else None
    except FileNotFoundError:
        return None

bf16_iso  = parse_gflops('/tmp/amx_bf16_iso.txt')
int8_iso  = parse_gflops('/tmp/amx_int8_iso.txt')
bf16_full = parse_gflops('/tmp/amx_bf16_full.txt')
int8_full = parse_gflops('/tmp/amx_int8_full.txt')

GNR_BF16_ISO = 12600   # GFLOPS (12.6 TFLOPS)
GNR_INT8_ISO = 22900   # TOPS  (22.9 TOPS)

print("AMX BENCHMARK RESULTS")
print("=" * 50)
if bf16_iso:
    delta = (bf16_iso - GNR_BF16_ISO) / GNR_BF16_ISO * 100
    status = "PASS" if bf16_iso > GNR_BF16_ISO else "FAIL"
    print(f"BF16 iso-core (8C): {bf16_iso:.0f} GFLOPS  (GNR: 12600, delta: {delta:+.1f}%) — {status}")
if int8_iso:
    delta = (int8_iso - GNR_INT8_ISO) / GNR_INT8_ISO * 100
    status = "PASS" if int8_iso > GNR_INT8_ISO else "FAIL"
    print(f"INT8 iso-core (8C): {int8_iso:.0f} TOPS    (GNR: 22900, delta: {delta:+.1f}%) — {status}")
if bf16_full:
    print(f"BF16 full (32C):    {bf16_full:.0f} GFLOPS  (informational — GNR was 240C)")
if int8_full:
    print(f"INT8 full (32C):    {int8_full:.0f} TOPS    (informational)")
```

## Pass Criteria
- BF16 iso-core > 12.6 TFLOPS (12,600 GFLOPS) → PASS
- INT8 iso-core > 22.9 TOPS (22,900 TOPS) → PASS
- Full-system: informational (different core count vs GNR 240T)
