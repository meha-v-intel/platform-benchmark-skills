# storage-iperf3 — GitHub Copilot CLI Skill

**Branch:** `storage-skills`  
**Scope:** Single skill — iperf3 network bandwidth and latency validation for Storage Segment Test 108  
**Audience:** Engineer validating a 2-system, dual-port 400GbE back-to-back topology

> This branch contains only the `storage-iperf3` Copilot CLI skill.
> For the full platform benchmark skills set (CPU, memory, AMX, wakeup), see the `main` branch.

---

## Problem Statement

You have two servers connected back-to-back with a dual-port 800Gbps NIC (2 × 400Gbps
ports per system). You need to:

- Confirm each 400GbE link can sustain ≥ 380 Gbps TCP throughput
- Confirm aggregate NIC throughput reaches ≥ 750 Gbps across both links simultaneously
- Identify which configuration conditions (MTU, streams, TCP window, IRQ coalescing) are
  required to actually reach 400 Gbps
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

## How to Use

1. Clone this branch into your project workspace
2. Open in VS Code with GitHub Copilot Chat enabled
3. Set the required variables (see below), then ask Copilot:

```
@workspace /storage-iperf3 all
```

Copilot runs all test groups in order, collects EMON telemetry on both machines,
and prints a pass/fail report at the end.

---

## Skill

| Skill | What it runs | Runtime |
|---|---|---|
| `storage-iperf3` | iperf3 TCP/UDP sweep, NIC aggregate, config sweep, EMON collection | ~36 min |

### Test Groups

| Group | Subtests | Purpose |
|---|---|---|
| A | 108.001–006 | Single-stream TCP Tx / Rx / BiDir per link (baseline) |
| B | 108.007–014 | Multi-stream -P8 / -P16 TCP per link (line-rate saturation) |
| C | 108.015–018 | Both links simultaneously — NIC aggregate throughput |
| D | 108.019–022 | UDP jitter and line-rate packet loss |
| E | 108.023–026 | 60-second sustained stability (thermal/clock sag) |
| F | 108.F.1–F.16 | Config sweep: MTU / streams / TCP window / coalescing |
| EMON | — | `perf stat` running on both systems throughout all groups |

### Invocation

```bash
@workspace /storage-iperf3 all            # full run
@workspace /storage-iperf3 link1          # Groups A+B, Link1 only
@workspace /storage-iperf3 link2          # Groups A+B, Link2 only
@workspace /storage-iperf3 both           # Group C — NIC aggregate
@workspace /storage-iperf3 latency        # Group D — UDP
@workspace /storage-iperf3 single link1 sweep   # Group F — config sweep
```

---

## Variables to Set

```bash
export SERVER_HOST="storage-server-a"   # SSH alias for System A
export CLIENT_HOST="storage-server-b"   # SSH alias for System B
export IP_A0="192.168.10.1"             # System A Port 0 — Link1 server end
export IP_A1="192.168.11.1"             # System A Port 1 — Link2 server end
export IP_B0="192.168.10.2"             # System B Port 0 — Link1 client end
export IP_B1="192.168.11.2"             # System B Port 1 — Link2 client end
export IFACE_A0="ens1f0"                # System A NIC interface, Port 0
export IFACE_A1="ens1f1"                # System A NIC interface, Port 1
export OUTPUT_DIR="/data/benchmarks/test108"
export DURATION=30
export STREAMS=8
```

---

## Requirements

| Item | Requirement |
|---|---|
| Systems | 2 × servers (any Intel CPU with PCIe Gen5 ×16 slot) |
| NIC | 1 × 800Gbps dual-port NIC per system (e.g. Intel E810-C2Q) |
| Cabling | 2 × direct-attach cables (400GbE DAC/AOC), back-to-back |
| OS | CentOS Stream / RHEL 9, or Ubuntu 22.04+ |
| iperf3 | ≥ 3.7 (for `--bidir`); ≥ 3.10 recommended |
| perf | Pre-installed on most distros; `dnf install perf` if missing |

---

## Pass/Fail Thresholds

| Test | Threshold | Gate |
|---|---|---|
| Single stream (-P1) per link | ≥ 300 Gbps | — |
| Multi-stream -P8 per link | ≥ 370 Gbps | — |
| **Multi-stream -P16 per link** | **≥ 380 Gbps** | **Primary** |
| Both links aggregate (Tx) | ≥ 750 Gbps | — |
| Both links BiDir | ≥ 740 Gbps each dir | — |
| UDP packet loss at line rate | ≤ 0.5% | — |
| Sustained 60s vs 30s delta | < 5% sag | — |

> 393 Gbps is the practical SW TCP ceiling for a 400G link — the remaining ~1.75% is
> TCP/IP header overhead. This is expected and is not a failure.

---

## Quick Diagnosis

| Result | Most likely cause | Fix |
|---|---|---|
| < 250 Gbps | MTU 1500 (jumbo frames off) | `ip link set $IFACE mtu 9000` |
| 250–350 Gbps | TCP window too small | `sysctl -w net.core.rmem_max=536870912` |
| 350–375 Gbps | IRQ coalescing or affinity | `ethtool -C $IFACE rx-usecs 50` + stop irqbalance |
| BiDir << Tx-only | PCIe Gen4 slot | Move NIC to PCIe Gen5 ×16 slot |
| Throughput drops after 30s | NIC thermal throttle | `ethtool -m $IFACE \| grep Temp` |

---

## Repository Structure (this branch)

```
.github/skills/
└── storage-iperf3/
    ├── SKILL.md    ← Copilot CLI skill (757 lines — all commands, thresholds, EMON)
    └── README.md   ← Detailed skill reference (topology, variables, output files)
README.md           ← This file
```

---

## References

- [`SKILL.md`](.github/skills/storage-iperf3/SKILL.md) — full skill with all commands
- [`skills/storage-iperf3/README.md`](.github/skills/storage-iperf3/README.md) — detailed reference
- Intel Ethernet 800 Series (E810) Performance Tuning Guide
- Storage Segment Validation spec: Test 108 (internal)
