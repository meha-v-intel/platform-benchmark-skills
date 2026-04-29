---
name: iperf-analysis
description: "Analyze DMR iperf performance with EMON, identify key counter shifts, infer likely root causes (lock/coherence, DTLB, IRQ/NUMA, PCIe), and propose tuning plus follow-up experiments. Use when troubleshooting sub-target aggregate throughput or regressions across kernel/config changes."
argument-hint: "Provide result directory or experiment summary. Include kernel version, stream count, and target throughput if available."
allowed-tools:
  - Bash
---

# DMR iperf Analysis Skill

This skill is optimized for DMR storage-network validation and extends the storage-iperf3 workflow with DMR private EDP files and root-cause attribution logic.

## Scope

Use this skill when you need to:
- explain why aggregate throughput is below target
- compare behavior across kernels or tuning sets
- decide whether bottleneck is software lock/coherence, TLB, IRQ spread, NUMA placement, or PCIe/link configuration
- generate decision actions and validation experiments

## Required Inputs

- iperf results under multiple configurations (streams, MTU, coalescing, affinity, kernel)
- DMR EMON raw data from both server and client
- DMR private EDP files:
  - C:/Users/awzhang/OneDrive - Intel Corporation/Documents/DCG/platforms/DMR/validation/networking/diamondrapids_server_private.xml
  - C:/Users/awzhang/OneDrive - Intel Corporation/Documents/DCG/platforms/DMR/validation/networking/diamondrapids_server_events_private 3.txt

Optional but strongly recommended:
- chart_format_diamondrapids_server_private.txt
- pre/post ethtool -S and /proc/interrupts snapshots
- numastat pre/post

## Step 1: Start From Throughput Matrix

Build a table first. Do not start from EMON.

Minimum columns:
- run_id
- kernel_version
- role (server/client)
- link_mode (single, aggregate, bidir)
- stream_count
- mtu
- tcp_window
- rx_usecs
- queue_count
- irq_affinity_profile
- tx_gbps
- rx_gbps
- aggregate_gbps

Interpretation rules:
- if throughput rises with P then plateaus early, check queue/IRQ/core distribution
- if throughput insensitive to P and stuck low, check PCIe/MTU/socket buffer gates first
- if kernel is only changed variable and shift is repeatable, prioritize software root-cause path

## Step 2: Hard Preflight Gates (Must Pass)

Before deep EMON interpretation, verify:
- PCIe LnkSta at expected generation and width, not downgraded
- MTU 9000 on all benchmark ports
- tcp rmem/wmem max large enough for test window
- queue count not below active stream parallelism
- IRQ affinity spread across NUMA-local cores
- no stale iperf3 processes consuming CPU

If any gate fails, fix gate first and rerun. Do not assign microarchitectural root cause yet.

## Step 3: EMON Collection and Post-Processing (DMR Private EDP)

Use the DMR private event and metric files above during collection and post-processing.

Collection guideline:
- collect on both systems
- run EMON continuously over grouped tests rather than one file per subtest
- capture pre/post NIC stats, IRQ, and numastat in same run folder

Post-processing guideline:
- generate socket/core/thread/uncore views
- keep one summary table per run with selected metrics below

## Step 4: Key Metric Domains for Root Cause

### A) Core Efficiency and Stall Signature

Primary metrics:
- metric_core IPC
- metric_CPI
- metric_CPU utilization %
- metric_TMA_Backend_Bound(%)
- metric_TMA_Core_Bound(%)
- metric_TMA_Memory_Bound(%)

Interpretation:
- CPI up + IPC down + Core_Bound up indicates execution blocked by contention/serialization more than raw DRAM saturation

### B) Lock/Coherence and RFO Path

Primary events/metrics:
- CPU_CLK_UNHALTED.PAUSE
- CPU_CLK_UNHALTED.PAUSE_INST
- metric_core pause per instr (if present)
- UNC_SNCU_LOCK_CYCLES
- UNC_CBO_TOR_ALLOCATION.MISS_READFOROWNERSHIP
- UNC_CBO_TOR_ALLOCATION.MISS_RFO_PREF
- UNC_CBO_TOR_ALLOCATION.MISS_LLCPREFRFO
- LLC demand RFO miss latency metric

