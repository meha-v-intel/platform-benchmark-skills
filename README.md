# Platform Benchmark Skills — Storage Segment

**Branch:** `storage-skills`  
**Scope:** GitHub Copilot CLI skills for Intel Storage Segment Validation (DMR platform)  
**Audience:** Engineers validating Diamond Rapids (DMR) systems against the Storage Segment spec  
**Platform verified on:** DMR-Q9UC (160-core, 2-socket, DDR5-8000, PCIe Gen6, 4×400GbE CX7/CX8)

> For CPU, memory, AMX, and wakeup benchmark skills, see the `main` branch.

---

## Overview

This branch contains **12 Copilot CLI skills** covering Intel Storage Segment Validation Tests 101–117.
Each skill automates a workload end-to-end: prerequisites, benchmark execution, output parsing,
pass/fail evaluation, and EMON-based hardware telemetry collection.

| Category | Skills | Tests covered |
|---|---|---|
| **Memory & CPU micro** | `storage-mlc`, `storage-c2c` | 101, 102 |
| **Crypto & compression** | `storage-encryption`, `storage-compression`, `storage-erasure-coding`, `storage-hashing` | 104–107 |
| **Network** | `storage-iperf3` | 108 |
| **Storage I/O** | `storage-fio`, `storage-fio-solo-dmr` | 109–113 |
| **Object storage** | `storage-minio` | 117 |
| **Methodology / tooling** | `emon-workload-sweep`, `benchmark-ssh-orchestration` | cross-cutting |

---

## Skills Reference

### Test 101 — Memory Subsystem (MLC)
**Skill:** [`storage-mlc`](.github/skills/storage-mlc/SKILL.md) · 539 lines · 100% coverage · ✅ Live-tested on DMR

Runs Intel MLC across 7 groups (idle latency, latency matrix, bandwidth matrix, peak injection BW,
loaded latency curve, cache-to-cache, bandwidth scan). All 92 subtests documented with live DMR baselines.

| Key baselines (DMR) | Value |
|---|---|
| Idle DRAM latency | 212–214 ns |
| Peak read bandwidth (AVX-512) | ~48.7 GB/s |
| AVX-512 mixed R/W | ~54.5 GB/s |

---

### Test 102 — Intra-Socket Core-to-Core Latency
**Skill:** [`storage-c2c`](.github/skills/storage-c2c/SKILL.md) · 420 lines · 100% coverage · ✅ Live-tested on DMR

