---
name: fsi-benchmark
description: "Run Intel FSI (Financial Services Industry) segment validation benchmarks. Use when: validating HFT latency, measuring packet processing latency, testing network ping-pong latency, running Monte Carlo options pricing workloads, benchmarking HPC grid financial workloads, validating Solarflare NIC kernel bypass, measuring core-to-core latency for HFT, checking SMI count for HFT readiness, validating DMR/GNR/EMR/AMD Turin FSI KPIs, checking LZ KPI compliance, FSI segment validation."
argument-hint: "[hft|hpc-grid|platform|all|preflight]"
disable-model-invocation: false
allowed-tools: Bash
---

# FSI Segment Benchmark Runner

**Scope:** Intel FSI Segment Validation — HFT (High-Frequency Trading) + HPC Grid  
**Platforms:** DMR, GNR-SP, EMR, AMD Turin (auto-detected at runtime)  
**Output dir:** `${BENCHMARK_OUTDIR:-/datafs/fsi-benchmarks}/<timestamp>-fsi/` (persistent; never `/tmp/`)
**Test Plan ref:** Segment Validation - FSI Test Plan v0.91

## Quick Reference

| `/fsi-benchmark $name` | What it runs | ~Runtime |
|---|---|---|
| `preflight` | CPU detect, SMI check, C-state check, NUMA topology | ~1 min |
| `hft-compute` | hft_rdtscp packet processing (1r1w, 24r1w, 24r3w) | ~5 min |
| `hft-network` | ef_vi + Onload UDP/TCP ping-pong, STAC-N1 sweep | ~20 min |
| `hft` | preflight + hft-compute + hft-network (if topology available) | ~25 min |
| `hpc-workloads` | Monte Carlo options suite × 4 compiler variants | ~45 min |
| `hpc-accelerator` | IAA compression, QAT crypto, DSA P2P BW | ~15 min |
| `hpc-grid` | hpc-workloads + hpc-accelerator | ~60 min |
| `platform` | Shared platform KPIs: QAT, DSA, power (rows 53–66 LZ) | ~20 min |
| `all` | preflight + hft + hpc-grid + platform | ~90 min |

> **`hft-network` requires two systems** with Solarflare X2522-25G-PLUS NICs directly connected.  
> If a second system is unavailable, `hft` runs only `hft-compute` and reports the topology gap.

---

## Step 0 — Always run preflight first

```bash
/fsi-benchmark preflight
```

Preflight confirms:
1. CPU family (selects correct LZ KPI threshold column)
2. SMI count is zero (critical HFT gate)
3. C-states are healthy
4. NUMA topology matches expected config
5. Solarflare NIC presence (gates hft-network availability)

---

## Step 1 — CPU Auto-Detection

Run this first in every benchmark session. The detected CPU sets the threshold column used for all pass/fail evaluations.

```bash
# Detect CPU family
CPU_MODEL=$(lscpu | awk -F: '/Model name/{print $2}' | xargs)
CPUID_MODEL=$(awk '/^cpu family/{f=$NF} /^model\s/{m=$NF} END{print f":"m}' /proc/cpuinfo | head -1)

echo "CPU: $CPU_MODEL"
echo "CPUID: $CPUID_MODEL"

# Map to platform
if echo "$CPU_MODEL" | grep -qi "Diamond Rapids\|DMR"; then
    PLATFORM="DMR"
elif echo "$CPU_MODEL" | grep -qi "Granite Rapids\|GNR"; then
    PLATFORM="GNR"
elif echo "$CPU_MODEL" | grep -qi "Emerald Rapids\|EMR"; then
    PLATFORM="EMR"
elif echo "$CPU_MODEL" | grep -qi "EPYC\|Turin"; then
    PLATFORM="AMD_TURIN"
else
    PLATFORM="UNKNOWN"
    echo "WARNING: Unrecognized CPU — defaulting to GNR thresholds. Verify manually."
fi

echo "PLATFORM=$PLATFORM"
```

Platform-to-threshold-column mapping:

| Detected Platform | LZ KPI Column Used |
|---|---|
| DMR | DMR Min/Target |
| GNR | GNR Latest BKC (reference baseline) |
| EMR | EMR Latest BKC |
| AMD_TURIN | AMD Turin Intel-Measured |
| UNKNOWN | GNR (fallback) |

