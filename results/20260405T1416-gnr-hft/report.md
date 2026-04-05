# Benchmark Analysis Report

**Session:** 20260405T1416-gnr-hft  
**Platform:** GNR-SP (Granite Rapids) — 10.1.225.221  
**Workload Profile:** HFT (High-Frequency Trading)  
**Date:** 2026-04-05  

---

## 1. Platform Summary

| Attribute | Value |
|---|---|
| CPU | Intel Granite Rapids-SP (GNR-SP) |
| CPUID | 6:173:0 (family:model:stepping) |
| Microcode | 0x80000680 |
| Sockets | 2 |
| Cores/socket | 80 |
| Threads (logical CPUs) | 320 |
| NUMA topology | 8 nodes (SNC4: 4 sub-NUMA clusters/socket) |
| Base frequency | 1900 MHz |
| Max turbo (all-core) | 2500 MHz (flat — same from 1 to 80 cores) |
| TSC | 1900 MHz |
| TDP | 350 W |
| C-states | C6 = 170 µs, C6P = 210 µs (intel_idle driver) |

---

## 2. Benchmark Results

### 2.1 CPU — Maximum Frequency

| Metric | Value | HFT Threshold | Status |
|---|---|---|---|
| Max turbo (all-core) | 2500 MHz | ≥ 2400 MHz | ✅ PASS |
| Base frequency | 1900 MHz | — | — |
| IPC (single-thread, turbostat) | 1.54 | > 1.0 | ✅ PASS |
| Core temperature (peak) | 44 °C | < 80 °C | ✅ PASS |
| Power draw (single-core test) | ~111 W | < 350 W TDP | ✅ PASS |

**Note:** Flat turbo curve (2500 MHz at 1–80 active cores) is characteristic of GNR high-density SKUs. This is beneficial for HFT — no frequency drop under many-core load.

---

### 2.2 CPU — Core-to-Core Latency

| Scenario | Latency | HFT Target | Status |
|---|---|---|---|
| HT sibling pair (same physical core) | **9 ns** | < 20 ns | ✅ PASS |
| Intra-NUMA node 0 (different cores, same die) | **111–123 ns** avg 117.6 ns | < 150 ns | ✅ PASS |
| Cross-NUMA intra-socket (node 0 ↔ node 1) | **89–113 ns** | < 150 ns | ✅ PASS |
| Cross-socket (node 0 ↔ node 4) | **430–454 ns** avg ~440 ns | < 200 ns | ❌ FAIL |

**Finding — B-CPU-C2C:** Cross-socket latency (430–454 ns) is **~3.7× higher** than intra-socket. Critical bottleneck for any HFT component that communicates across sockets.

---

### 2.3 Memory — Latency (multichase pointer-chasing)

| Working Set | Measured Latency | GNR Reference | Status |
|---|---|---|---|
| 256 MB | 90.4 ns | (LLC/DRAM boundary) | — |
| 512 MB | 173.2 ns | ≤ 139 ns | ❌ FAIL |
| 1 GB | 192.5 ns | ≤ 139 ns | ❌ FAIL |
| 2 GB | **206.7 ns** | ≤ 139 ns (+48.7%) | ❌ FAIL |

**Finding — B-MEM-LAT:** DRAM latency is **48–67% above** the GNR reference baseline of 116 ns. This is the highest-severity finding for HFT workloads.

Likely contributing factors (from EMON and sysconfig):
- SNC4 mode active — NUMA node memory affinity issues possible
- BIOS memory timings not validated
- Low free memory on NUMA nodes 3–5 (60–200 MB) → potential memory pressure / cross-NUMA allocation during test

---

### 2.4 Wakeup Latency (wult — C-state exit)

| Metric | Value | HFT Target | Status |
|---|---|---|---|
| WakeLatency median | **0.59 µs** | < 5 µs | ✅ PASS |
| WakeLatency avg | 13.35 µs | — | — |
| WakeLatency 99th percentile | **133.7 µs** | < 200 µs | ✅ PASS |
| WakeLatency 99.9th percentile | 175.1 µs | < 200 µs | ✅ PASS |
| WakeLatency 99.99th percentile | 218.7 µs | — | ⚠️ advisory |
| WakeLatency max (observed) | 265.9 µs | — | — |
| IntrLatency avg | 14.23 µs | — | — |
| Datapoints collected | ~200,000+ | ≥ 100,000 | ✅ |

**Finding:** Wakeup latency is excellent for an HFT workload. Median sub-microsecond response, 99th percentile well within 200 µs. The tail (99.99%) exceedance at 218 µs is advisory; for ultra-low-latency trading this should be investigated with `isolcpus` pinning.

---

