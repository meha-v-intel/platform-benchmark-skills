# FSI LZ KPIs — Appendix B

**Source:** Segment Validation - FSI Test Plan v0.91, Appendix B  
**Purpose:** Authoritative pass/fail thresholds for all FSI benchmark sub-skills.  
**Usage:** Each benchmark skill reads this file to select the threshold column matching the detected CPU platform.

---

## How to Use This File

1. Detect platform using the CPU auto-detection step in `fsi-benchmark/SKILL.md`
2. For each measured KPI, look up the row by `#` or `KPI` name
3. Select threshold from the column matching `PLATFORM` (DMR, GNR, COR, AMD)
4. Apply Tier-1 tuning if measured value misses the **Min** threshold
5. Apply Tier-2 profiling if measured value is between **Min** and **Target**

**Column key:**
- **DMR Min / DMR Target** — Diamond Rapids acceptance gates
- **COR Min / COR Target** — Coral Rapids projection (design exit criteria)
- **GNR** — Granite Rapids latest BKC (reference baseline for comparisons)
- **AMD Turin (Intel)** — AMD Turin as measured by Intel
- **Match Type** — `Exact` = same spec for DMR+COR; `COR only` = DMR N/A; `DMR only` = COR N/A; `Equivalent` = same intent, different values

---

## HFT KPIs (Rows 1–22)

| # | KPI | DMR Min | DMR Target | COR Min | COR Target | GNR Ref | AMD Turin | Match Type |
|---|---|---|---|---|---|---|---|---|
| 1 | PCIe Loaded Read Latency (60% load, 64B) | 350 ns @1.8GHz | 300 ns @1.8GHz | 350 ns @1.8GHz | 300 ns @1.8GHz | — | — | Exact |
| 2 | PCIe Idle Read Latency (64B) | 325 ns @1.8GHz | 275 ns @1.8GHz | 325 ns @1.8GHz | 275 ns @1.8GHz | — | — | Exact |
| 3 | LLC Hit Variability | ≤50% variation | ≤30% variation | ≤50% variation | ≤30% variation | — | — | Exact |
| 4 | Networking: Firewall throughput | 1.5×/1.3×/1.2× clear-VPN; 1.2×/1.2×/1.1× TLS | same as min | same | same | GNR | — | Exact |
| 5 | Networking: VPP FIB | ≥1.6 Tb/s @512B | same as min | ≥1.6 Tb/s @512B | same as min | — | — | Exact |
| 6 | Networking: Single Thread Per Core Perf | ≥1.0× vs GNR SMT-off | ≥1.1× vs GNR SMT-off | ≥1.0× vs GNR SMT-off | ≥1.1× vs GNR SMT-off | GNR | — | Exact |
| 7 | Networking: SIR Aggregate Perf (GCC/P1) | ≥1.4× GNR, ≥1.0× AMD | ≥1.5× GNR, ≥1.2× AMD | ≥1.4× GNR, ≥1.0× AMD Turin2 | ≥1.5× GNR, ≥1.2× AMD Turin2 | GNR | AMD Turin | Equivalent |
| 8 | Networking: Compute Perf/Core vs Comp | ≥1.1× vs comp | ≥1.2× vs comp | ≥1.1× vs comp | ≥1.2× vs comp | — | AMD | Exact |
| 9 | MMIO Idle Write Latency | N/A (DMR) | N/A (DMR) | ≤126 ns | ≤120 ns | — | — | COR only |
| 10 | MMIO Idle Write Latency Variation | N/A (DMR) | N/A (DMR) | TBD | ≤126 ns | — | — | COR only |
| 11 | Core-to-Core HitM Latency in Cluster | N/A (DMR) | N/A (DMR) | ≤47 ns | ≤25 ns | — | — | COR only |
| 12 | Cluster-to-Cluster LLC HitM Latency | N/A (DMR) | N/A (DMR) | ≤110 ns | ≤110 ns | — | — | COR only |
| 13 | Local IO Memory Read - Security Enabled | N/A (DMR) | N/A (DMR) | ≤370 ns | ≤370 ns | — | — | COR only |
| 14 | Lock/Atomic Latency Back to Back | N/A (DMR) | N/A (DMR) | 8–9 cycles | 8–9 cycles | — | — | COR only |
| 15 | Lock/Atomic non-B2B L1D hit | N/A (DMR) | N/A (DMR) | ≤20 cycles | ≤20 cycles | — | — | COR only |
| 16 | 2C1M Lock Performance | N/A (DMR) | N/A (DMR) | No regression vs PNC | No regression vs PNC | — | — | COR only |
| 17 | SOC Latency Optimized Flows — CXL Write to CBB L3 | Push CXL write data to CBB L3 cache | same as min | N/A (COR) | N/A (COR) | — | — | DMR only |
| 18 | uServices Average RPC Latency (<512B) | <50 µs gRPC RTT P50 | <10 µs gRPC RTT P50 | N/A (COR) | N/A (COR) | — | — | DMR only |
| 19 | uServices RPC Rate | ≥1M rpc/s (>100KB), ≥10M rpc/s (<512B) | same as min | N/A (COR) | N/A (COR) | — | — | DMR only |
| 20 | Networking SIR Base and All-Core Turbo Freq | P1n >2.0 GHz; all-core turbo >2.5 GHz | same as min | N/A (COR) | N/A (COR) | — | — | DMR only |
| 21 | Uncore Enhancements SnpCur | SnpCur | SnpCur + 32 CLOS + Frequency CLOS | N/A (COR) | N/A (COR) | — | — | DMR only |
| 22 | SMI Reduction/Elimination for RAS | ≥50% reduction for memory RAS flows | Eliminate runtime RAS SMIs | N/A (COR) | N/A (COR) | — | — | DMR only |