Builds and runs [`nviennot/core-to-core-latency`](https://github.com/nviennot/core-to-core-latency) to
produce a full N×N latency matrix. Includes EMON collection (`xsnp_hitm` — MESIF coherency hand-off counter).

| Key baselines (DMR 32-core) | Value |
|---|---|
| Min latency (HT siblings) | 19.7 ns |
| Max latency (distant mesh) | 115.4 ns |
| Mean | 91.8 ns |

---

### Test 104 — Encryption / Decryption (AES-256-GCM)
**Skill:** [`storage-encryption`](.github/skills/storage-encryption/SKILL.md) · 373 lines · 100% SW coverage · ✅ Live-tested on DMR

Sweeps 26 buffer sizes (64B → 1 GiB) using OpenSSL AES-256-GCM with AES-NI. QAT hardware
subtests out-of-scope (documented). EMON collects `fp_arith_inst_retired.512b_packed_single` as VAES proxy.

| Key baselines (DMR) | Value |
|---|---|
| Peak throughput | 11.97 GB/s (~2 MiB buf) |
| DRAM-bound floor | 10.32 GB/s (1 GiB buf) |

---

### Test 105 — Compression / Decompression
**Skill:** [`storage-compression`](.github/skills/storage-compression/SKILL.md) · 683 lines · 100% public codec coverage · ✅ Live-tested on DMR

Three codec groups: lz4 (levels 1–9 × 3 corpora), pigz/zlib (levels 1/6/9 × thread counts 1–NPROC),
zstd (levels 1–9 × corpora). Intel minLZ subtests require internal tool — excluded with callout note.

| Key baselines (DMR) | Value |
|---|---|
| lz4 l1 compress (text) | 408 MB/s |
| lz4 l1 decompress (text) | 3,609 MB/s |
| pigz l1 p32 | 3,350 MB/s |
| zstd l3 compress | 227 MB/s |

---

### Test 106 — Erasure Coding (Reed-Solomon)
**Skill:** [`storage-erasure-coding`](.github/skills/storage-erasure-coding/SKILL.md) · 499 lines · 100% coverage · ✅ Live-tested on DMR

Builds [`intel/isa-l`](https://github.com/intel/isa-l) from source and runs `erasure_code_perf` /
`gf_vect_mul_perf`. Primary config RS 10+4; config sweep 4+2/8+3/10+4/12+4; buffer size sweep 64K–16M.
AVX-512 GFNI dispatch confirmed.

| Key baselines (DMR, AVX-512 GFNI) | Value |
|---|---|
| RS 10+4 encode | 35,599 MB/s |
| RS 10+4 decode | 51,592 MB/s |
| GF-256 multiply | 26,573 MB/s |

---

### Test 107 — Hashing
**Skill:** [`storage-hashing`](.github/skills/storage-hashing/SKILL.md) · 564 lines · ~88% coverage · ✅ Live-tested on DMR

SHA-256 and SHA-512 26-point buffer sweeps via OpenSSL (`speed`). Extended hash suite via
[SMHasher3](https://gitlab.com/fwojcik/smhasher3) (built from source, 336 hashes). SHA-NI hardware
acceleration confirmed on all cores.

| Key baselines (DMR) | Value |
|---|---|
| SHA-256 peak | 2.627 GB/s (1 GiB buf) |
| SHA-512 peak | 0.729 GB/s |
| XXH3-64 (AVX-512) | 134.86 GiB/s |
| CRC-32C | 34.42 GiB/s |
| MeowHash (AES-NI) | 115.61 GiB/s |

---

### Test 108 — Network Bandwidth / Latency (iperf3)
**Skill:** [`storage-iperf3`](.github/skills/storage-iperf3/SKILL.md) · 1,157 lines · 98% coverage · ✅ **Live-tested on DMR-Q9UC S1↔S2 pair**  
**Skill README:** [`.github/skills/storage-iperf3/README.md`](.github/skills/storage-iperf3/README.md)

The most detailed skill in this branch. Validated on a real two-system DMR-Q9UC pair
(S1: `sc00901168s0095`, S2: `sc00901168s0097`) with 4×400GbE Mellanox CX8 NICs, PCIe Gen6.

#### Topology
```
S1 (SERVER)                                   S2 (CLIENT)
┌──────────────────────────────┐              ┌──────────────────────────────┐
│  CX8 #1 (socket 0, 0000:61) │              │  CX8 #1 (socket 0, 0000:61) │
│  eth1: 400GbE ◄──── Link 1 ────────────────►  eth1: 400GbE               │
│  eth2: 400GbE ◄──── Link 2 ────────────────►  eth2: 400GbE               │
│                              │              │                              │
│  CX8 #2 (socket 1, 0001:11) │              │  CX8 #2 (socket 1, 0001:11) │
│  eth3: 400GbE ◄──── Link 3 ────────────────►  eth3: 400GbE               │
│  eth4: 400GbE ◄──── Link 4 ────────────────►  eth4: 400GbE               │
└──────────────────────────────┘              └──────────────────────────────┘
           4-port aggregate target: ≥ 1,400 Gbps
```

#### Live baselines (DMR-Q9UC, PCIe Gen6, IRQ affinity applied)
| Port | Throughput | NIC slot | PCIe domain |
|---|---|---|---|
| eth1 | **365 Gbps** | CX8 #1, port 0 | `0000:61:xx`, socket 0 |
| eth2 | **365 Gbps** | CX8 #1, port 1 | `0000:61:xx`, socket 0 |
| eth3 | **356 Gbps** | CX8 #2, port 0 | `0001:11:xx`, socket 1 |
| eth4 | **353 Gbps** | CX8 #2, port 1 | `0001:11:xx`, socket 1 |
| **4-port aggregate** | **~1,400 Gbps** | all simultaneous | Gen6 ×16 per slot |

#### Test groups
| Group | Subtests | Description |
|---|---|---|
| A | 108.001–006 | Single-stream TCP Tx / Rx / BiDir per link (baseline) |
| B | 108.007–014 | Multi-stream -P8 / -P16 TCP per link (line-rate saturation) |
| C | 108.015–018 | Both links simultaneously — NIC aggregate throughput |
| D | 108.019–022 | UDP jitter and line-rate packet loss |
| E | 108.023–026 | 60-second sustained stability (thermal/clock sag) |
| F | 108.F.1–16 | Config sweep: MTU · streams · TCP window · IRQ coalescing · CCA |
| EMON | — | `perf stat` on both systems throughout all groups |

#### Quick diagnosis
| Result | Most likely cause | Fix |
|---|---|---|
| < 250 Gbps | MTU 1500 (jumbo frames off) | `ip link set $IFACE mtu 9000` |
| 250–350 Gbps | TCP window too small | `sysctl -w net.core.rmem_max=536870912` |
| 350–375 Gbps | IRQ coalescing or affinity | `ethtool -C $IFACE rx-usecs 50` + stop `irqbalance` |
| Single port << others | PCIe link downgraded | `lspci -vv \| grep LnkSta` — look for `Speed 2.5GT/s (downgraded)` |
| Port drops after 30s | NIC thermal throttle | `ethtool -m $IFACE \| grep Temp` |
| BiDir << Tx-only | PCIe Gen4 slot | Move NIC to Gen5/Gen6 ×16 slot |

#### PCIe Gen1 recovery (documented in SKILL.md Phase 9.3)
CX8 thermal crash → BIOS locked PCIe to Gen1 (2.5 GT/s) → 28 Gbps throughput →
`setpci` link retrain → Gen3 partial recovery → **BMC D-Bus cold power cycle** → Gen6 restored → 365 Gbps.
Full EMON-based diagnosis path and recovery procedure in [`SKILL.md`](.github/skills/storage-iperf3/SKILL.md).

#### Pass / fail thresholds
| Test | Threshold | Gate |
|---|---|---|
| Single stream per link | ≥ 300 Gbps | — |
| Multi-stream -P8 per link | ≥ 370 Gbps | — |
| **Multi-stream -P16 per link** | **≥ 380 Gbps** | **Primary** |
| Both-link aggregate (Tx) | ≥ 750 Gbps | — |
| Both-link BiDir | ≥ 740 Gbps each dir | — |
| UDP packet loss at line rate | ≤ 0.5% | — |
| 60s vs 30s delta | < 5% sag | — |

> 393 Gbps is the practical SW-TCP ceiling for a 400G link (~1.75% is TCP/IP header overhead — not a failure).

---

### Tests 109–113 — Local Storage + Composite (FIO)

Two skills for different hardware configurations:

**[`storage-fio-solo-dmr`](.github/skills/storage-fio-solo-dmr/SKILL.md)** · 484 lines · 95% file-based coverage · ✅ Live-tested on DMR  
For systems where the only NVMe is the OS boot disk. File-based FIO only. All 4K/128K/QD sweep
subtests documented with live baselines on Micron 7450 NVMe (PCIe Gen5×4, 1.92TB).

**[`storage-fio`](.github/skills/storage-fio/SKILL.md)** · 404 lines · 40% coverage  
For raw block device + multi-NVMe configurations (dedicated partition or separate drives).
All subtest IDs and spec targets from the Excel are present; multi-device groups B/E pending hardware.

---

### Test 117 — Software Defined Storage: MinIO
**Skill:** [`storage-minio`](.github/skills/storage-minio/SKILL.md) · 544 lines · 95% coverage · ✅ Live-tested on DMR

Deploys single-node MinIO and runs WARP object storage benchmark across all object sizes
(1KiB → 64MiB) and concurrency levels (4 → 256). 112 of 114 subtests covered
(MLPerf distributed subtests excluded — require cluster + GPU).

| Key baselines (DMR, loopback) | Value |
|---|---|
| 1KiB PUT C32 | 3,092 obj/s, 3.02 MiB/s |
| 1KiB GET C32 | 43,899 obj/s, 42.87 MiB/s (page cache) |
| 1MiB PUT C32 | 1,064 MiB/s (NVMe write bound) |
| 64MiB GET C4 | 8,370 MiB/s (RAM bound) |

---

## Methodology / Tooling Skills

These skills are not tied to a specific Test ID but are used across all workloads.

### EMON Workload Investigation
**Skill:** [`emon-workload-sweep`](.github/skills/emon-workload-sweep/SKILL.md) · 666 lines  
**References:** [`.github/skills/emon-workload-sweep/references/`](.github/skills/emon-workload-sweep/references/)

Covers Intel EMON (SEP 5.58 beta) setup on DMR, EDP Excel analysis workflow, and a full
**hypothesis-driven investigation methodology** for debugging iperf3 (and any workload) anomalies
using hardware counters. Phase 9 (283 lines) teaches:

- Throughput decomposition: is the bottleneck PCIe · DRAM · CPU · IRQ distribution?
- DMR-correct event names (`UNC_OTC_*`/`UNC_ITC_*` for IO BW — `UNC_IIO_*` does not exist on DMR)
- Known anomaly signatures (PCIe Gen1 downgrade, IRQ imbalance, thermal, NUMA cross-traffic)
- Hypothesis-driven sweep templates (IRQ affinity · NUMA binding · stream count)
- EDP Excel read order and diff discipline (always compare to a known-good trace)

The `references/` folder contains:
- [`emon-metric-guide.md`](.github/skills/emon-workload-sweep/references/emon-metric-guide.md) — 540-line reference guide compiled from the official DMR JSON files
- Symlinks to 4 DMR PMon JSON files (1.28M lines total): core events, computed metrics, offcore OMR events, uncore events
- GNR→DMR event rename table (critical: many GNR event names are silently invalid on DMR)

**DMR-Q9UC ceilings (for anomaly detection):**
| Resource | Ceiling |
|---|---|
| Memory bandwidth | 1,024 GB/s (16ch × DDR5-8000) |
| Per-port NIC | 400 Gbps (PCIe Gen6 ×16) |
| Measured per-port | 353–365 Gbps |
| Typical iperf3 DRAM use | ~50 GB/s (~5% of peak — never DRAM bound) |

### SSH Orchestration
**Skill:** [`benchmark-ssh-orchestration`](.github/skills/benchmark-ssh-orchestration/SKILL.md) · 373 lines

Passwordless SSH key setup between two benchmark systems, remote command execution patterns,
stale process cleanup, and server/client workload orchestration (used for iperf3 S1↔S2).

---

## Repository Structure

```
.github/skills/
├── storage-mlc/              # Test 101 — MLC memory subsystem
├── storage-c2c/              # Test 102 — Core-to-core latency
├── storage-encryption/       # Test 104 — AES-256-GCM
├── storage-compression/      # Test 105 — lz4 / pigz / zstd
├── storage-erasure-coding/   # Test 106 — Reed-Solomon (ISA-L)
├── storage-hashing/          # Test 107 — SHA2 + SMHasher3
├── storage-iperf3/           # Test 108 — iperf3 400GbE ← most detailed
│   ├── SKILL.md              #   1,157 lines — all commands, EMON, anomaly debug
│   └── README.md             #   topology, variables, output files reference
├── storage-fio/              # Tests 109–113 — FIO raw block / multi-NVMe
├── storage-fio-solo-dmr/     # Tests 109–113 — FIO file-based (OS boot disk)
├── storage-minio/            # Test 117 — MinIO + WARP object storage
├── emon-workload-sweep/      # Methodology — EMON collection + investigation
│   ├── SKILL.md              #   666 lines
│   ├── references/           #   DMR PMon JSON symlinks + metric guide
│   └── scripts/              #   helper scripts
└── benchmark-ssh-orchestration/  # Tooling — multi-system SSH setup
README.md                     # This file
storage-skills-checklist.md   # Full test-by-test status checklist
```

---

## Coverage Summary

| Test | Workload | Skill | Doc % | Live-tested |
|---|---|---|---|---|
| 101 | MLC Memory | `storage-mlc` | 100% | ✅ DMR |
| 102 | Core-to-Core Latency | `storage-c2c` | 100% | ✅ DMR |
| 103 | SpecCPU 2017 | — | 0% | ❌ Blocked (ISO install issue) |
| 104 | AES-256-GCM (SW) | `storage-encryption` | 100% | ✅ DMR |
| 105 | Compression (lz4/zlib/zstd) | `storage-compression` | 100% | ✅ DMR |
| 106 | Erasure Coding (RS) | `storage-erasure-coding` | 100% | ✅ DMR |
| 107 | SHA2 + hashes | `storage-hashing` | ~88% | ✅ DMR |
| 108 | iperf3 400GbE | `storage-iperf3` | 98% | ✅ **S1/S2 DMR-Q9UC** |
| 109–113 | FIO + Composite | `storage-fio` / `storage-fio-solo-dmr` | solo: 95% · full: 40% | ✅ DMR (solo) |
| 114–116 | NAS / CDN / Ceph | — | 0% | ❌ Infrastructure not available |
| 117 | MinIO (WARP) | `storage-minio` | 95% | ✅ DMR |