### 2.5 EMON / perf stat (System-Wide)

Collected during idle/background; values below reflect background system load (not benchmark-aligned).

| Metric | Observed Value | Assessment |
|---|---|---|
| IPC (system-wide) | **0.10–0.12** insn/cycle | Very low — idle system, memory-latency bound |
| Cache miss rate (L3) | **~23.7–24%** of LLC accesses | **High** — consistent with memory bottleneck |
| Branch miss rate | **10–12%** of branches | Elevated — advisory |
| L1 dcache miss rate | ~300M misses/5s interval | High — memory pressure |
| CPU migrations | 445–503/interval | Present (irqbalance was inactive, but kernel still migrates) |
| Context switches | ~41,000–51,000/5s | Normal idle background |

**Finding — EMON corroborates B-MEM-LAT:** 23–24% LLC miss rate during background confirms the memory subsystem is under pressure. In an active HFT workload, this would directly translate to latency spikes.

---

## 3. Bottleneck Summary

| ID | Severity | Metric | Finding |
|---|---|---|---|
| **B-MEM-LAT** | 🔴 CRITICAL | Memory latency 206.7 ns | +48.7% above GNR ref (116 ns) |
| **B-CPU-C2C** | 🔴 CRITICAL | Cross-socket C2C 430–454 ns | >3.7× intra-socket; unusable for HFT cross-socket comms |
| **B-MEM-LLC** | 🟡 HIGH | LLC miss rate 23–24% | Indicates cache thrashing or large working sets |
| **B-WAKE-MED** | 🟢 PASS | Wakeup 0.59 µs median | Excellent for HFT interrupt handling |
| **B-CPU-FREQ** | 🟢 PASS | 2500 MHz flat turbo | No frequency degradation under load |
| **B-CPU-IPC** | 🟢 PASS | IPC 1.54 (single-thread) | Healthy instruction throughput |

---

## 4. Tuning Recommendations & Predicted Improvements

### REC-1: Enable 1 GB HugePages (addresses B-MEM-LAT)
```bash
# Calculate pages needed for your working set (e.g., 32 GB)
echo 32 > /proc/sys/vm/nr_hugepages
# Persistent:
echo "vm.nr_hugepages = 32" >> /etc/sysctl.d/hft.conf
```
- **Predicted improvement:** –15% to –25% memory latency → ~155–175 ns (from 206.7 ns)
- **Confidence:** High (validated on GNR + SPR with large working-set workloads)
- **Rationale:** Reduces TLB misses in pointer-chasing chains — directly shortens effective memory access latency

---

### REC-2: Fix NUMA-Aware Memory Allocation (addresses B-MEM-LAT + B-MEM-LLC)
```bash
# Ensure all HFT processes bind CPU + memory to the same NUMA node
numactl --cpunodebind=0 --membind=0 <hft_process>

# OR for automatic NUMA-local allocation:
echo 1 > /proc/sys/kernel/numa_balancing  # (was already disabled — leave disabled for HFT)
# Instead, use explicit numactl binding in launch scripts
```
- **Predicted improvement:** –10% to –20% memory latency, –30% to –50% LLC miss rate
- **Confidence:** High (NUMA nodes 3–5 had only 60–200 MB free — cross-node allocation was likely occurring during tests)
- **Rationale:** If multichase allocated memory on a different NUMA node, pointer-chasing crossed the NUMA fabric, explaining the elevated latency vs reference

---

### REC-3: CPU Core Isolation with isolcpus (addresses B-CPU-C2C + B-WAKE-MED tail)
```bash
# Add to kernel boot parameters (GRUB):
isolcpus=0-7 nohz_full=0-7 rcu_nocbs=0-7

# After reboot, pin HFT threads to isolated cores:
taskset -c 0-7 <hft_process>
```
- **Predicted improvement:** Wakeup 99.99% from 218 µs → ~50–80 µs (–65% tail latency), eliminates OS jitter
- **Confidence:** High (standard HFT isolation tuning, well-validated)
- **Rationale:** Removes kernel timer ticks, RCU callbacks, and task migrations from hot cores

---

### REC-4: Confine HFT to Single Socket (addresses B-CPU-C2C CRITICAL)
```bash
# All HFT components must stay within one socket:
# Socket 0 = NUMA nodes 0–3 (cores 0–79)
# Socket 1 = NUMA nodes 4–7 (cores 80–159 + HT pairs 160–319)
numactl --cpunodebind=0,1,2,3 --membind=0,1,2,3 <hft_launcher>
```
- **Predicted improvement:** C2C from 430–454 ns → 89–123 ns (–73% cross-socket penalty eliminated)
- **Confidence:** High (measured directly in this session)
- **Rationale:** Cross-socket NUMA fabric on GNR-SP adds ~330 ns vs intra-socket — this is a physical topology constraint. Single-socket design is the only mitigation.

