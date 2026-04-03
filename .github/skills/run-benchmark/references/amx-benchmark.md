# AMX Performance Benchmark Reference

## Purpose
Measure Intel AMX throughput for BF16 and INT8 matrix operations via oneDNN benchdnn.
Pass = DMR throughput > GNR at iso-core count (8 cores, 100% utilization).

**Tool correction vs framework doc**: Use `--conv` operator, NOT `--matmul`.
Shape from GNR BKM: `ic128oc128ih56oh56kh3ph1n32`

---

## Prerequisites

### Check if oneDNN benchdnn is available
```bash
# From llama.cpp build (already on this system)
find /root/llama.cpp -name benchdnn 2>/dev/null
# Or standalone oneDNN build
find /root -name benchdnn 2>/dev/null
ls /root/oneDNN/build/tests/benchdnn/benchdnn 2>/dev/null || echo "need to build"
```

### Build oneDNN standalone (if benchdnn not found)
```bash
dnf install -y cmake gcc-c++ git
cd /root
git clone --depth 1 https://github.com/oneapi-src/oneDNN.git
mkdir -p oneDNN/build && cd oneDNN/build
cmake .. -DCMAKE_BUILD_TYPE=Release -DDNNL_CPU_RUNTIME=OMP
make -j$(nproc) benchdnn
export BENCHDNN=/root/oneDNN/build/tests/benchdnn/benchdnn
export LD_LIBRARY_PATH=/root/oneDNN/build/src:$LD_LIBRARY_PATH
```

---

## Environment Setup
```bash
export BENCHDNN=/root/oneDNN/build/tests/benchdnn/benchdnn   # adjust path
export LD_LIBRARY_PATH=/root/oneDNN/build/src:$LD_LIBRARY_PATH
export DNNL_MAX_CPU_ISA=AMX
export KMP_BLOCKTIME=0
export OMP_PROC_BIND=close
export OMP_PLACES=cores
```

---

## Run: Iso-core (8 cores, 100% utilization — matches GNR BKM)

```bash
# ISO_CORES: first 8 physical cores on this 32-core system
ISO_CORES=0,1,2,3,4,5,6,7   # HT disabled, so 0-7 = 8 physical cores

# BF16 iso-core
export OMP_NUM_THREADS=8
numactl --physcpubind=$ISO_CORES \
    $BENCHDNN --mode=P --conv --dt=bf16 \
    ic128oc128ih56oh56kh3ph1n32 \
    2>/dev/null | tee /tmp/amx_bf16_isocore.txt

# INT8 iso-core
numactl --physcpubind=$ISO_CORES \
    $BENCHDNN --mode=P --conv --dt=s8 \
    ic128oc128ih56oh56kh3ph1n32 \
    2>/dev/null | tee /tmp/amx_int8_isocore.txt
```

---

## Run: Full system (all 32 cores)

```bash
# BF16 full system
export OMP_NUM_THREADS=32
export OMP_PROC_BIND=spread
$BENCHDNN --mode=P --conv --dt=bf16 \
    ic128oc128ih56oh56kh3ph1n32 \
    2>/dev/null | tee /tmp/amx_bf16_fullsys.txt

# INT8 full system
$BENCHDNN --mode=P --conv --dt=s8 \
    ic128oc128ih56oh56kh3ph1n32 \
    2>/dev/null | tee /tmp/amx_int8_fullsys.txt
```

---

## Parse Results
```python
import re

def parse_benchdnn(filepath):
    """Extract GFLOPS/s from benchdnn --mode=P output."""
    text = open(filepath).read()
    # benchdnn reports: "perf,... <GFLOPS>"  or "flops:  X.XXe+YY  GFLOPS/s: X.XX"
    m = re.search(r'(\d+\.?\d*)\s*GFLOPS', text, re.IGNORECASE)
    if m:
        return float(m.group(1))
    # fallback: look for throughput line
    m = re.search(r'min\s*=\s*[\d.]+ms.*?(\d+\.?\d+)\s*GFLOPS', text)
    return float(m.group(1)) if m else None

bf16_gflops = parse_benchdnn('/tmp/amx_bf16_isocore.txt')
int8_tops   = parse_benchdnn('/tmp/amx_int8_isocore.txt')
print(f"BF16: {bf16_gflops:.1f} GFLOPS/s  (GNR: 12.6 TFLOPS, pass = DMR > GNR)")
print(f"INT8: {int8_tops:.1f}  TOPS/s    (GNR: 22.9 TOPS,   pass = DMR > GNR)")
```

---

## Pass Criteria

| Test | GNR Reference | Pass Condition |
|---|---|---|
| BF16 iso-core (8C, 100%) | 12.6 TFLOPS | DMR > 12.6 TFLOPS |
| INT8 iso-core (8C, 100%) | 22.9 TOPS | DMR > 22.9 TOPS |
| BF16 full system | 56.7 TFLOPS (240T GNR) | DMR/32C vs GNR/240T — informational |
| INT8 full system | 54.6 TOPS (240T GNR) | DMR/32C vs GNR/240T — informational |

> **For iso-core comparison**: GNR numbers above are from the GNR BKM (8 vCPUs from 240-core system). Compare DMR 8-core to GNR 8-core directly.

---

## Notes

- `~3 seconds` runtime is normal for benchdnn micro-benchmark
- Results represent kernel throughput (peak synthetic), not end-to-end workload
- AMX kernel used: `brg_conv_fwd:avx10_1_512_amx`
- `DNNL_MAX_CPU_ISA=AMX` forces AMX even if frequency scaling would otherwise select a lower ISA
- DMR has wider AMX tiles and higher DDR5 bandwidth → expect meaningful BF16/INT8 uplift vs GNR

---

## Reporting Format

```
AMX BENCHMARK RESULTS
=====================
BF16 (8-core iso): XX.X GFLOPS/s  (GNR: 12.6 TFLOPS, delta: +X.X%) — PASS/FAIL
INT8 (8-core iso): XX.X TOPS/s    (GNR: 22.9 TOPS,   delta: +X.X%) — PASS/FAIL
BF16 (32-core):    XX.X GFLOPS/s  (informational — GNR was 240C)
INT8 (32-core):    XX.X TOPS/s    (informational)
AMX kernel: brg_conv_fwd:avx10_1_512_amx
```
