# DMR EMON Metric Reference Guide
## Diamond Rapids (Panther Cove Core) — EMON Metric Definitions

Source files in this directory:
- `corePMonCore.json` — 1,471 raw core PMU event definitions
- `corePMonCore_Metrics.json` — 111 computed metrics (IPC, BW, efficiency formulas)
- `corePerfMon_Offcore.json` — 1,869 OMR offcore/cross-socket events
- `corePerfMon_Uncore.json` — 7,281 uncore events (IIO, memory, PCIe, CXL, mesh)

All JSON files are sourced from `/root/emon_dmr_documentation/` (symlinked here).
Official platform: Diamond Rapids PantherCove, build Feb 2026.

---

## 1. EDP Excel Output Guide — What to Read First

When you open `summary.xlsx`, this is the ordered read sequence:

1. **System Summary tab** — IPC, freq, utilization% at a glance
2. **Core Details / Thread View** — per-core IPC, util%, hotspot identification  
3. **IIO / OTC Uncore tab** — IO read/write BW, IRQ (MSI) rate  
4. **IMC Uncore tab** — memory BW read/write per channel, page hit %  
5. **HAMVF Uncore tab** — read/write tracker queues, CXL vs DDR split  
6. **CMS Uncore tab** — mesh credit stalls, injection starvation  
7. **Time-Series tabs** — trend over run duration (look for ramp/drop patterns)

---

## 2. Core Metrics (111 Computed Metrics — NDA/Private)

All formulas use positional variables (a=event1, b=event2, ...) resolved by pyedp.

### 2.1 Throughput and Utilization

| Metric | Formula | Unit | Notes |
|--------|---------|------|-------|
| `metric_CPU operating frequency (in GHz)` | `(CLK_UNHALTED.THREAD / CLK_UNHALTED.REF_TSC * TSC_FREQ) / 1e9` | GHz | Actual running freq, not nominal |
| `metric_CPI` | `CLK_UNHALTED.THREAD / INST_RETIRED.ANY` | cycles/instr | Lower is better; <1.5 = well-utilized |
| `metric_core IPC` | `INST_RETIRED.ANY / CLK_UNHALTED.THREAD` | instr/cycle | Inverse of CPI |
| `metric_CPU utilization %` | `100 * CLK_UNHALTED.THREAD / CLK_UNHALTED.REF_TSC` | % | % time in C0 (active) |
| `metric_EMON event mux reliability%` | `100 * min(group_a, group_b) / max(...)` | % | Must be ≥95% for valid data |

**iperf3 context:** For 400GbE TCP workload, expect utilization 60–90% on IRQ cores, IPC 0.5–2.0 (small burst sizes → low IPC due to interrupt overhead; large → higher).

### 2.2 Uncore Frequencies

| Metric | Notes |
|--------|-------|
| `metric_uncore CBB0/1/2/3 frequency GHz` | 4 Cache Building Blocks — each has own ring freq |
| `metric_uncore IMH0/1 frequency GHz` | Integrated Memory Hub freq (routes to DDR/CXL) |
| `metric_DDR data rate DDR5 (MT/sec)` | = `gear * MNTCMD_REFRATE / 1e6`; DMR-Q9UC baseline 8000 MT/s |

### 2.3 C-state and Power

| Metric | Notes |
|--------|-------|
| `metric_core c1 residency %` | % time in C1/C1E; should be low during active workload |
| `metric_core c6 residency %` | % time in C6 deep sleep; high = workload not fully utilizing those cores |
| `metric_package c2/c6 residency %` | Package-level idle; non-zero during partial utilization |
| `metric_package power (watts)` | `UNC_P_POWER_STATE * 61 / 1e6` |
| `metric_DRAM power (watts)` | `UNC_P_DRAM_POWER * 61 / 1e6` |

### 2.4 Memory Access Metrics (per-core / thread-level)

