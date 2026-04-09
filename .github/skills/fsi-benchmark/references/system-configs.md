# FSI System Configurations

**Source:** Segment Validation - FSI Test Plan v0.91  
**Purpose:** Reference system configurations for HFT and HPC Grid test cases.  
**Usage:** Verify the system under test matches the expected configuration before running benchmarks. Use the preflight step in `fsi-benchmark/SKILL.md` to auto-detect the platform.

---

## HFT System Configurations

> All HFT configurations require **2 identical systems** for network ping-pong tests.  
> Simulated HFT packet processing (`hft_rdtscp`) runs on a single node.

### DMR HFT Configuration

| Parameter | Value |
|---|---|
| Quantity | 2 systems |
| System | Johnson City |
| CPU | DMR (highest frequency, highest L3 cache available) |
| Sockets | 1 |
| Cores / Socket | Any |
| Memory | 8× 64GB DDR5-6400 (1DPC) |
| Storage | 4TB NVMe |
| NIC | 1× Solarflare X2522-25G-PLUS |
| DAC Cable | 1× CAB-10GBSFP-P3M (10G SFP+ DAC, 3M) |
| BKC | Latest |
| BIOS | Default |
| OS / Kernel | Ubuntu LTS 24.04.4 / Kernel 6.19.6 |
| GRUB | `GRUB_CMDLINE_LINUX_DEFAULT="isolcpus=1-127 nohz=off iommu=off intel_iommu=off mce=ignore_ce nmi_watchdog=0"` |

### GNR-SP HFT Configuration

| Parameter | Value |
|---|---|
| Quantity | 2 systems |
| System | Beechnut City |
| CPU | GNR-SP HCC 6732P |
| Sockets | 1 |
| Cores / Socket | 32 |
| Memory | 8× 64GB DDR5-6400 (1DPC) |
| Storage | 4TB NVMe |
| NIC | 1× Solarflare X2522-25G-PLUS |
| DAC Cable | 1× CAB-10GBSFP-P3M (10G SFP+ DAC, 3M) |
| BKC | Latest |
| BIOS Knobs | Socket Config → Processor Config → Enable LP [Global] = **Single LP**; Socket Config → Advanced PM Config → CPU Advanced PM Tuning → Latency Optimized Mode = **Enable** |
| OS / Kernel | Ubuntu LTS 24.04.4 / Kernel 6.19.6 |
| GRUB | `GRUB_CMDLINE_LINUX_DEFAULT="isolcpus=1-31 nohz=off iommu=off intel_iommu=off mce=ignore_ce nmi_watchdog=0"` |

### EMR HFT Configuration

| Parameter | Value |
|---|---|
| Quantity | 2 systems |
| System | Archer City |
| CPU | EMR 6558Q |
| Sockets | 1 |
| Cores / Socket | 32 |
| Memory | 8× 64GB DDR5-6400 (1DPC) |
| Storage | 4TB NVMe |
| NIC | 1× Solarflare X2522-25G-PLUS |
| DAC Cable | 1× CAB-10GBSFP-P3M (10G SFP+ DAC, 3M) |
| BKC | Latest |
| BIOS Knobs | Socket Config → Processor Config → Enable LP [Global] = **Single LP** |
| OS / Kernel | Ubuntu LTS 24.04.4 / Kernel 6.19.6 |
| GRUB | `GRUB_CMDLINE_LINUX_DEFAULT="isolcpus=1-31 nohz=off iommu=off intel_iommu=off mce=ignore_ce nmi_watchdog=0"` |

### AMD Turin HFT Configuration

| Parameter | Value |
|---|---|
| Quantity | 2 systems |
| System | Supermicro Hyper A+ Server AS-2126HS-TN |
| CPU | AMD Turin 9575F |
| Sockets | 1 |
| Cores / Socket | 64 |
| Memory | 8× 64GB DDR5-6400 (1DPC) |
| Storage | 4TB NVMe |
| NIC | 1× Solarflare X2522-25G-PLUS |
| DAC Cable | 1× CAB-10GBSFP-P3M (10G SFP+ DAC, 3M) |
| BKC | Latest |
| BIOS Knobs | CPU Common Options → Performance → SMT Control → **Disable**; DF Common Options → Memory Addressing → NUMA nodes per socket → **NPS4**; NBIO → IOMMU → **Disable**; NBIO → SMU → Determinism Control → **Manual**; NBIO → SMU → Determinism Enable → **Power**; NBIO → SMU → APBDIS → **1**; NBIO → SMU → DfPstate → **0**; NBIO → SMU → Power Profile → **Maximum IO Performance Mode**; NBIO → PCIe → PCIe Idle Power Setting → **Latency Optimized** |
| OS / Kernel | Ubuntu LTS 24.04.4 / Kernel 6.19.6 |
| GRUB | `GRUB_CMDLINE_LINUX_DEFAULT="isolcpus=1-63 nohz=off iommu=off intel_iommu=off mce=ignore_ce nmi_watchdog=0"` |

