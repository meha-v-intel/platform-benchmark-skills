# Storage Segment Validation — Workload Analysis
**Source:** `Storage_Segment_Validation_v0.5.xlsx` › Sheet: `1 Node StorageSegment Tests`  
**System:** DMR 1S×32C×1T | 1×Micron 7450 NVMe (PCIe Gen5×4, 1.92TB) | 30GB RAM | CentOS Stream 10  
**Scope:** What workloads exist, what each tests, and what is runnable on THIS system today

---

## Compatibility Legend
| Symbol | Meaning |
|--------|---------|
| ✅ ELIGIBLE | Can run today, tools present |
| ⚠️ PARTIAL | Some subtests runnable, others need missing tool/hardware |
| 🔧 NEEDS INSTALL | Feasible but needs package install first |
| ⏭️ SKIP | Requires missing hardware or infrastructure not on this system |
| ❌ NOT ELIGIBLE | Requires hardware/software not present on this system |

---

## TEST 101 — Memory Subsystem (MLC)
**Classification:** Microbenchmark  
**Benchmark Tool:** Intel MLC  
**Rationale:** Foundational — bounding box for all storage workloads (memory feeds/buffers all I/O)  
**Relevance:** Bounding Box  
**Status:** ✅ ELIGIBLE — MLC already installed at `/root/mlc`

### What it stresses
Memory latency and bandwidth — the ceiling that limits how fast the CPU can stage/buffer I/O data. Storage servers spend most cycles in memcpy, checksumming, and data movement between NIC, NVMe, and DRAM.

### Subtests (92 total)
| Subtest | Metric | Notes |
|---------|--------|-------|
| Idle Latency | Min / Avg / Median / Max | Unloaded DRAM round-trip |
| `local_socket_local_cluster_memory_latency, sequential, sse` | Average Latency | SSE vector access pattern |
| `local_socket_local_cluster_memory_latency, random, sse` | Average Latency | Random access, TLB pressure |
| `local_socket_local_cluster_memory_latency, sequential/random, avx2/avx512` | Average Latency | ISA-specific bandwidth patterns |
| ALL Reads | Bandwidth | Peak read BW |
| 2:1 / 3:2 / 1:1 Reads-Writes | Bandwidth | Mixed R/W ratios (realistic for storage) |
| NT ALL Writes / NT ALL Reads | Bandwidth | Non-temporal (bypass cache) — models DMA-like writes |
| NT 2:1 / 3:1 / 1:1 Reads-Writes | Bandwidth | NT mixed — models RAID parity update patterns |
| NT 2:1 Reads-writes w/ 2buf (Stream-triad like) | Bandwidth | STREAM triad analog |
| Node:Node Bandwidth | Bandwidth | NUMA cross-node (only 1 NUMA node on this system) |

---

## TEST 102 — Intra-Socket Core-to-Core Latency
**Classification:** Microbenchmark  
**Benchmark Tool:** `core-to-core-latency` (Rust, nviennot/core-to-core-latency)  
**Rationale:** Foundational — measures cache coherency cost when storage threads communicate across cores  
**Relevance:** Bounding Box  
**Status:** ✅ ELIGIBLE — tool already built at `/root/core-to-core-latency/target/release/`

### What it stresses
Cache coherency bus (MESIF protocol). Critical for storage: lock contention, queue hand-off between I/O submission and completion threads, ring-buffer producers/consumers on different cores.

### Subtests (4 total)
| Subtest | Metric |
|---------|--------|
| All core pairs | Min Latency (ns) |
| All core pairs | Max Latency (ns) |
| All core pairs | Mean Latency (ns) |
| 32×32 core pair matrix | Latency Heatmap |

---

## TEST 103 — Integer Rate (SpecCPU 2017 SPECintRate)
**Classification:** Microbenchmark  
**Benchmark Tool:** SpecCPU 2017  
**Rationale:** Foundational — overall integer throughput ceiling, models CPU-bound storage data path operations  
**Relevance:** Bounding Box  
**Status:** ❌ NOT ELIGIBLE — requires SPEC license + full toolchain, not installed

### What it stresses
Multi-core integer throughput across diverse workloads (compression, parsing, cryptography). Useful as a single-number CPU ceiling but not runnable ad-hoc.

### Subtests (4 total)
| Subtest | Metric |
|---------|--------|
| SpecintRate Base (GCC8) | Score |
| SpecintRate Peak (GCC8) | Score |
| SpecintRate Base (GCC12) | Score |
| SpecintRate Peak (GCC12) | Score |