| Metric | Notes |
|--------|-------|
| `metric_L1D MPI (includes data+rfo w/ prefetches)` | L1D misses/instruction; typically <0.05 for cache-friendly code |
| `metric_L2 demand data read MPI` | L2 read misses/instr; <0.01 is good |
| `metric_LLC data read MPI (demand+prefetch)` | Key for DMA-heavy workloads; high = working set exceeds LLC |
| `metric_LLC HITM same CBB (per instr)` | Modified line hit in same CBB LLC; high = false sharing within CBB |
| `metric_LLC HITM other CBB local socket (per instr)` | Modified hit in diff CBB; high = cross-CBB sharing (NUMA-like within socket) |
| `metric_LLC demand data read miss latency (in ns)` | `1e9 * (COMPLETED / COUNT) / TSC_FREQ` — if >200ns = going to DRAM/CXL |

### 2.5 Memory Bandwidth (IMC-level — NDA visibility)

| Metric | Formula | Unit |
|--------|---------|------|
| `metric_memory bandwidth read (MB/sec)` | `UNC_M_CAS_COUNT.RD * 64 / 1e6` | MB/s |
| `metric_memory bandwidth write (MB/sec)` | `UNC_M_CAS_COUNT.WR * 64 / 1e6` | MB/s |
| `metric_memory bandwidth total (MB/sec)` | `(UNC_M_CAS_COUNT.RD + .WR) * 64 / 1e6` | MB/s |
| `metric_memory reads vs. all requests` | `.RD / (.RD + .WR)` | ratio |
| `metric_memory page hit %` | `100 * (1 - ACT_COUNT.ALL / CAS_COUNT.ALL)` | % |
| `metric_memory page miss %` | `100 * (PRE_COUNT.PGT / CAS_COUNT.ALL)` | % |
| `metric_memory Rd Trk entries` | avg outstanding read tracker entries | count |
| `metric_memory Rd Trk latency (ns)` | avg ns for reads in IMC tracker queue | ns |

**Derived:** DMR-Q9UC theoretical peak memory BW: 16 channels × 8000 MT/s × 8 bytes = **1,024 GB/s**

### 2.6 I/O Bandwidth (OTC/ITC-level — NDA visibility)

| Metric | Formula | Notes |
|--------|---------|-------|
| `metric_IO read bandwidth (MB/sec)` | `UNC_OTC_reads * 64 / 1e6` | 64B granularity for reads |
| `metric_IO write bandwidth (MB/sec)` | `UNC_ITC_writes * 4 / 1e6` | **4B granularity for writes** — significant difference from reads |
| `metric_IO MSI per sec` | `UNC_CNCU_NCU_INTERRUPTS_TYPE` | PCIe interrupt rate; normalize to NAPI budget |
| `metric_IO read miss SCA %` | `100 * SCA_miss / SCA_total` | Cache miss rate at Scalable Caching Agent |
| `metric_IO write miss SCA %` | complex formula over UNC_SCA | SCA write miss rate |

### 2.7 UPI and CXL

| Metric | Notes |
|--------|-------|
| `metric_UPI transmit BW (MB/sec)` | `(UNC_ULA[0] + UNC_ULA[13]) * 64 / 1e6` — NUMA cross-socket traffic |
| `metric_CXL_bandwidth_inbound (MB/sec)` | data from CXL device → CPU memory controller |
| `metric_CXL_bandwidth_outbound (MB/sec)` | data from CPU → CXL device |

### 2.8 Frontend & Compute (useful for calibrating what the cores are doing)

| Metric | Notes |
|--------|-------|
| `metric_% Uops from DSB (Icache)` | ≥70% = good instruction fetch; <50% = decode pressure |
| `metric_% Uops from MITE (legacy decode)` | High → decode bottleneck, check alignment |
| `metric_% Uops from MS (microcode)` | High → complex instructions (REP MOVS, CPUID, etc.) |
| `metric_sse_avx_mix penalty cycles%` | Each SSE↔AVX transition costs ~170 cycles |
| `metric_AMX retired per instr` | BF16+INT8+FP16+TF32 tiles/instr; non-zero only if AMX workload |
| `metric_branch mispredict ratio` | `BR_MISP_RETIRED / BR_INST_RETIRED`; <0.01 is good |

---

## 3. Core Hardware Events (1,471 in corePMonCore.json)

### 3.1 Critical Foundation Events (used in every EDP metric)