---

## HPC Grid KPIs (Rows 23–52)

| # | KPI | DMR Min | DMR Target | COR Min | COR Target | GNR Ref | Match Type |
|---|---|---|---|---|---|---|---|
| 23 | IAA: Analytics Database Perf (RocksDB) | ≥1.2× GNR | ≥1.5× GNR | ≥2.0× GNR | ≥3.0× GNR | GNR | Equivalent (COR tighter) |
| 24 | IAA: Compression/Decompression Throughput | ≥GNR | ≥1.2× GNR | COR-SP ≥1.5× GNR-SP | COR-SP ≥2.0× GNR-SP | GNR | Equivalent (COR tighter) |
| 25 | IAA/System: Page Fault Latency Compressed Tier | ≤1.75 µs (GNR trend) | ≤1.5 µs | ≤1.0 µs | ≤750 ns | GNR | Equivalent (COR tighter) |
| 26 | IAA/System: Mem Tiering Compression | Same mem savings as GNR | +5% savings vs GNR | Same mem savings as GNR | +5% savings vs GNR | GNR | Exact |
| 27 | AI Inference vs AMD Stack | 3× BF16, 4× INT8, 1.3× ARM BF16 | 4× BF16, 4× INT8, 1.3× ARM BF16 | same | same | — | Exact |
| 28 | L0 Hit Latency | N/A (DMR) | N/A (DMR) | 4 cycles | 4 cycles | — | COR only |
| 29 | L1 Hit Latency | N/A (DMR) | N/A (DMR) | 9 cycles | 9 cycles | — | COR only |
| 30 | L2 Hit Latency | N/A (DMR) | N/A (DMR) | 19 cycles | 19 cycles | — | COR only |
| 31 | LLC Hit Latency | N/A (DMR) | N/A (DMR) | ≤25 ns | ≤12 ns | — | COR only |
| 32 | Local Memory Read Latency | N/A (DMR) | N/A (DMR) | ≤115 ns NUMA / ≤125 ns UMA | ≤100 ns NUMA / ≤110 ns UMA | — | COR only |
| 33 | Remote Socket Memory Read Latency | N/A (DMR) | N/A (DMR) | ≤215 ns NUMA / ≤225 ns UMA | ≤200 ns NUMA / ≤210 ns UMA | — | COR only |
| 34 | Local Memory Read Latency - Security Enabled | N/A (DMR) | N/A (DMR) | ≤132 ns NUMA / ≤142 ns UMA | ≤110 ns NUMA / ≤120 ns UMA | — | COR only |
| 35 | 1-Core Stream Triad BW | N/A (DMR) | N/A (DMR) | ≥80 GB/s | ≥80 GB/s | — | COR only |
| 36 | All-CBB to Local DDR BW (100R) | N/A (DMR) | N/A (DMR) | ≥565 GB/s | ≥565 GB/s | — | COR only |
| 37 | All-CBB to Local MCR BW (100R) | N/A (DMR) | N/A (DMR) | ≥786 GB/s | ≥786 GB/s | — | COR only |
| 38 | IO→Memory BW (100R) | N/A (DMR) | N/A (DMR) | ~22 GB/s | ≥115 GB/s | — | COR only |
| 39 | P2P BW | N/A (DMR) | N/A (DMR) | ~22 GB/s | ≥448 GB/s | — | COR only |
| 40 | HPC Perf vs Comp (HPCG/LAMMPS/DGEMM/HPL) | ≥1.05× comp; parity floor | ≥1.1× comp | N/A (COR) | N/A (COR) | — | DMR only |
| 41 | Linpack 2S Perf/W vs GNR | ≥1.2× | ≥1.2× | N/A | N/A | GNR | DMR only |
| 42 | Linpack 2S Perf/W vs Comp | ≥1.05× | ≥1.1× | N/A | N/A | — | DMR only |
| 43 | DGEMM Perf/W vs GNR | ≥1.2× | ≥1.2× | N/A | N/A | GNR | DMR only |
| 44 | DGEMM Perf/W vs Comp | ≥1.05× | ≥1.1× | N/A | N/A | — | DMR only |
| 45 | SFR SpecFloatRate Perf/W vs GNR | ≥1.2× | ≥1.2× | N/A | N/A | GNR | DMR only |
| 46 | SFR SpecFloatRate Perf/W vs Comp | ≥1.05× | ≥1.1× | N/A | N/A | — | DMR only |
| 47 | Stream Triad Perf vs GNR | ≥1.2× | ≥1.25× | N/A | N/A | GNR | DMR only |
| 48 | Stream Triad Perf vs Comp | ≥1.05× | ≥1.1× | N/A | N/A | — | DMR only |
| 49 | L2 Bandwidth per Core | ≥32 B/cycle/core | ≥42 B/cycle/core | N/A | N/A | — | DMR only |
| 50 | L3 LLC Bandwidth per Core | ≥12 B/cycle/core | ≥15 B/cycle/core | N/A | N/A | — | DMR only |
| 51 | Mem BW Supply per DCM (all-cores) | ≥9.4 GB/s all-cores; ≥30 GB/s partial | ≥10 GB/s all-cores; ≥40 GB/s partial | N/A | N/A | — | DMR only |
| 52 | Memory BW per VM at Harmonic Core Counts | ≥9.3 GB/s per VM | ≥10.0 GB/s per VM | N/A | N/A | — | DMR only |

