# storage-iperf3

**GitHub Copilot CLI skill — Storage Segment Validation, Test 108**

Automates iperf3 network bandwidth and latency validation across a **2-system,
dual-port 400GbE back-to-back topology**. Covers 42 subtests across 6 test groups
plus simultaneous EMON/perf telemetry collection on both systems.

---

## Problem Statement

You have two servers connected back-to-back with a dual-port 800Gbps NIC (2 × 400Gbps
ports per system). You need to:

- Confirm each 400GbE link can sustain ≥ 380 Gbps TCP throughput
- Confirm aggregate NIC throughput reaches ≥ 750 Gbps across both links
- Identify which configuration conditions (MTU, streams, window, IRQ coalescing) are
  required to actually hit 400 Gbps
- Collect CPU/NIC PMU telemetry during tests to attribute any shortfall to a root cause

---

## Topology

```
System A (SERVER)                       System B (CLIENT)
┌─────────────────────────┐             ┌─────────────────────────┐
│  NIC-A (800G, 2-port)   │             │  NIC-B (800G, 2-port)   │
│  Port A0: $IP_A0 (400G) │◄───Link1───►│  Port B0: $IP_B0 (400G) │
│  Port A1: $IP_A1 (400G) │◄───Link2───►│  Port B1: $IP_B1 (400G) │
└─────────────────────────┘             └─────────────────────────┘
  Aggregate target: 800 Gbps Tx + 800 Gbps Rx (1.6 Tbps full-duplex)
```

> **Two physical machines required.** This test cannot run on a single system.

---

## Hardware Requirements

| Item | Requirement |
|---|---|
| Systems | 2 × servers (any Intel CPU) |
| NIC | 1 × 800Gbps dual-port NIC per system (e.g. Intel E810-C2Q) |
| Cabling | 2 × direct-attach cables (400GbE DAC or AOC), back-to-back |
| PCIe slot | Gen5 ×16 per NIC (for full-duplex BiDir — Gen4 will bottleneck) |
| OS | CentOS Stream / RHEL 9, or Ubuntu 22.04+ |
| Kernel | ≥ 5.10 (for softirq tracepoints in EMON collection) |

---

## Software Requirements

```bash
# Both systems
iperf3 --version        # need ≥ 3.7 (for --bidir); ≥ 3.10 recommended
perf --version          # for EMON collection (usually pre-installed)

# Install if missing
dnf install -y iperf3 perf    # CentOS/RHEL
apt-get install -y iperf3 linux-perf   # Ubuntu/Debian
```

---

## Variables to Set Before Running

```bash
export SERVER_HOST="storage-server-a"   # SSH alias for System A
export CLIENT_HOST="storage-server-b"   # SSH alias for System B
export IP_A0="192.168.10.1"             # System A, Port 0 (Link1 server end)
export IP_A1="192.168.11.1"             # System A, Port 1 (Link2 server end)
export IP_B0="192.168.10.2"             # System B, Port 0 (Link1 client end)
export IP_B1="192.168.11.2"             # System B, Port 1 (Link2 client end)
export IFACE_A0="ens1f0"                # System A NIC interface, Port 0
export IFACE_A1="ens1f1"                # System A NIC interface, Port 1
export OUTPUT_DIR="/data/benchmarks/test108"
export DURATION=30                      # seconds per test
export STREAMS=8                        # parallel TCP streams
```

---

## What the Skill Runs

| Group | Subtests | What it tests | Runtime |
|---|---|---|---|
| Prerequisites | — | MTU, link speed, sysctl tuning | 2 min |
| EMON start | — | perf stat on both systems (background) | — |
| **A** | 108.001–006 | Single-stream TCP Tx/Rx/BiDir per link | ~6 min |
| **B** | 108.007–014 | Multi-stream -P8/-P16 TCP per link | ~8 min |
| **C** | 108.015–018 | Both links simultaneously (NIC aggregate) | ~5 min |
| **D** | 108.019–022 | UDP jitter + line-rate loss | ~2 min |
| **E** | 108.023–026 | 60-second sustained stability | ~8 min |
| **F** | 108.F.1–F.16 | Config sweep: path to 400 Gbps | ~4 min |
| EMON stop | — | Collect perf data from both systems | 1 min |
| **Total** | **42 subtests** | | **~36 min** |

---

## How to Invoke (GitHub Copilot CLI)

```bash
# Run everything (all groups + EMON)
@workspace /storage-iperf3 all

# Run a specific group
@workspace /storage-iperf3 link1      # Groups A+B for Link1 only
@workspace /storage-iperf3 both       # Group C — aggregate NIC
@workspace /storage-iperf3 latency    # Group D — UDP
@workspace /storage-iperf3 link2      # Groups A+B for Link2 only

# Run the config sweep (find why you're not hitting 400 Gbps)
@workspace /storage-iperf3 single link1 sweep
```

---

## Pass / Fail Thresholds

| Test | Threshold | Primary gate |
|---|---|---|
| Single stream (-P1) per link | ≥ 300 Gbps | — |
| Multi-stream -P8 per link | ≥ 370 Gbps | — |
| **Multi-stream -P16 per link** | **≥ 380 Gbps** | **✅ Primary line-rate gate** |
| Both links aggregate | ≥ 750 Gbps | — |
| Both links BiDir | ≥ 740 Gbps each dir | — |
| UDP packet loss at line rate | ≤ 0.5% | — |
| Sustained 60s vs 30s delta | < 5% sag | — |

---

## Quick Diagnosis: Not Reaching 400 Gbps?

| Measured result | Most likely cause | Fix |
|---|---|---|
| < 250 Gbps | MTU 1500 instead of 9000 | `ip link set $IFACE mtu 9000` |
| 250–350 Gbps | TCP window too small | `sysctl -w net.core.rmem_max=536870912` |
| 350–375 Gbps | IRQ coalescing / affinity | `ethtool -C $IFACE rx-usecs 50` + stop irqbalance |
| 375–393 Gbps | Software TCP overhead | **Normal** — SW TCP stack max is ~393 Gbps on 400G |
| BiDir << Tx-only | PCIe Gen4 slot | Move NIC to PCIe Gen5 ×16 slot |

> **393 Gbps is the practical SW TCP ceiling for a single 400G link.** The remaining
> ~1.75% is TCP/IP header overhead — this is expected and not a failure.

---

## Output Files

All results written to `$OUTPUT_DIR/`:

```
108.001_link1_tx_p1.json         ...  108.026_link1_cpu_top.txt
config_sweep/sweep_results.txt        (Group F summary table)
emon_server.txt                       (perf stat — System A)
emon_client.txt                       (perf stat — System B)
```

---

## References

- Intel Ethernet 800 Series (E810) Performance Tuning Guide
- iperf3 documentation: https://software.es.net/iperf/
- Storage Segment Validation spec: Test 108 (internal)