| Event | Description |
|-------|-------------|
| `INST_RETIRED.ANY` | Instructions retired (architectural completion) |
| `CPU_CLK_UNHALTED.THREAD` | Unhalted core cycles (C0 only) — the denominator for almost everything |
| `CPU_CLK_UNHALTED.REF_TSC` | Reference TSC-rate cycles — used for freq calculation |
| `TOPDOWN.SLOTS` | Total dispatch slots (= 4 × CYC for 4-wide OOO machine) |

### 3.2 Backend Stalls — DMR-specific `BE_STALLS.*` (replaces GNR `RESOURCE_STALLS.*`)

| Event | Meaning |
|-------|---------|
| `BE_STALLS.ANY` | All backend stalls (was `RESOURCE_STALLS.ANY` on GNR) |
| `BE_STALLS.SB` | Store buffer full stall (was `RESOURCE_STALLS.SB`) |
| `BE_STALLS.LB` | Load buffer full stall |
| `BE_STALLS.MADQ` | Memory address disambiguation queue stall |
| `BE_STALLS.SCOREBOARD` | Register scoreboard stall |
| `BE_STALLS.GIT` | GTL/GIT resource stall |
| `BE_STALLS.ICLB` | ICL buffer stall |
| `BE_STALLS.VECQ` | Vector unit queue stall |

### 3.3 Frontend Bubbles — DMR-specific `IDQ_BUBBLES.*` (replaces `IDQ_UOPS_NOT_DELIVERED`)

| Event | Meaning |
|-------|---------|
| `IDQ_BUBBLES.CORE` | Total frontend bubbles — uops not delivered when backend could accept (was IDQ_UOPS_NOT_DELIVERED.CORE on GNR) |
| `IDQ_BUBBLES.BW_STARVATION` | Frontend BW bottleneck |
| `IDQ_BUBBLES.FETCH_LATENCY` | Frontend fetch latency bottleneck |
| `IDQ_BUBBLES.STARVATION_CYCLES` | Cycles with zero uop delivery |
| `IDQ_BUBBLES.POWER_THROTTLING` | Uop delivery throttled by power limit |
| `IDQ_BUBBLES.CYCLES_FE_WAS_OK` | Cycles where frontend was fine (diagnostic) |

### 3.4 Memory Activity — New in DMR

| Event | Meaning |
|-------|---------|
| `MEMORY_ACTIVITY.STALLS_L1D_MISS` | Stall cycles waiting for L1D miss fill |
| `MEMORY_ACTIVITY.STALLS_L2_MISS` | Stall cycles waiting for L2 miss fill |
| `MEMORY_ACTIVITY.STALLS_L3_MISS` | Stall cycles waiting for LLC miss fill (→ memory) |
| `MEMORY_ACTIVITY.L1M_PENDING` | Cycles with outstanding L1 miss |
| `MEMORY_ACTIVITY.L2M_PENDING` | Cycles with outstanding L2 miss |
| `MEMORY_ACTIVITY.L3M_PENDING` | Cycles with outstanding L3 miss |
| `MEMORY_STALLS.L2` | Direct L2 stall counter |
| `MEMORY_STALLS.L3` | Direct L3 stall counter |
| `MEMORY_STALLS.MEM` | Stalls due to main memory latency |

### 3.5 Off-Module Requests (replaces `OFFCORE_REQUESTS.*` from GNR)

| Event | Meaning |
|-------|---------|
| `OFFMODULE_REQUESTS.DEMAND_DATA_RD` | Demand data reads leaving the module |
| `OFFMODULE_REQUESTS.DEMAND_RFO` | Read-for-ownership requests (stores) |
| `OFFMODULE_REQUESTS.ALL_REQUESTS` | All requests going offmodule |
| `OFFMODULE_REQUESTS_OUTSTANDING.DEMAND_DATA_RD` | Outstanding demand read count |
| `OFFMODULE_REQUESTS_OUTSTANDING.DEMAND_DATA_RD_GE_6` | Cycles with ≥6 outstanding (latency pressure indicator) |
| `OFFMODULE_REQUESTS_OUTSTANDING.CYCLES_WITH_DEMAND_DATA_RD` | Cycles with at least 1 outstanding |