---

## TEST 104 — Encryption / Decryption (OpenSSL Speed)
**Classification:** Microbenchmark  
**Benchmark Tool:** `openssl speed`  
**App:** OpenSSL 3  
**Rationale:** Encryption is frequently in the data path — NVMe-oF, object storage (S3 TLS), NFS-over-TLS, Ceph msgr2  
**Relevance:** Bounding Box  
**Status:** ⚠️ PARTIAL — software AES-NI subtests ✅, QAT subtests ❌

**OpenSSL 3.5.1 confirmed present. AES-NI + AVX-512 flags confirmed on CPU.**

### What it stresses
AES-256-GCM throughput across buffer sizes (1B → 1GB). The buffer-size sweep reveals where pipeline fill / cache effects transition from latency-bound (small buffers) to throughput-bound (large buffers). Critical for sizing TLS termination capacity.

### Subtests — Software AES-NI (✅ ELIGIBLE, 26 subtests)
All use `openssl speed -evp aes-256-gcm` at these buffer sizes:  
`1b, 2b, 4b, 8b, 16b, 64b, 256b, 1024b, 8192b, 16384b, 32768b, 65536b, 131072b, 262144b, 524288b, 1048576b, 2097576b (2MiB), 4194304b (4MiB), 8388608b (8MiB), 16777216b (16MiB), 33554432b (32MiB), 67108864b (64MiB), 134217728b (128MiB), 268435456b (256MiB), 536870912b (512MiB), 1073741824b (1GiB)`

### Subtests — QAT Offload (❌ NOT ELIGIBLE, 26 subtests)
Same buffer size sweep but via Intel QAT hardware accelerator. **No QAT hardware on this system.**

---

## TEST 105 — Compression / Decompression
**Classification:** Microbenchmark  
**Benchmark Tool:** Multiple (lz4, pigz/zlib, minLZ)  
**Rationale:** Compression frequently in storage data path — object stores, ZFS, Ceph BlueStore inline compression  
**Relevance:** Bounding Box  
**Status:** 🔧 NEEDS INSTALL — `zstd` present ✅, `lz4` CLI missing (only libs), `pigz`/`zlib` CLI missing, `minLZ` unknown

> Note: `lz4-libs` and `zstd` are installed RPMs. `lz4` CLI can be added with `dnf install lz4`. `zlib` tested via `pigz` or Python. `minLZ` is an Intel-internal tool — not publicly available.

### What it stresses
Compression ratio vs throughput tradeoff across codec levels. Each compression level changes CPU cycles/byte, directly modeling storage amplification cost.

### Subtests (23 total)
| Subtest | Metric | Eligibility |
|---------|--------|-------------|
| lz4 | Bandwidth MB/s | 🔧 `dnf install lz4` |
| zlib -1 through -9 (compress) | Bandwidth MB/s | 🔧 needs `pigz` or Python zlib |
| zlib -1 through -9 (decompress) | Bandwidth MB/s | 🔧 same |
| minLZ-1 stream | Bandwidth MB/s | ❌ Intel-internal tool |
| minLZ1 / minLZ2 / minLZ3 stream | Bandwidth MB/s | ❌ Intel-internal tool |

---

## TEST 106 — Erasure Coding
**Classification:** Microbenchmark  
**Benchmark Tool:** Multiple (likely ISA-L / jerasure)  
**Rationale:** Erasure coding (EC) is the dominant data protection scheme in object/distributed storage (Ceph, HDFS, MinIO)  
**Relevance:** Bounding Box  
**Status:** ❌ NOT ELIGIBLE — requires `isa-l` (Intel ISA-L) or `jerasure` library + benchmark harness, not installed

### What it stresses
Reed-Solomon encode/decode throughput — measures how fast the CPU can compute parity shards. Bottleneck in EC-heavy object stores.

### Subtests (2 total)
| Subtest | Metric |
|---------|--------|
| Reed-Solomon 10+4 encode | Bandwidth MB/s |
| Reed-Solomon 10+4 decode | Bandwidth MB/s |

---

## TEST 107 — Hashing
**Classification:** Microbenchmark  
**Benchmark Tool:** Multiple (SMHasher3 / `smhasher`, OpenSSL speed)  
**Rationale:** Hashing is ubiquitous in storage — checksums (CRC32C on NVMe, ZFS block checksums), dedup fingerprinting, object key hashing  
**Relevance:** Bounding Box  
**Status:** ⚠️ PARTIAL