Interpretation:
- high pause plus rising RFO miss traffic and/or RFO miss latency supports lock contention and cache-line ownership ping-pong

### C) DTLB/Page-Walk Path

Primary events/metrics:
- DTLB_LOAD_MISSES.WALK_COMPLETED
- DTLB_STORE_MISSES.WALK_COMPLETED
- DTLB_LOAD_MISSES.WALK_ACTIVE
- DTLB_STORE_MISSES.WALK_ACTIVE
- DTLB load/store miss latency metrics

Interpretation:
- latency alone is insufficient; require miss-rate increase and cycle-cost contribution
- if miss rate is flat but latency rises modestly, likely secondary effect

### D) IO/Uncore Pressure

Primary metrics/events:
- metric_IO read BW (MB/sec)
- metric_IO write BW (MB/sec)
- metric_IO read miss % (SCA)
- metric_IO MSI per sec
- UNC_ITC_*
- UNC_OTC_*
- UNC_SCA_*

Interpretation:
- use to distinguish NIC/IO path saturation versus software-core bottleneck

## Step 5: Decision Logic for RFO vs DTLB vs Config

Use this order:
1. preflight gate failure present -> fix gate, rerun
2. if pause and lock/coherence counters surge with throughput drop -> primary lock/coherence path
3. if DTLB miss rate and walk-active cycles surge enough to explain lost cycles -> primary translation path
4. if neither dominates but MSI/IRQ skew is severe -> primary interrupt distribution/coalescing path

Attribution rule:
- do not conclude from latency-only metrics
- use stall cost concept:
  - RFO_cost ~ RFO_miss_rate * RFO_miss_latency
  - DTLB_cost ~ DTLB_miss_rate * DTLB_miss_latency
- dominant cost should align with throughput delta direction across runs

## Step 6: Kernel Regression A/B Method (Critical)

For kernel comparisons (for example 6.8 vs newer):
- keep all non-kernel variables fixed
- run at least 3 repetitions per configuration
- compare medians and spread, not single-run peak
- collect same EMON domains and telemetry files each run

Conclusion quality levels:
- weak: only latency changed
- medium: latency + frequency changed
- strong: frequency, latency, and stall-cost changed consistently with throughput

## Step 7: Actionable Tuning Recommendations

When lock/coherence dominated:
- reduce lock sharing and cross-core ownership transfers
- tighten IRQ and worker affinity to NUMA-local partitions
- increase queue sharding and reduce cross-queue contention
- test kernel spinlock fix/backport branch

When translation dominated:
- enable/expand hugepages for relevant buffers
- reduce page churn and allocator fragmentation
- retest DTLB walk activity and miss rates

When IRQ/MSI dominated:
- tune coalescing (for example rx-usecs)
- spread IRQs across more local cores
- verify NIC queue count and ring depth

## Step 8: Experiment Plan to Nail Root Cause

Run this exact sequence:
1. baseline current kernel and current knobs
2. same knobs plus known-good kernel
3. current kernel plus lock-mitigation tuning
4. current kernel plus hugepage/TLB-focused tuning
5. best-kernel plus best-knob combination

For each run, produce:
- throughput summary row
- key metric deltas versus baseline
- attribution verdict: lock/coherence, TLB, IRQ/NUMA, PCIe, or mixed

## Required Output Format

Always return:
1. throughput comparison table
2. top shifted EMON metrics grouped by domain
3. root-cause confidence statement (high/medium/low)
4. prioritized remediation list
5. next 3 experiments with expected confirming signals

## DMR Naming Reminder

Use DMR event names from the private files above. Do not rely on GNR-only aliases.
If event names differ between environments, map by metric intent (RFO ownership, DTLB walk, IO miss, MSI rate) and document mapping explicitly.