### 3.6 Load/Cache Hit Hierarchy — DMR adds XQ model

| Event | Meaning |
|-------|---------|
| `MEM_LOAD_RETIRED.L1_HIT` | Retired load hit in L1D |
| `MEM_LOAD_RETIRED.L1_HIT_L0` / `.L1_HIT_L1` | Sub-L1 hit granularity (new in DMR) |
| `MEM_LOAD_RETIRED.L2_MISS` | Retired load missed L2 (→ LLC or memory) |
| `MEM_LOAD_RETIRED.XQ_HIT_OTHER_CORE` | XQ (cross-module L2 buffer) hit from another core |
| `MEM_LOAD_RETIRED.XQ_HIT_SAME_CORE` | XQ hit from same core module |
| `MEM_LOAD_RETIRED.L2_XSNP_HIT_FWD` | L2 cross-snoop hit with forward (another core had line) |

### 3.7 Cycle Stalls (same as GNR — safe to reuse)

| Event | Meaning |
|-------|---------|
| `CYCLE_ACTIVITY.STALLS_TOTAL` | All stall cycles |
| `CYCLE_ACTIVITY.STALLS_L1D_MISS` | Stalls waiting for L1D miss |
| `CYCLE_ACTIVITY.STALLS_L2_MISS` | Stalls waiting for L2 miss |
| `CYCLE_ACTIVITY.STALLS_L3_MISS` | Stalls waiting for LLC miss (→ DRAM) |
| `CYCLE_ACTIVITY.STALLS_MEM_ANY` | Stalls due to any memory access |

### 3.8 TopDown Slots (first-level bottleneck identification)

| Event | Meaning |
|-------|---------|
| `TOPDOWN.SLOTS` | Total machine slots (4 × unhalted cycles on 4-wide) |
| `TOPDOWN.BACKEND_BOUND_SLOTS` | Slots wasted due to backend stalls |
| `TOPDOWN.MEMORY_BOUND_SLOTS` | Slots wasted specifically due to memory |
| `TOPDOWN.BAD_SPEC_SLOTS` | Slots wasted on wrong-path work |
| `TOPDOWN.BR_MISPREDICT_SLOTS` | Slots wasted on branch mispredictions |
| `TOPDOWN.MEMORY_STALLS` | Memory stall count for TopDown accounting |

---

## 4. Offcore (OMR) Events (1,869 in corePerfMon_Offcore.json)

All offcore events use the `OMR.*` prefix (replaces `OFFCORE_RESPONSE.*` from GNR).

### 4.1 Name Structure

```
OMR.<REQUEST_TYPE>.<CACHE_LEVEL>[.<TOPOLOGY>[.<HIT_TYPE>]]
```

Example: `OMR.DEMAND_DATA_RD.L3_MISS` = demand data reads that missed LLC.

### 4.2 Request Types (21 total)

| Type | Meaning |
|------|---------|
| `DEMAND_DATA_RD` | Core demand data loads |
| `DEMAND_CODE_RD` | Core instruction fetch |
| `DEMAND_RFO` | Read-for-ownership (store to dirty/absent line) |
| `READS_TO_CORE` | All reads including prefetch |
| `HWPF_L1D` / `HWPF_L2_*` / `HWPF_L3_*` | Hardware prefetch by level |
| `SWPF_READ` | Software prefetch |
| `ALL_REQUESTS` | Everything |

### 4.3 Key Response Codes

| Response | Meaning |
|----------|---------|
| `ANY_RESPONSE` | Any outcome — total requests |
| `L3_MISS` | Missed LLC (→ DRAM or CXL) |
| `ANY_MEMORY` | Went to any memory (all regions) |
| `MEM_REGION_0..3` | Local DDR (typical) |
| `MEM_REGION_4..7` | CXL memory tiers (T2/T3) |
| `L3_HITM_SAME_CBB` | Modified line hit in same CBB LLC |
| `L3_HITM_ANY_CBB` | Modified line hit in any CBB (false sharing) |
| `L3_HITESF_*` | ESF (exclusive/shared/forward) state hit |
| `OTHER_MODULE_L2_*` | In-module L2 of another core module |

### 4.4 Key Events for iperf3 Analysis