| Subtest group | Tool | Eligibility |
|---------------|------|-------------|
| `crc32`, MD5 variants, SHA1 variants | SMHasher3 | 🔧 needs `smhasher3` build |
| SHA2-NI variants (sha1ni, sha2ni-256) | SMHasher3 | 🔧 same — will leverage SHA-NI CPU extension |
| xxHash32/64, xxh3, xxh128 | SMHasher3 | 🔧 same |
| MurmurHash, FarmHash, CityHash, SipHash | SMHasher3 | 🔧 same |
| FNV, MeowHash, wyhash, rapidhash, etc. | SMHasher3 | 🔧 same |
| `SHA2-256` buffer sweep (1b → 1GiB) | `openssl speed -evp sha256` | ✅ ELIGIBLE — OpenSSL present |
| `SHA2-512` buffer sweep (1b → 1GiB) | `openssl speed -evp sha512` | ✅ ELIGIBLE — OpenSSL present |

### What it stresses
Hash throughput as a function of input size. Small inputs stress per-call overhead (latency). Large inputs stress throughput / AVX-512 utilization. AESNI-based hashes (MeowHash, aesni-hash) stress the AES round instruction throughput independent of encryption.

**Total subtests: 312**
- 222 SMHasher3 hashes (cycle/hash + bandwidth) — 🔧 NEEDS BUILD
- 38 SHA2-256 via openssl (buffer sweep × 2 runs) — ✅ ELIGIBLE
- 38 SHA2-512 via openssl (buffer sweep × 2 runs) — ✅ ELIGIBLE
- 14 sha1/sha2 small (cycle/hash via SMHasher) — 🔧 NEEDS BUILD

---

## TEST 108 — Network
**Classification:** Microbenchmark  
**Benchmark Tool:** Multiple (iperf3, perftest/RDMA verbs, netperf)  
**Rationale:** Networking is critical to storage workloads — all distributed storage protocols traverse the network  
**Relevance:** Bounding Box  
**Status:** ❌ NOT ELIGIBLE — no dedicated NIC for isolation, no second machine, no `iperf3`/`perftest` installed

### What it stresses
TCP/IP bandwidth (Tx/Rx/BDir), TCP latency percentiles (P25→P99.999), RDMA (InfiniBand) write/read/send bandwidth and latency, netperf TCP stream.

### Subtests (60 total) — all blocked on missing network hardware

---

## TEST 109 — Local Storage (FIO)
**Classification:** Microbenchmark  
**Benchmark Tool:** FIO  
**Rationale:** Local storage is the foundational I/O primitive for all storage workload tiers  
**Relevance:** Bounding Box  
**Status:** ✅ PARTIAL — two skill versions created; file-based tests live on this system

### Skill split — two separate versions

> **WHY TWO SKILLS:** The spec requires raw block device access and multiple dedicated NVMe drives
> (1×, 2×, 4×, 8×, 16×, 24×). This system has a single NVMe used as the OS boot disk with no
> separate partition or dedicated storage device. The two skills encode these fundamentally
> different execution environments:

| Skill | Target system | Device mode | Live on this DMR | Spec subtests covered |
|---|---|---|---|---|
| `storage-fio-solo-dmr` | 1S solo DMR, OS boot disk only, no dedicated NVMe, no separate partition | File-based (`--filename=/path/to/file`) | ✅ Yes — tested live | 109.001–003, 109.019–021, 109.037–039 (9 subtests) |
| `storage-fio` | Any system with a dedicated NVMe partition or separate non-OS drive(s) | Raw block (`--filename=/dev/nvmeXnY`) | ❌ Not yet — no dedicated device | Full Test 109 skeleton: 1× through 24× NVMe device scaling |

### What it stresses
4KiB random read/write/mixed IOPS and 128KiB sequential read/write/mixed bandwidth across 1/2/4/8/16/24 NVMe devices (PCIe Gen5 and Gen6 configurations). Latency at queue depth.

**This system:** 1×NVMe (Gen5×4, OS boot disk) — file-based test only. Multi-device subtests require additional drives.

### Live DMR baselines (file-based, Micron 7450, fio-3.36, `--direct=1`)

| Subtest | Config | Result |
|---|---|---|
| 109.001 | 4K randwrite QD32, file | ~212,966 IOPS |
| 109.002 | 4K randread QD32, file | ~339,623 IOPS |
| 109.019 | 128K seq write QD32, file | ~1,662 MB/s |
| 109.020 | 128K seq read QD32, file | ~2,149 MB/s |
| — | 4K randread QD1 (latency) | ~84 µs avg |