---

## Solarflare X2522-25G-PLUS NIC Software Configuration

| Component | Version |
|---|---|
| Open Onload & ef_vi | 9.1.1.66 |
| Solarflare X2522-25G-PLUS NUMA node | 0 |
| Solarflare X2522-25G-PLUS Firmware | 8.6.2.1000 rx1 tx1 |
| sfc kernel module | 6.2.1.1000 |
| Ethernet Cable (port0) | CAB-10GBSFP-P3M (10G SFP+ DAC, 3M) |
| Ethernet Cable (port1) | Disconnected (for HFT ping-pong) |
| cns-sfnettest | 1.5.0 |
| netperf | 2.7.0 |

### Kernel Bypass Stack Descriptions

| Network Stack | Mode | Description |
|---|---|---|
| ef_vi | Layer 2 API | Direct access to Solarflare NIC datapath — lowest latency |
| Onload | TCP/IP in userspace | Eliminates kernel transitions; TCP/IP in user-process |
| CTPIO Cut-Through (ct) | Transmit mode | Starts TX before full packet delivered over PCIe — **lowest TX latency** |
| CTPIO Store and Forward (s/f) | Transmit mode | Buffers on adapter before TX — higher latency, safer |
| CTPIO Store and Forward No Poison (s/f no-p) | Transmit mode | Same as s/f but guarantees no poisoned packets transmitted |

---

## HPC Grid System Configurations

> HPC Grid tests run on a **single system** (single-node job submission model).  
> EMR is **not tested** for HPC Grid due to lower core count compared to GNR-AP.

### DMR HPC Grid Configuration

| Parameter | Value |
|---|---|
| Quantity | 1 system |
| System | Johnson City |
| CPU | DMR (highest core count available) |
| Sockets | 1 |
| Cores / Socket | 256 |
| Memory Config A | 32× 64GB DDR5-12800 MRDIMM Gen2 (1DPC) |
| Memory Config B | 32× 64GB DDR5-6400 (1DPC) |
| Storage | 4TB NVMe |
| BKC | Latest |
| BIOS | Default |
| OS / Kernel | Ubuntu LTS 24.04.4 / Kernel 6.19.6 |

> Run all HPC workloads under **both memory configurations** and report results separately.

### GNR-AP HPC Grid Configuration

| Parameter | Value |
|---|---|
| Quantity | 1 system |
| System | Avenue City |
| CPU | GNR-AP 6980P |
| Sockets | 2 |
| Cores / Socket | 128 |
| Memory Config A | 24× 64GB DDR5-8800 MRDIMM (1DPC) |
| Memory Config B | 24× 64GB DDR5-6400 (1DPC) |
| Storage | 4TB NVMe |
| BKC | Latest |
| BIOS | Default |
| OS / Kernel | Ubuntu LTS 24.04.4 / Kernel 6.19.6 |

### AMD HPC Grid Configuration

| Parameter | Value |
|---|---|
| Quantity | 1 system |
| System | Supermicro Hyper A+ Server AS-2126HS-TN |
| CPU | AMD Turin 9755 |
| Sockets | 2 |
| Cores / Socket | 128 |
| Memory | 24× 64GB DDR5-6400 (1DPC) |
| Storage | 4TB NVMe |
| BKC | Latest |
| BIOS | Default |
| OS / Kernel | Ubuntu LTS 24.04.4 / Kernel 6.19.6 |

---

## Configuration Verification Commands

Run these after SSH-ing into the test system to confirm config matches spec:

```bash
# CPU and socket count
lscpu | grep -E "Socket|Core|Thread|Model name|MHz"

# Memory config
dmidecode -t 17 | grep -E "Size|Speed|Type|Locator" | grep -v "No Module"

# NUMA topology
numactl --hardware

# NIC presence (HFT only)
lspci | grep -i "solarflare\|xilinx"
ethtool <iface> | grep -E "Speed|Link"

# GRUB cmdline (verify isolcpus etc.)
cat /proc/cmdline

# C-state driver
cat /sys/devices/system/cpu/cpuidle/current_driver

# Kernel version
uname -r
```