```bash
# Total demand reads going to memory (any tier):
OMR.DEMAND_DATA_RD.ANY_MEMORY

# Demand reads that missed LLC (→ DRAM/CXL path):
OMR.DEMAND_DATA_RD.L3_MISS

# Split by DDR vs CXL:
OMR.DEMAND_DATA_RD.MEM_REGION_0   # local DDR (typical hot tier)
OMR.DEMAND_DATA_RD.MEM_REGION_4   # CXL T2 cold tier

# Coherency false-sharing signals:
OMR.READS_TO_CORE.L3_HITM_SAME_CBB
OMR.READS_TO_CORE.L3_HITM_ANY_CBB
```

---

## 5. Uncore Events (7,281 in corePerfMon_Uncore.json)

### 5.1 Unit Family Map

| Unit | Count | Purpose |
|------|-------|---------|
| `ITC` | 1099 | Interconnect Transaction Controller — PCIe/CXL inbound |
| `CBO` | 938 | LLC coherence agent (same as GNR) |
| `UBR` | 865 | Universal Bridge Router |
| `SCA` | 739 | Scalable Caching Agent (replaces IIO) |
| `IMC` | 628 | Integrated Memory Controller — DDR5 per channel |
| `HAMVF` | 470 | Home Agent Memory + Virtual Fabric |
| `ULA` | 454 | Universal Link Agent (UPI) |
| `CXLCM` | 433 | CXL Coherence Manager — new in DMR |
| `OTC` | 388 | On-Tile Controller |
| `CMS` | 320 | Cross-Module Switch — mesh interconnect stalls |
| `PCIE` | 181 | PCIe dedicated counters |
| `PCU` | 79 | Power Control Unit |
| `DDA` | 77 | Die-to-Die Adapter |

### 5.2 Memory Controller (IMC) — UNC_M_*

**Primary bandwidth counters:**

| Event | Meaning |
|-------|---------|
| `UNC_M_CAS_COUNT.RD` | DRAM CAS for all reads. BW = .RD * 64 bytes / time |
| `UNC_M_CAS_COUNT.WR` | DRAM CAS for all writes. BW = .WR * 64 bytes / time |
| `UNC_M_CAS_COUNT.ALL` | Total DRAM transactions (reads + writes) |
| `UNC_M_CAS_COUNT.PCH0_RD` / `PCH0_WR` | Sub-channel 0 read/write breakdown |
| `UNC_M_CAS_COUNT.PCH1_RD` / `PCH1_WR` | Sub-channel 1 read/write breakdown |
| `UNC_M_ACT_COUNT.RD` / `.WR` / `.ALL` | Row activations (row miss events) |
| `UNC_M_PRE_COUNT.PGT` | Precharge page-turn events |

**Derived metrics:**
- `page_hit_% = 100 * (1 - ACT_COUNT.ALL / CAS_COUNT.ALL)` — higher = better locality
- `page_miss_% = 100 * PRE_COUNT.PGT / CAS_COUNT.ALL`

**Note:** RPQ/WPQ events (`UNC_M_RPQ_INSERTS`, `UNC_M_WPQ_INSERTS`) from GNR are **GONE** in DMR. Use HAMVF counters for queue tracking.

**Tracker queue events:**

| Event | Meaning |
|-------|---------|
| `UNC_M_TRKR_RD_INSERT_TYPE.ALL` | Read tracker inserts (= requests to DRAM) |
| `UNC_M_TRKR_RD_NOT_EMPTY` | Cycles with ≥1 outstanding read in tracker |
| `UNC_M_TRKR_RD_OCCUPANCY` | Read tracker occupancy (sum of outstanding reads) |

### 5.3 Home Agent Memory Virtual Fabric (HAMVF) — UNC_HAMVF_*

Replaces the GNR HA+IMC pipeline. Front-ends the memory controller.