Spec targets are for raw block (e.g. 109.002 spec = 1,603,000 IOPS). File-based results are 30–85% lower due to XFS overhead and shared OS I/O.

---

## TEST 110 — Composite: iperf3 + FIO (Simultaneous)
**Classification:** Composite Microbenchmark  
**Benchmark Tool:** iperf3 + FIO  
**Rationale:** Simultaneous stress of network and local storage — models storage server data forwarding path  
**Relevance:** Entirely Synthetic storage server  
**Status:** ❌ NOT ELIGIBLE on this system — requires 400GbE NIC + second machine + dedicated NVMe

> When a second machine and dedicated NVMe are available, use `storage-fio` + `storage-iperf3` skills together.

### Subtests (6): Network Tx/Rx combined with 4KiB Disk Read/Write/Mixed

---

## TEST 111 — Composite: Bandwidth-Matched iperf3 + FIO
**Classification:** Composite Microbenchmark  
**Benchmark Tool:** iperf3 + FIO  
**Rationale:** Network BW matched to disk BW — models realistic NVMe-oF / NAS data path saturation  
**Relevance:** Entirely Synthetic storage server  
**Status:** ⏭️ SKIP — missing iperf3 + FIO deferred

### Subtests (18): TX+Read, RX+Write, BiDir+Mixed combinations at matched bandwidth

---

## TEST 112 — Composite: Bandwidth-Matched iperf3 + FIO + CPU Noise
**Classification:** Composite Microbenchmark  
**Benchmark Tool:** iperf3 + FIO + CPU stress  
**Rationale:** Adds CPU competition to network+storage stress — models collocated compute + storage  
**Relevance:** Entirely Synthetic storage server with simulated compute activity  
**Status:** ⏭️ SKIP — missing iperf3 + FIO deferred

### Subtests (18): Same as Test 111 but with background CPU load injected

---

## TEST 113 — Composite: netperf + FIO
**Classification:** Composite Microbenchmark  
**Benchmark Tool:** netperf + FIO  
**Rationale:** Alternative network stack (netperf) combined with disk I/O  
**Relevance:** Not specified  
**Status:** ⏭️ SKIP — missing netperf + FIO deferred

### Subtests (4): TCP Tx/Rx + disk read/write combinations

---

## TEST 114 — NAS: NFSv4 & SMB on OpenZFS
**Classification:** System Level Benchmark  
**Benchmark Tool:** FIO + MLPerf Storage  
**App:** Open Source NAS (OpenZFS + NFS + Samba)  
**Rationale:** Realistic single-node NAS usage model  
**Relevance:** High Performance Network Attached Storage  
**Status:** ❌ NOT ELIGIBLE — requires OpenZFS install, NFS/SMB config, FIO + MLPerf Storage, NIC

### What it stresses
Full NAS stack: filesystem (ZFS raidz2 + mirrored stripe) → protocol layer (NFSv4/SMB) → network. Tests data integrity under protection overhead, protocol latency, and file metadata operations.

### Subtests (50): Local 4KiB RandWr/Rd, 128KiB SeqWr/Rd, NFSv4 write/read at varied concurrency, SMB write/read, MLPerf Storage synthetic AI training I/O patterns

---

## TEST 115 — Content Delivery Network (CDN)
**Classification:** System Level Benchmark  
**Benchmark Tool:** WRK (HTTP load generator)  
**App:** Multiple (nginx, lighttpd, Apache, Varnish)  
**Rationale:** Realistic single-node CDN usage model  
**Relevance:** High Performance Content Delivery Network  
**Status:** ❌ NOT ELIGIBLE — requires wrk, NIC, and CDN server (nginx/lighttpd) configured with hot/cold object mix

### What it stresses
HTTP serving throughput + latency with a cache hit rate (50% / 80%) simulating CDN cache tiers. 16KiB objects. This exercises the network stack, kernel page cache, and NVMe read path simultaneously.

### Subtests (12): 16KiB at 50%/80%/other hit rates, Bandwidth + Latency per config

---

## TEST 116 — Software Defined Storage: Ceph (NonProd)
**Classification:** System Level Benchmark  
**Benchmark Tool:** WARP (object), FIO (block + file)  
**App:** Ceph  
**Rationale:** Simplest possible instantiation of Ceph SDS  
**Relevance:** Software Defined Storage  
**Status:** ❌ NOT ELIGIBLE — full Ceph cluster setup required (RGW + OSD + MON), multi-disk, NIC