### System Configuration Validation

```bash
# Kernel version gate
echo "Kernel: $(uname -r)"
EXPECTED_KERNEL="6.18"
uname -r | grep -q "^${EXPECTED_KERNEL}" \
    && echo "Kernel: PASS — matches BKC ${EXPECTED_KERNEL}" \
    || echo "Kernel: WARN — expected BKC ${EXPECTED_KERNEL}, got $(uname -r)"

# System inventory (CPU, memory, IPMI)
dmidecode -t 1 2>/dev/null | grep -E "Manufacturer|Product Name|Version" || true
dmidecode -t 17 2>/dev/null \
    | grep -E "Size|Type:|Configured Memory Speed|Part Number" \
    | grep -v "No Module" | head -16 \
    || echo "dmidecode -t 17: unavailable"

# Benchmark tool version checks
echo "--- Tool versions ---"
wult --version 2>/dev/null || echo "wult: not installed"
python3 -c "import dnnl; print('oneDNN:', dnnl.__version__)" 2>/dev/null \
    || find /root -name "libdnnl*" 2>/dev/null | head -1 || echo "oneDNN: location unknown"
ls -la /usr/lib/x86_64-linux-gnu/libefa.so* 2>/dev/null \
    || ls /usr/lib64/libefa.so* 2>/dev/null || echo "Solarflare/EFA libs: not found"

# Hugepages check
HP=$(cat /proc/sys/vm/nr_hugepages)
[ "$HP" -ge 2048 ] \
    && echo "Hugepages: OK — $HP (≥2048 required for HFT)" \
    || echo "Hugepages: WARN — only $HP (run: echo 2048 > /proc/sys/vm/nr_hugepages)"

# Disk space check for output directory
df -h /tmp 2>/dev/null | awk 'NR==2{print "Tmp space available:", $4}'
```

---

## Step 2 — SMI Check (HFT Critical Gate)

**SMI (System Management Interrupts) > 0 is a hard HFT failure.** SMIs cause latency spikes of hundreds of microseconds — unacceptable for HFT. Check before running any HFT test.

```bash
# Baseline SMI count
SMI_BEFORE=$(sudo rdmsr -a 0x34 2>/dev/null | head -1)
echo "SMI count before: $SMI_BEFORE"

# After 60s idle observation
sleep 60
SMI_AFTER=$(sudo rdmsr -a 0x34 2>/dev/null | head -1)
SMI_DELTA=$((16#$SMI_AFTER - 16#$SMI_BEFORE))
echo "SMI delta (60s): $SMI_DELTA"

if [ "$SMI_DELTA" -eq 0 ]; then
    echo "SMI: PASS — 0 SMIs in 60s observation window"
else
    echo "SMI: FAIL — $SMI_DELTA SMIs detected. HFT latency targets not achievable until resolved."
    echo "  Investigate: sudo dmidecode -t 38 (IPMI), platform RAS config, memory scrubbing intervals"
fi
```

---

## Dispatch Logic

Map `$ARGUMENTS` to sub-skill:

| Argument | Sub-skill |
|---|---|
| `preflight` | CPU detect + SMI check + C-state + NUMA (inline above) |
| `hft-compute` | See [benchmark-hft skill](../benchmark-hft/SKILL.md) → hft-compute section |
| `hft-network` | See [benchmark-hft skill](../benchmark-hft/SKILL.md) → hft-network section |
| `hft` | Run preflight → detect topology → hft-compute → hft-network if available |
| `hpc-workloads` | See [benchmark-hpc-grid skill](../benchmark-hpc-grid/SKILL.md) → workloads section |
| `hpc-accelerator` | See [benchmark-hpc-grid skill](../benchmark-hpc-grid/SKILL.md) → accelerator section |
| `hpc-grid` | Run hpc-workloads → hpc-accelerator |
| `platform` | QAT + DSA + power KPIs (rows 53–66 from [lz-kpis.md](./references/lz-kpis.md)) |
| `all` | Run all in phase order: preflight → hft → hpc-grid → platform |

If `$ARGUMENTS` is empty, show the Quick Reference table above and ask which benchmark to run.