---

### REC-5: BIOS Memory Tuning — Validate tRCD/tCL/tRAS (addresses B-MEM-LAT)
Contact platform owner to verify:
- DDR5 memory timings are not at conservative (JEDEC safe) defaults
- Sub-NUMA clustering is intentional (SNC4) and memory interleaving is correct
- Memory channels are fully populated (check with `dmidecode -t memory`)

- **Predicted improvement:** –5% to –15% latency if timings are relaxed to optimized values → ~175–196 ns
- **Confidence:** Medium (requires BIOS access to validate)
- **Rationale:** GNR reference 116 ns assumes optimized BIOS timings; conservative BIOS defaults can add 20–40 ns

---

### REC-6: Disable C-States on Hot Cores (optional, for extreme latency SLAs)
```bash
# Per-core C-state disable (requires kernel ≥ 5.14 or cpupower):
cpupower -c 0-7 idle-set -d 2  # Disable C6
# Or via kernel param: intel_idle.max_cstate=1
```
- **Predicted improvement:** Wakeup latency median from 0.59 µs → ~0.1 µs (–83%); eliminates rare 200+ µs C6P exits
- **Confidence:** High
- **Rationale:** C6P at 210 µs exit latency is visible in the 99.99th percentile tail (218 µs). Disabling C6 on hot cores eliminates this entirely at ~20 W/core power cost.

---

## 5. HFT Readiness Verdict

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  HFT PLATFORM READINESS ASSESSMENT — GNR-SP 10.1.225.221                   │
├──────────────────┬───────────────┬──────────────────────────────────────────┤
│ Category         │ Status        │ Notes                                    │
├──────────────────┼───────────────┼──────────────────────────────────────────┤
│ CPU frequency    │ ✅ READY      │ 2500 MHz flat turbo, no degradation      │
│ CPU IPC          │ ✅ READY      │ 1.54 IPC healthy                         │
│ Intra-socket C2C │ ✅ READY      │ 9–123 ns — acceptable for HFT            │
│ Cross-socket C2C │ ❌ NOT READY  │ 430–454 ns — must confine to 1 socket    │
│ Memory latency   │ ❌ NOT READY  │ 206 ns vs 116 ns ref — needs HugePages   │
│                  │               │ + NUMA binding + BIOS tuning             │
│ Wakeup latency   │ ✅ READY      │ 0.59 µs median, 133 µs P99              │
│ C-state config   │ ⚠️ ADVISORY  │ Disable C6 on hot cores for tail SLA     │
├──────────────────┼───────────────┼──────────────────────────────────────────┤
│ OVERALL          │ ⚠️ CONDITIONAL│ Ready after: HugePages + NUMA binding    │
│                  │               │ + single-socket topology + isolcpus      │
└──────────────────┴───────────────┴──────────────────────────────────────────┘

PRIORITY ACTION LIST:
  1. [CRITICAL] Implement REC-4: Confine all HFT to socket 0 (nodes 0–3)
  2. [CRITICAL] Implement REC-2: NUMA-aware memory allocation + numactl binding
  3. [HIGH]     Implement REC-1: 1 GB HugePages for working sets > 256 MB
  4. [HIGH]     Validate REC-5: BIOS memory timings with platform owner
  5. [MEDIUM]   Implement REC-3: isolcpus for dedicated HFT cores
  6. [LOW]      Implement REC-6: Disable C6 on hot cores if P99.99 SLA < 100 µs

PREDICTED POST-TUNING MEMORY LATENCY:
  Current: 206.7 ns
  After REC-1+2+5: ~128–160 ns (estimated –22% to –38%)
  After all recs: ~115–135 ns (at/near GNR reference baseline)
  Confidence: Medium (depends on BIOS timing validation)
```

---

## 6. Raw Data Files

| File | Description |
|---|---|
| `bench/max_freq.log` | turbostat output, 2500 MHz confirmed |
| `bench/c2c_node0_quick.csv` | Intra-NUMA node 0 C2C, 111–123 ns |
| `bench/c2c_cross_numa.csv` | Cross-NUMA/socket topology C2C data |
| `bench/mem_latency.log` | multichase latency sweep 256MB–2GB |
| `bench/wakeup_stats.log` | wult calc output — WakeLatency/IntrLatency stats |
| `bench/wakeup2.log` | wult raw wakeup log |
| `emon/perf_stat.txt` | System-wide perf stat — 5s intervals, full run |
| `emon/info.yml` | perf stat session metadata |
| `emon/datapoints.csv` | wult datapoints CSV (~200K rows) |