### What it stresses
Ceph RGW (S3 object): PUT/GET concurrency sweep at 1KiB–4MiB object sizes. Ceph RBD (block): 4KiB random IOPS. CephFS (file): metadata ops + sequential I/O. The entire Ceph data path — CRUSH, OSD threads, BlueStore, journal — is under load.

### Subtests (126): Object PUT/GET at concurrency 4/8/16/32/64, block rand r/w, file r/w across multiple object sizes

---

## TEST 117 — Software Defined Storage: MinIO (NonProd)
**Classification:** System Level Benchmark  
**Benchmark Tool:** WARP + MLPerf Storage / TF_ObjectStorage  
**App:** MinIO  
**Rationale:** Not specified  
**Relevance:** Not specified  
**Status:** ✅ PARTIAL — 112 WARP subtests runnable; 2 MLPerf subtests ❌ NOT ELIGIBLE (no cluster)

### What it stresses
S3-compatible object storage throughput. PUT/GET concurrency sweep (4→256) at 1KiB through 64MiB objects. Also includes MLPerf Storage training I/O profile (models AI training data ingestion from object store).

### Skill split

| Subtests | Skill | Status | Notes |
|---|---|---|---|
| 117.001–117.112 (WARP sweep) | `storage-minio` | ✅ RUNNABLE | MinIO + WARP built from source; single-node loopback |
| 117.113 (MLPerf Training) | — | ❌ NOT ELIGIBLE | Needs distributed MinIO cluster + GPU + mlperf_storage |
| 117.114 (MLPerf Inference) | — | ❌ NOT ELIGIBLE | Needs distributed MinIO cluster + GPU + mlperf_storage |

### Installation (already done on this DMR)
```bash
# Go 1.26.1
dnf install -y golang
# MinIO server
go install github.com/minio/minio@latest   # ~/go/bin/minio
# WARP benchmark client
go install github.com/minio/warp@latest    # ~/go/bin/warp
# Start MinIO
export MINIO_ROOT_USER=minioadmin MINIO_ROOT_PASSWORD=minioadmin
nohup ~/go/bin/minio server /data/minio --address :9000 > /tmp/minio.log 2>&1 &
```

### DMR live baselines (single-node, loopback, Micron 7450 Gen5×4)

| Object size | Op | C | Throughput | Obj/s | Avg latency |
|---|---|---|---|---|---|
| 1 KiB | PUT | 4 | 1.80 MiB/s | 1,848 | 2.2 ms |
| 1 KiB | PUT | 32 | 3.02 MiB/s | 3,092 | 10.5 ms |
| 1 KiB | GET | 4 | 6.05 MiB/s | 6,196 | 0.6 ms |
| 1 KiB | GET | 32 | 42.87 MiB/s | 43,899 | 0.7 ms |
| 1 MiB | PUT | 32 | 1,064 MiB/s | 1,064 | 30.1 ms |
| 1 MiB | GET | 32 | 8,067 MiB/s | 8,067 | 4.0 ms |
| 64 MiB | PUT | 4 | 1,102 MiB/s | 17 | 232 ms |
| 64 MiB | GET | 4 | 8,370 MiB/s | 131 | 30.6 ms |

*PUT limited by NVMe write (~1.1 GB/s); GET served from 30 GiB page cache (~8 GiB/s).*

### Subtests (114): PUT/GET/Mixed concurrency sweep, MLPerf Storage checkpoints, TF_ObjectStorage patterns

---

## Summary: Eligibility on This System