---

## Pass/Fail Summary Table (All Platforms)

Full KPI thresholds are in [references/lz-kpis.md](./references/lz-kpis.md).

| # | Workload | KPI | DMR Min | GNR Reference | AMD Turin |
|---|---|---|---|---|---|
| 1 | HFT | PCIe Idle Read Latency | 325 ns | — | — |
| 2 | HFT | PCIe Loaded Read Latency (60% load) | 350 ns | — | — |
| 3 | HFT | LLC hit variability | ≤50% variation | — | — |
| 6 | HFT | Single-thread per-core Perf | ≥1.0× vs GNR SMT-off | GNR | — |
| 7 | HFT | SIR Aggregate Perf (GCC/P1) | ≥1.4× GNR, ≥1.0× AMD | GNR | AMD Turin |
| 23 | HPC | IAA Analytics DB Perf | RocksDB ≥1.2× GNR | GNR | — |
| 24 | HPC | IAA Compression Throughput | ≥GNR | GNR | — |
| 27 | HPC | AI Inference vs AMD | 3× BF16, 4× INT8 | — | AMD |
| 53 | Both | QAT RSA Crypto | ≥100 Kops | — | — |
| 54 | Both | QAT Bulk Crypto | ≥400 Gbps @4K | — | — |
| 63 | Both | SIR Perf/Watt | ≥1.1× (vs prior gen) | — | — |

---

## Two-Tier Tuning Response

After each benchmark, the agent responds using a two-tier approach:

**Tier 1 — Immediate tunable recommendations** (triggered when KPI miss has a known OS/BIOS fix):

| KPI Miss | Root Cause | Immediate Fix |
|---|---|---|
| PCIe latency > threshold | ASPM active or PCIe Gen4 slot | Disable ASPM in BIOS; verify PCIe Gen5 ×16 slot |
| LLC hit variability > 50% | IRQ affinity / C-state transitions | `isolcpus`, disable SMT, C-state pre-wake off |
| Core-to-Core HitM high | SNC enabled (cross-cluster hops) | Pin HFT threads to single SNC cluster via `numactl` |
| Network ½ RTT above target | CTPIO mode = s/f or Onload not loaded | Switch to `ef_vi` CTPIO cut-through; verify `onload` loaded |
| Monte Carlo throughput low | Wrong compiler flags or thread binding | Use ICX + avx512; pin threads `--physcpubind` per NUMA node |
| SMI > 0 | RAS memory scrubbing, IPMI | Disable patrol scrubbing in BIOS; disable runtime RAS SMIs |
| Freq below P1 | HWP not pinned, C-states active | Set `cpupower frequency-set -g performance`; pin HWP ratio |

**Tier 2 — Profiling trigger** (for composite KPI misses where root cause is unknown):

When a Monte Carlo throughput benchmark misses its target, do not immediately recommend a fix. Instead:
1. Run `memory-latency-bw` from the existing `benchmark-memory` skill to get the latency-BW curve
2. Run `benchmark-amx` for AI inference KPIs (rows 27–37 of LZ table)
3. Cross-reference the latency-BW curve inflection point against the thread count where Monte Carlo throughput degrades
4. Report: "Throughput miss is [memory-bound | compute-bound | compiler-bound]" with supporting data
5. Only then recommend the appropriate tuning path

---

## Topology Detection (HFT Network Gate)

```bash
# Check if Solarflare NIC is present
if lspci | grep -qi "solarflare\|xilinx.*x2\|ef100\|8086:1593"; then
    echo "Solarflare NIC: DETECTED"
    NIC_AVAILABLE=1
else
    echo "Solarflare NIC: NOT FOUND — hft-network tests require X2522-25G-PLUS"
    echo "  hft-compute tests will run; hft-network tests will be SKIPPED"
    NIC_AVAILABLE=0
fi

# Check if second system is reachable (requires $PONG_HOST env var)
if [ -n "$PONG_HOST" ] && ssh -o ConnectTimeout=5 "$PONG_HOST" echo ok 2>/dev/null; then
    echo "Pong system ($PONG_HOST): REACHABLE"
    TOPO_AVAILABLE=1
else
    echo "Pong system: NOT REACHABLE — set PONG_HOST=<ip_or_alias> for network tests"
    TOPO_AVAILABLE=0
fi
```