| Event | Meaning |
|-------|---------|
| `UNC_HAMVF_HA_IMC_READS_COUNT` | Reads dispatched to IMC post-coherency |
| `UNC_HAMVF_HA_IMC_WRITES_COUNT.FULL` | Full 64B writes to IMC |
| `UNC_HAMVF_HA_IMC_WRITES_COUNT.PARTIAL` | Partial writes (< 64B) |
| `UNC_HAMVF_TRACKER_INSERTS.LOCAL_IACA_1LM_DDR` | DDR access tracking (local socket DDR) |
| `UNC_HAMVF_TRACKER_INSERTS.LOCAL_IACA_CXL_T2_HDMDB` | CXL Type 2 (HDMDB) tracking |
| `UNC_HAMVF_TRACKER_INSERTS.LOCAL_IACA_CXL_T3_HDMDB` | CXL Type 3 (HDMDB) tracking |
| `UNC_HAMVF_TRACKER_INSERTS.LOCAL_IACA_FLAT2LM` | 2LM flat mode tracking |
| `UNC_HAMVF_TRACKERDB_OCCUPANCY` | Total tracker occupancy |
| `UNC_HAMVF_RPQ_CYCLES_NO_SPEC_CREDITS` | Cycles with no read queue speculative credits |
| `UNC_HAMVF_WPQ_CYCLES_NO_REG_CREDITS` | Cycles with no write queue credits |

**Use for:** Verifying DDR vs CXL split; queue saturation; write amplification (FULL vs PARTIAL ratio).

### 5.4 Cross-Module Switch (CMS) — UNC_CMS_* — Mesh Interconnect

**Stall events (240 total — per mesh node ID 0-15):**

| Event Pattern | Meaning |
|---------------|---------|
| `UNC_CMS_STALL_NO_EGR_CREDIT_AD.TXMESHIDn` | No egress credit on AD channel to node n |
| `UNC_CMS_STALL_NO_EGR_CREDIT_AK.TXMESHIDn` | No egress credit on AK channel |
| `UNC_CMS_STALL_NO_EGR_CREDIT_BL.TXMESHIDn` | No egress credit on BL channel |
| `UNC_CMS_STALL_NO_TA_CREDIT_AD.TXMESHIDn` | No TA credit on AD channel |
| `UNC_CMS_RX_INJ_STARVED_ASC.AD` | Injection starvation — AD channel in ASC direction |
| `UNC_CMS_RX_INJ_STARVED_ASC.BL` | Injection starvation — BL channel |
| `UNC_CMS_RX_INJ_STARVED_DSC.AD` | Injection starvation — AD channel in DSC direction |

**GNR → DMR mapping:**
- `TXN_STARVED.ASQ/DC` → `UNC_CMS_RX_INJ_STARVED_DSC.AD`
- `STALL_NO_EGR_CRD.ANY` → `UNC_CMS_STALL_NO_EGR_CREDIT_AD.TXMESHID0`

### 5.5 Interconnect Transaction Controller (ITC) — UNC_ITC_*

1099 events — PCIe/CXL inbound traffic controller.

**For iperf3 / PCIe NIC analysis:**
- IO write bandwidth metric sources from ITC (4B granularity — note the ×4 not ×64)
- `UNC_ITC_CLOCKTICKS` — reference clock for ITC normalization

### 5.6 On-Tile Controller (OTC) — UNC_OTC_*

- IO read bandwidth metric sources from OTC (64B granularity)
- `metric_IO read bandwidth (MB/sec) = UNC_OTC_reads * 64 / 1e6`

### 5.7 Scalable Caching Agent (SCA) — UNC_SCA_*

Replaces the GNR IIO (I/O Traffic Controller).

- `metric_IO read miss SCA %` — % of IO reads missing SCA cache
- `metric_IO write miss SCA %` — % of IO writes missing SCA cache
- High SCA miss rate = PCIe device data not cached → high DRAM pressure from NIC DMA

### 5.8 CXL Coherence Manager (CXLCM) — New in DMR

| Event | Meaning |
|-------|---------|
| `UNC_CXLCM_CLOCKTICKS` | Reference clock (lfclk) |
| `UNC_CXLCM_TX_256B.*` | 256B TX transactions → BW = count × 256B |
| `UNC_CXLCM_RX_FLITS.*` | Received flits from CXL device |
| `UNC_CXLCM_TX_FLITS.*` | Transmitted flits to CXL device |
| `UNC_CXLCM_TX_BACK_PRESSURE.*` | TX backpressure (congestion from CXL fabric) |
| `UNC_CXLCM_RX_AGF_INSERTS` | RX buffer inserts |
| `UNC_CXLCM_RX_AGF_OCCUPANCY` | RX buffer occupancy |