---

## Shared Platform KPIs — Both HFT and HPC (Rows 53–66)

These run regardless of HFT vs HPC context, invoked by `/fsi-benchmark platform`.

| # | KPI | DMR Min | DMR Target | COR Min | COR Target | GNR Ref | Match Type |
|---|---|---|---|---|---|---|---|
| 53 | QAT: RSA (PKE) Crypto Acceleration | ≥100 Kops | ≥200 Kops | ≥100 Kops | ≥200 Kops | — | Exact |
| 54 | QAT: Bulk Crypto Acceleration | ≥400 Gbps @4K | ≥800 Gbps @4K | ≥400 Gbps @4K | ≥800 Gbps @4K | — | Exact |
| 55 | QAT: Compression Acceleration (Zstd/Deflate) | Zstd 200/100/100; Deflate 160/100 | Zstd 400/200/200; Deflate 320/200 | same as DMR min | same as DMR target | — | Exact |
| 56 | QAT: Decompression Performance | Zstd ≥400G; Deflate ≥320G | Zstd ≥400G; Deflate ≥640G | same | same | — | Exact |
| 57 | Accelerator Read Memory Latency (idle/loaded) | ≥GNR baseline | ≥20% lower vs GNR | COR-AP same as DMR-AP | ≥20% lower | GNR | Equivalent |
| 58 | DSA Per-NTB Peer-to-Peer BW | ≥60 GB/s | ≥120 GB/s | ≥115 GB/s | ≥120 GB/s | — | Equivalent (COR min tighter) |
| 59 | Xeon-SP Legacy Accelerator Performance | ≤10% perf reduction vs GNR | No perf reduction vs GNR | ≤10% reduction | No reduction | GNR | Exact |
| 60 | Active/Performance Idle Power | CC6 <20% TDP; perf-idle <30% TDP | same + no drop with CC6 | Better than 30%/20% anchors | Better than comp | — | Equivalent intent |
| 61 | SIR Perf/Power Loadline Energy Efficiency | Linear from active idle to TDP | same as min | <60% TDP at 50% util; on-par vs comp | same | — | Equivalent intent |
| 62 | Power Save Mode for SERT | Better PC6 power vs prior gen | Better PC6 + PC6→PC0 <125 µs | Better power/latency vs prior gen | Better than AMD | — | Equivalent intent |
| 63 | SIR General Perf/Watt | ≥1.1× | ≥1.2× | ≥1.1× | ≥1.3× | — | Equivalent (COR tighter) |
| 64 | Cloud IaaS Perf/TCO | ≥1.05× PCP + ≥10% TCO reduction | ≥1.1× PCP + ≥20% TCO reduction | same | same | — | Exact |
| 65 | SOC SPECPower vs Loadline | 50% util power <60% TDP | same | Within 10% vs comp | Better than comp | — | Equivalent intent |
| 66 | RDT Region-Aware MBM/MBA | Counters for 2 memory regions | Counters for 4 memory regions | N/A (COR) | N/A (COR) | — | DMR only |