---

## Output Directory Structure

```
${BENCHMARK_OUTDIR:-/datafs/fsi-benchmarks}/<TIMESTAMP>-fsi/
├── sysconfig/
│   ├── cpu_info.txt          # lscpu + /proc/cpuinfo
│   ├── numa_topology.txt     # numactl --hardware
│   ├── dimm_info.txt         # dmidecode -t 17
│   ├── bios_knobs.txt        # relevant MSRs, C-state driver, HWP state
│   └── nic_info.txt          # lspci, ethtool (if Solarflare present)
├── bench/
│   ├── smi_check.log
│   ├── hft_compute/          # hft_rdtscp outputs
│   ├── hft_network/          # eflatency, sfnt-pingpong outputs
│   ├── hpc_workloads/        # Monte Carlo per-workload CSVs
│   └── hpc_accelerator/      # QAT, IAA, DSA outputs
├── emon/                     # perf stat collection per workload
├── monitor/                  # turbostat, RAPL, numastat pre/post, NIC baseline
├── deep_dive_report.md       # REQUIRED — platform summary + monitoring telemetry + results
└── tuning_recommendations.md # REQUIRED — even if all KPIs pass
```

---

## Report Format

```
FSI BENCHMARK RESULTS — <PLATFORM> — <TIMESTAMP>
=================================================
Platform       : DMR / GNR-SP / EMR / AMD Turin (auto-detected)
Kernel         : PASS/WARN — 6.18.x (BKC) / [actual]
System Config  : <Manufacturer> <Product> | <N>× DDR5-<speed> DIMMs
Hugepages      : PASS/WARN — N configured (≥2048 required)
SMI gate       : PASS — 0 SMIs (HFT prerequisite)

HFT COMPUTE
  hft_rdtscp 1r1w     : PASS — avg XXX ns ± XX ns (5 runs)
  hft_rdtscp 24r1w    : PASS — avg XXX ns ± XX ns
  hft_rdtscp 24r3w    : PASS — avg XXX ns ± XX ns
  Freq stability      : stable / WARN: droop > 5%
  NIC drops during    : 0

HFT NETWORK (or: SKIPPED — topology not available)
  UDP eflatency 99%   : PASS — XXX ns ½RTT (threshold: ≤ target from LZ row 7)
  TCP sfnt-pingpong   : PASS — XXX ns ½RTT
  UDP STAC-N1 sweep   : PASS — stable across 100K–1M msgs/sec

HPC GRID
  Monte Carlo (ICX avx512) : PASS — XXX options/sec (avg 5 runs)
  Monte Carlo (GCC avx512) : PASS — XXX options/sec
  IPC (BlackScholesDP)     : X.XX (expected 2–4 for FP workloads)
  NUMA remote hits         : N (expect 0)
  IAA Compression          : PASS/FAIL — XXX GB/s (threshold vs GNR)
  QAT RSA (PKE)            : PASS — XXX Kops (threshold: ≥100 Kops)

PLATFORM
  QAT Bulk Crypto    : PASS — XXX Gbps @4K (threshold: ≥400 Gbps)
  DSA P2P BW         : PASS — XXX GB/s (threshold: ≥60 GB/s)
  Perf/Watt (SIR)    : PASS — X.Xx vs prior gen (threshold: ≥1.1x)

TUNING RECOMMENDATIONS: [none | see Tier-1 items below | Tier-2 profiling needed]
```

---

## Additional References

- [LZ KPIs (Appendix B — 66 KPIs)](./references/lz-kpis.md)
- [System Configurations](./references/system-configs.md)
- [benchmark-hft skill](../benchmark-hft/SKILL.md)
- [benchmark-hpc-grid skill](../benchmark-hpc-grid/SKILL.md)
- FSI Test Plan: Segment Validation - FSI Test Plan v0.91 (internal)
- HFT reference scripts: https://github.com/intel-sandbox/financial-samples/tree/main/HFT
- Network latency scripts: https://github.com/intel-sandbox/applications.benchmarking.financial-services/tree/main/network_latency
- Financial samples (HPC): https://github.com/intel-sandbox/financial-samples