| Test | Workload | Tool | Status | Blocker |
|------|----------|------|--------|---------|
| **101** | Memory Latency/BW | Intel MLC | ✅ ELIGIBLE | — |
| **102** | Core-to-Core Latency | core-to-core-latency | ✅ ELIGIBLE | — |
| **103** | Integer Rate (SIR) | SpecCPU 2017 | ❌ | Needs SPEC license |
| **104** (×26) | AES-256-GCM (SW) | openssl speed | ✅ ELIGIBLE | — |
| **104** (×26) | AES-256-GCM (QAT) | QAT offload | ❌ | No QAT hardware |
| **105** | Compression (lz4) | lz4 | 🔧 | `dnf install lz4` |
| **105** | Compression (zlib) | pigz / python | 🔧 | `dnf install pigz` |
| **105** | Compression (minLZ) | Intel internal | ❌ | Not public |
| **106** | Erasure Coding | ISA-L / jerasure | ❌ | Needs ISA-L build |
| **107** (×76) | SHA2-256 / SHA2-512 sweep | openssl speed | ✅ ELIGIBLE | — |
| **107** (×236) | SMHasher3 hashes | smhasher3 | 🔧 | Needs build from source |
| **108** | Network (TCP/RDMA) | iperf3 / perftest | ❌ | No NIC / no 2nd machine |
| **109** | Local Storage IOPS/BW | FIO | ✅ PARTIAL | `storage-fio-solo-dmr` (file-based, live) · `storage-fio` (raw block skeleton) |
| **110–113** | Composite Net+Disk | iperf3 + FIO | ❌ | No NIC + no 2nd machine |
| **114** | NAS (ZFS+NFS/SMB) | FIO + MLPerf | ❌ | Needs OpenZFS + NIC |
| **115** | CDN | WRK | ❌ | Needs NIC + web server |
| **116** | Ceph SDS | WARP + FIO | ❌ | Needs Ceph cluster |
| **117** | MinIO SDS | WARP + MLPerf | ✅ PARTIAL | `storage-minio` (WARP 112/114 done) · MLPerf 2 subtests ❌ no cluster |

### Immediately runnable today (0 installs needed)
- **101** — MLC (memory latency/BW/lat-BW curve)
- **102** — Core-to-core latency heatmap
- **104.001–104.026** — AES-256-GCM buffer sweep (SW only)
- **107.223–107.260** — SHA2-256 and SHA2-512 buffer sweeps via openssl

### Runnable after quick installs (`dnf install`)
- **105 (partial)** — lz4 + pigz compression/decompression
- **107 (full)** — SMHasher3 hashes after building from source
- **109 (file-based)** — `storage-fio-solo-dmr`: 4K rand IOPS + 128K seq BW on OS boot NVMe (**fio-3.36 already installed**)
- **117 (WARP sweep)** — `storage-minio`: MinIO + WARP already built (`~/go/bin/minio`, `~/go/bin/warp`); MinIO server running at localhost:9000

---

## SPEC CPU 2017 Install Blocker (Test 103)

**Status:** ❌ Blocked — ISO filename truncation

### Root Cause
The `speccpu.iso` was mastered with plain **ISO 9660 Level 1**, which caps filenames at 8.3 characters. The ISO has no Joliet or Rock Ridge extensions. When Linux mounts it, all long filenames are silently truncated. The SPEC `install.sh` script expects the full names and fails immediately.

**Truncated names that break install.sh:**

| `install.sh` expects | ISO actually has |
|---|---|
| `bin/scripts.misc/` | `bin/scripts.mis/` |
| `bin/scripts.misc/exec_test` | `bin/scripts.mis/exec_tes` |
| `tools/bin/linux000/specsha512sum` | `tools/bin/linux000/specsha5` |

### Error observed
```
Top of the CPU2017 tree is '/mnt/speccpu_iso'
ERROR:
The bin subdirectory of /mnt/speccpu_iso is missing a file.
Installation cannot proceed.
```

### Fix (when resuming)
The ISO is read-only so the names cannot be fixed in place. Workaround: copy the entire ISO tree to a writable staging directory, rename the three truncated paths, then run `install.sh` from there.

**Key steps:**
```bash
mkdir -p /tmp/spec_stage
cp -a /mnt/speccpu_iso/. /tmp/spec_stage/             # ~3GB, ~2 min
mv /tmp/spec_stage/bin/scripts.mis  /tmp/spec_stage/bin/scripts.misc
mv /tmp/spec_stage/bin/scripts.misc/exec_tes  /tmp/spec_stage/bin/scripts.misc/exec_test
# rename specsha5 → specsha512sum in each tools/bin/<arch>/ directory
for d in /tmp/spec_stage/tools/bin/*/; do
    [[ -f "${d}specsha5" ]] && mv "${d}specsha5" "${d}specsha512sum"
done
chmod -R +w /tmp/spec_stage
cd /tmp/spec_stage && ./install.sh -d /opt/spec2017 -f
```

**Downloads already complete** (no re-download needed):
- `/tmp/speccpu_downloads/speccpu.iso` — 2.86 GB ✅
- `/tmp/speccpu_downloads/cpu2017-gcc8.tar.xz` — 366 MB ✅
- `/tmp/speccpu_downloads/cpu2017-gcc12.tar.xz` — 1.17 GB ✅

The `install_speccpu2017.sh` script in `/root/` needs to incorporate the copy+rename step before invoking `install.sh`.