---

## Tier-1 Tuning Lookup (KPI Miss → Known Fix)

| KPI # | KPI Name | If Miss — Root Cause | If Miss — Fix |
|---|---|---|---|
| 1–2 | PCIe Read Latency | ASPM active; PCIe Gen4 slot | Disable ASPM in BIOS; move NIC to PCIe Gen5 ×16 |
| 3 | LLC Hit Variability | IRQ affinity; C-state transitions; SMT siblings | `isolcpus`; disable SMT; turn off C-state pre-wake |
| 6 | Single-Thread Per-Core Perf | SMT enabled; governor not performance | `echo 0 > /sys/devices/system/cpu/smt/control`; `cpupower -g performance` |
| 7 | SIR Aggregate Perf | Wrong compiler; NUMA binding off | Use ICX + avx512; pin with `numactl --physcpubind` |
| 11 | C2C HitM in Cluster (COR) | SNC misconfiguration or cross-cluster placement | Verify SNC enabled; pin threads to single cluster |
| 22 | SMI Reduction | Patrol scrubbing; IPMI; runtime RAS | Disable patrol scrub in BIOS; disable memory RAS SMIs |
| 23–24 | IAA Throughput | IAA not configured; wrong queue depth | Check `accel-config list`; verify IAA work queues active |
| 27 | AI Inference | AMX not used; BF16 paths not exercised | Use oneDNN with `DNNL_MAX_CPU_ISA=AVX512_CORE_AMX_BF16` |
| 47–50 | Stream/L2/L3 BW | THP off; wrong NUMA binding | `echo always > /sys/kernel/mm/transparent_hugepage/enabled`; `numactl --localalloc` |
| 53–56 | QAT Performance | QAT service not started; wrong driver | `systemctl start qat`; check `qatmgr --status` |
| 58 | DSA P2P BW | DSA not configured; IOMMU blocking | `accel-config load-config`; verify IOMMU passthrough |
| 60–65 | Power/Perf efficiency | Power governor active; CC6 disabled | Confirm TDP and power capping; check `turbostat` idle power |

---

## Tier-2 Profiling Triggers (Composite KPI Misses)

These KPIs require profiling before recommending a fix. Do NOT give a direct fix recommendation for these without first running the referenced diagnostic.

| KPI # | KPI Name | Tier-2 Diagnostic |
|---|---|---|
| 40–48 | HPC workload throughput (Linpack/DGEMM/Monte Carlo) | Run `benchmark-memory` latency-BW curve; identify if memory-bound vs compute-bound |
| 27 | AI Inference vs AMD | Run `benchmark-amx` BF16 + INT8; compare to AMX theoretical ceiling |
| 7 | SIR Aggregate Perf | Profile with EMON/perf stat; decompose into compute vs memory vs interconnect time |
| 23–25 | IAA throughput and page fault latency | Profile working set size progression; check if LLC-resident or DRAM-resident |