`metric_CXL_bandwidth_inbound/outbound` both use `count * 64 / 1e6`.

---

## 6. DMR Architecture: Key Differences from GNR

### 6.1 CBB (Cache Building Block) — 4 independent rings

DMR has 4 CBBs instead of GNR's single uncore frequency ring.
- Each CBB has its own frequency (monitored independently via `metric_uncore CBB0..3 frequency GHz`)
- Events referencing "same CBB" vs "other CBB" describe intra- vs cross-ring scope
- Cross-CBB coherence is more expensive than same-CBB hit

**Implication for iperf3:** NIC DMA vectors may land in different CBBs than IRQ-handling cores → cross-CBB snoop traffic visible in LLC HITM counters.

### 6.2 IMH (Integrated Memory Hub) — Replaces Direct IMC

DMR interposes an IMH (IMH0/IMH1) between the mesh and the 16 DDR5 channels.
- IMH0: 8 channels, IMH1: 8 channels
- HAMVF tracks reads/writes at the IMH level before dispatching to IMC
- Key difference: no more direct RPQ/WPQ visibility (GNR's UNC_M_RPQ_INSERTS is gone)

### 6.3 DDR5 Sub-channels (PCH0/PCH1)

Each DMR memory channel has 2 sub-channels (PCH0, PCH1).
- `UNC_M_CAS_COUNT.PCH0_RD` / `PCH1_RD` — per sub-channel granularity
- Aggregate total: `UNC_M_CAS_COUNT.RD` = PCH0_RD + PCH1_RD

### 6.4 CXL-Native Platform (First CXL-First Intel Server)

8 memory regions: MEM_REGION_0..3 = DDR, MEM_REGION_4..7 = CXL T2/T3.
- OMR events broken out per region: `OMR.DEMAND_DATA_RD.MEM_REGION_4`
- HAMVF tracker inserts broken by type: DDR vs CXL T2 vs CXL T3

### 6.5 ESF Cache Line State (New Coherence Terminology)

ESF = Exclusive / Shared / Forward (new state machine for DMR cross-core sharing).
- `L3_HITESF_*` = line is in ESF state (clean, shareable)
- `L3_HITM_*` = line is Modified (dirty, exclusive)
- **HITM is expensive** (requires ownership transfer); **HITESF is cheap** (forward clean copy)

---

## 7. GNR → DMR Critical Event Renames (Quick Reference)

| GNR Event | DMR Equivalent | Status |
|-----------|----------------|--------|
| `RESOURCE_STALLS.ANY` | `BE_STALLS.ANY` | Renamed prefix |
| `RESOURCE_STALLS.SB` | `BE_STALLS.SB` | Renamed prefix |
| `IDQ_UOPS_NOT_DELIVERED.CORE` | `IDQ_BUBBLES.CORE` | Renamed |
| `DECODE.MS` | `DECODE.MS_BUSY` | Renamed |
| `BR_MISP_RETIRED.INDIRECT` | `BR_MISP_RETIRED.NEAR_INDIRECT` | Renamed |
| `OFFCORE_REQUESTS.*` | `OFFMODULE_REQUESTS.*` | Prefix change |
| `OFFCORE_REQUESTS_OUTSTANDING.*` | `OFFMODULE_REQUESTS_OUTSTANDING.*` | Prefix change |
| `OFFCORE_RESPONSE.*` | `OMR.*` (offcore JSON) | New format |
| `MEM_LOAD_RETIRED.L3_MISS` | `OMR.DEMAND_DATA_RD.L3_MISS` | Moved to offcore |
| `UNC_M_RPQ_INSERTS` | `UNC_HAMVF_HA_IMC_READS_COUNT` | Structural change |
| `UNC_M_WPQ_INSERTS` | `UNC_HAMVF_HA_IMC_WRITES_COUNT.FULL` | Structural change |
| `TXN_STARVED.ASQ/DC` | `UNC_CMS_RX_INJ_STARVED_DSC.*` | New unit/name |
| `STALL_NO_EGR_CRD.ANY` | `UNC_CMS_STALL_NO_EGR_CREDIT_AD.*` | New unit/name |
| `UNC_IIO_DATA_REQ_*` | `UNC_ITC_*` + `UNC_SCA_*` | Split across 2 units |

---

## 8. iperf3 + EMON: Key Counter Set for Network Workload Investigation

### 8.1 Must-have core counters (IRQ cores)

```
INST_RETIRED.ANY              # instruction throughput
CPU_CLK_UNHALTED.THREAD       # unhalted cycles (denominator)
CPU_CLK_UNHALTED.REF_TSC      # ref cycles (for freq calculation)
TOPDOWN.SLOTS                 # total slots
TOPDOWN.BACKEND_BOUND_SLOTS   # slots lost to backend stalls
TOPDOWN.MEMORY_BOUND_SLOTS    # slots lost to memory
CYCLE_ACTIVITY.STALLS_L3_MISS # stall cycles from LLC miss (→ DRAM)
OFFMODULE_REQUESTS.ALL_REQUESTS   # total L3+ requests
OFFMODULE_REQUESTS_OUTSTANDING.DEMAND_DATA_RD  # queue depth signal
```

### 8.2 Must-have uncore counters

```
# Memory (per channel):
UNC_M_CAS_COUNT.RD            # → metric_memory bandwidth read
UNC_M_CAS_COUNT.WR            # → metric_memory bandwidth write
UNC_M_ACT_COUNT.ALL           # row activations (page miss proxy)

# IO bandwidth (via OTC/ITC):
[collected by -collect-edp automatically]

# Interrupt rate:
UNC_CNCU_NCU_INTERRUPTS_TYPE  # → metric_IO MSI per sec

# Mesh stalls (if investigating PCIe bandwidth ceiling):
UNC_CMS_STALL_NO_EGR_CREDIT_AD.TXMESHID0..15
UNC_CMS_RX_INJ_STARVED_ASC.AD
```

### 8.3 DMR-Q9UC theoretical ceilings (baseline for anomaly detection)

| Resource | Ceiling | Formula |
|----------|---------|---------|
| Memory BW | 1,024 GB/s | 16ch × 8000 MT/s × 8B |
| DDR5 data rate | 8000 MT/s | 16 × 24GB DIMMs, DDR5-8000 |
| Per-link PCIe | ~400 Gbps | PCIe Gen6 × 16 lanes |
| 4-link aggregate | ~1,400 Gbps | eth1+2+3+4 measured baselines |
| Per-port measured | 353–365 Gbps | eth1=365, eth2=365, eth3=356, eth4=353 |
| IPC (max efficiency) | ~4.0 | 4-wide issue PantherCove |
| Typical IRQ IPC | 0.5–1.5 | for network interrupt processing |

---

## 9. N/A Values in DAT Files — Critical Parser Note

On DMR (hybrid P-core + E-core), events not applicable to a core type appear as
literal `"N/A"` in `.dat` files instead of a numeric count.

```
# Example dat line:
UOPS_EXECUTED.STALLS  TSC  count0..count11  N/A  N/A  N/A  N/A  (e-cores)
```

Any dat parser MUST:
```python
# WRONG:
int(val.replace(',',''))

# CORRECT:
if val == 'N/A':
    continue  # skip, don't sum
else:
    int(val.replace(',',''))
```

---

## 10. Visibility Levels (what appears in which outputs)

| Visibility | Meaning |
|------------|---------|
| `NDA` | Available in EDP output; appears in xlsx with standard event collection |
| `Private` | Internal Intel only; may appear in EDP xlsx with private event files |
| `PMEOnly` | Only visible via raw PME collection, not through EDP metrics |

Of 111 computed metrics: ~40 are `NDA` (available to us), ~71 are `Private` (Intel-internal but visible since we have the private event files).

---

*Compiled from DMR PantherCove PMon JSON files, Feb 2026 build.*
*Reference notes in `DMR_EMON_reference_notes.txt` (667 lines) for GNR→DMR migration mapping.*
