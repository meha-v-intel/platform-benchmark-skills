---
name: storage-iperf3
description: "Run iperf3 network bandwidth and latency sweep for storage segment validation Test 108. Use when: measuring 400GbE TCP bandwidth, measuring bidirectional NIC throughput, validating back-to-back NIC line rate, testing per-link and aggregate NIC throughput, measuring network latency between two systems, validating storage network fabric, testing iperf3 parallel streams, characterizing 800Gbps dual-port NIC performance, validating NVMe-oF or NFS transport bandwidth, network bounding box for storage workloads."
argument-hint: "[link1|link2|both|latency|all|single <link> <mode>]"
allowed-tools: Bash
---

# iperf3 Network Bandwidth & Latency (Storage Test 108)

Measures TCP bandwidth (Tx, Rx, BiDir) and UDP latency across a **2-system, dual-port 400GbE
back-to-back topology** using iperf3. This is the network bounding box for all storage
workloads — it establishes the per-link and aggregate bandwidth ceiling that constrains
NVMe-oF throughput, NFS transfer rate, and storage tier data forwarding.

> **This test requires two physical machines.** It cannot run on a single system.
> This skill is a reference implementation — run on the target 400GbE system, not on DMR 1S.

**Topology:**
```
System A (SERVER)                       System B (CLIENT)
┌─────────────────────────┐             ┌─────────────────────────┐
│  NIC-A (800G, 2-port)   │             │  NIC-B (800G, 2-port)   │
│  Port A0: $IP_A0 (400G) │◄───Link1───►│  Port B0: $IP_B0 (400G) │
│  Port A1: $IP_A1 (400G) │◄───Link2───►│  Port B1: $IP_B1 (400G) │
└─────────────────────────┘             └─────────────────────────┘
  Aggregate target: 800 Gbps Tx + 800 Gbps Rx = 1.6 Tbps full-duplex
```

Argument: `$ARGUMENTS` — `link1`, `link2`, `both`, `latency`, `all`, or `single <link> <mode>`.

---

## Variables

| Variable | Description | Example |
|---|---|---|
| `$SERVER_HOST` | SSH alias or IP for System A | `storage-server-a` |
| `$CLIENT_HOST` | SSH alias or IP for System B | `storage-server-b` |
| `$IP_A0` | System A, Port 0 IP (Link1 server end) | `192.168.10.1` |
| `$IP_A1` | System A, Port 1 IP (Link2 server end) | `192.168.11.1` |
| `$IP_B0` | System B, Port 0 IP (Link1 client end) | `192.168.10.2` |
| `$IP_B1` | System B, Port 1 IP (Link2 client end) | `192.168.11.2` |
| `$IFACE_A0` | System A NIC interface name, Port 0 | `ens1f0` |
| `$IFACE_A1` | System A NIC interface name, Port 1 | `ens1f1` |
| `$OUTPUT_DIR` | Local results directory | `/data/benchmarks/2026-04-08/` |
| `$DURATION` | Test duration in seconds | `30` |
| `$STREAMS` | Parallel TCP streams for line-rate | `8` |

Set all variables before invoking this skill.

---

## Prerequisites

Run on **both systems** before any benchmark:

```bash
# Verify iperf3 version (need ≥ 3.7 for --bidir, ≥ 3.10 recommended)
iperf3 --version   # expect: iperf 3.10+
# Install if missing:
# CentOS/RHEL: dnf install -y iperf3
# Ubuntu/Debian: apt-get install -y iperf3

# Verify NIC link speed (run on each system for each port)
ethtool $IFACE_A0 | grep Speed    # expect: Speed: 400000Mb/s
ethtool $IFACE_A1 | grep Speed

# Verify MTU — jumbo frames are required for 400GbE throughput
ip link show $IFACE_A0 | grep mtu    # expect: mtu 9000
# Set if not already: ip link set $IFACE_A0 mtu 9000

# Tune TCP socket buffers for 400GbE (run on both systems as root)
sysctl -w net.core.rmem_max=536870912
sysctl -w net.core.wmem_max=536870912
sysctl -w net.ipv4.tcp_rmem="4096 87380 536870912"
sysctl -w net.ipv4.tcp_wmem="4096 65536 536870912"
sysctl -w net.core.netdev_max_backlog=250000
sysctl -w net.ipv4.tcp_congestion_control=bbr    # BBR or cubic both valid

# Set NIC ring buffers to max (reduces packet drops at 400Gbps)
ethtool -G $IFACE_A0 rx 4096 tx 4096
ethtool -G $IFACE_A1 rx 4096 tx 4096

# Pin IRQs to NUMA-local CPUs (replace ens1f0 with actual iface name)
# service irqbalance stop
# find /proc/irq -name "smp_affinity_list" | xargs -I{} bash -c \
#   'cat /proc/irq/$(echo {} | cut -d/ -f4)/actions | grep -q ens1f0 && echo 0-15 > {}'

# Verify reachability
ping -c 3 -i 0.2 $IP_A0 -I $IP_B0     # run from System B
ping -c 3 -i 0.2 $IP_A1 -I $IP_B1
```

> **MTU 9000 (jumbo frames) is required.** Standard MTU 1500 caps throughput near
> 200–250 Gbps due to CPU/PCIe overhead per packet. Always verify before benchmarking.

---

## Server Setup (System A — run first, leave running)

iperf3 is single-server-instance-per-port. Start one server per port, on separate TCP ports:

```bash
# On System A — start one iperf3 server per NIC port
# Use tmux for persistence across SSH disconnects

# Server for Link1 (Port A0)
ssh $SERVER_HOST "tmux new-session -d -s iperf3-p0 \
  'iperf3 -s -B ${IP_A0} -p 5201 --daemon --logfile /tmp/iperf3_p0.log'"

# Server for Link2 (Port A1)
ssh $SERVER_HOST "tmux new-session -d -s iperf3-p1 \
  'iperf3 -s -B ${IP_A1} -p 5202 --daemon --logfile /tmp/iperf3_p1.log'"

# Verify servers are listening
ssh $SERVER_HOST "ss -tlnp | grep '520[12]'"
```

---

## EMON Collection — Network Workload PMU Events

Start EMON/perf collection on **both systems** before running any test group.
Stop and collect after all groups complete. Runs for the duration of all iperf3 tests.

**Why collect on both systems:** SERVER processes NIC Rx/Tx interrupts + TCP stack;
CLIENT drives the traffic generation. Both show different CPU bottleneck signatures.

### Network-Workload Event Set

```
cycles
instructions
cache-misses
LLC-load-misses
cpu-migrations
context-switches
page-faults
irq:softirq_entry
irq:softirq_exit
```

`cpu-migrations` and `context-switches` are the primary OS noise signals for NIC workloads.
`LLC-load-misses` reveals whether packet buffers are evicting data from L3 (NUMA mismatch).
`irq:softirq_entry/exit` counts per-interval NIC interrupt burden.

### Start EMON — Before Group A

```bash
OUT=${OUTPUT_DIR:-/tmp/iperf3_results}
mkdir -p $OUT

# Network PMU events — valid on Intel and AMD
NET_EVENTS="cycles,instructions,cache-misses,LLC-load-misses,cpu-migrations,context-switches,page-faults"

# Add softirq tracepoints if available (kernel ≥ 5.10)
perf list tracepoint 2>/dev/null | grep -q softirq \
    && NET_EVENTS="${NET_EVENTS},irq:softirq_entry,irq:softirq_exit"

# Start perf on SERVER (collects host-side NIC interrupt + TCP Rx processing cost)
ssh $SERVER_HOST "nohup perf stat \
    -e ${NET_EVENTS} \
    -a --interval-print 5000 \
    -o /tmp/iperf3_perf_server.txt \
    sleep 86400 \
    > /tmp/iperf3_perf_server.log 2>&1 & echo \$! > /tmp/iperf3_perf_server.pid"

# Start perf on CLIENT (collects client-side send cost)
ssh $CLIENT_HOST "nohup perf stat \
    -e ${NET_EVENTS} \
    -a --interval-print 5000 \
    -o /tmp/iperf3_perf_client.txt \
    sleep 86400 \
    > /tmp/iperf3_perf_client.log 2>&1 & echo \$! > /tmp/iperf3_perf_client.pid"

echo "EMON started on both systems."
ssh $SERVER_HOST "cat /tmp/iperf3_perf_server.pid"
ssh $CLIENT_HOST "cat /tmp/iperf3_perf_client.pid"
```

### Stop EMON — After All Groups Complete

```bash
# Stop on both systems
ssh $SERVER_HOST "
    PID=\$(cat /tmp/iperf3_perf_server.pid 2>/dev/null)
    [ -n \"\$PID\" ] && kill -INT \$PID && sleep 3 && echo 'SERVER perf stopped'"

ssh $CLIENT_HOST "
    PID=\$(cat /tmp/iperf3_perf_client.pid 2>/dev/null)
    [ -n \"\$PID\" ] && kill -INT \$PID && sleep 3 && echo 'CLIENT perf stopped'"

# Retrieve to local output dir
scp ${SERVER_HOST}:/tmp/iperf3_perf_server.txt $OUT/emon_server.txt
scp ${CLIENT_HOST}:/tmp/iperf3_perf_client.txt $OUT/emon_client.txt
echo "EMON data saved to: $OUT/emon_server.txt  $OUT/emon_client.txt"
```

### Parse EMON Results

```bash
# Extract key metrics from each interval (5-second buckets)
awk '
/context-switches/ { printf "ctx_switches: %s\n", $1 }
/cpu-migrations/   { printf "cpu_migrate:   %s\n", $1 }
/LLC-load-misses/  { printf "LLC_miss:      %s\n", $1 }
/cache-misses/     { printf "cache_miss:    %s\n", $1 }
/softirq_entry/    { printf "softirq:       %s\n", $1 }
' $OUT/emon_server.txt | head -60

# Interpretation thresholds for NIC workloads:
# context-switches/s  < 3,000     → healthy (> 50,000/s = OS noise, kills NIC perf)
# cpu-migrations/s    < 100       → healthy (> 500/s = NUMA locality broken)
# LLC-load-misses     low         → packet buffers fit in L3 / NUMA-local
# LLC-load-misses     high        → cross-NUMA DMA or buffer fragmentation
# softirq_entry/s     ~NIC IRQ rate → validate against ethtool -S interrupt counts
```

**EMON correlation with throughput:**
- If `cpu-migrations` > 500/s AND throughput < 350 Gbps → IRQ affinity not set; run Group F config C
- If `LLC-load-misses` > 5% of loads AND throughput < 360 Gbps → NUMA mismatch; check NIC PCIe NUMA node vs iperf3 CPU affinity
- If `context-switches` > 10,000/s → irqbalance running and routing NIC interrupts to random cores; `systemctl stop irqbalance`

---

## Group A — Single-Stream TCP Bandwidth (Subtests 108.001–108.006)

Single-stream establishes the baseline. At 400GbE, single-stream TCP is limited by
CPU per-packet processing overhead. Expect ~330–360 Gbps with `-w 256m`; multi-stream
(Group B) is needed to approach line rate.

```bash
OUT=${OUTPUT_DIR:-/tmp/iperf3_results}
mkdir -p $OUT
DUR=${DURATION:-30}

# 108.001 — Link1 TCP Transmit (B → A, single stream)
ssh $CLIENT_HOST "iperf3 -c ${IP_A0} -B ${IP_B0} -p 5201 \
    -t $DUR -w 256m -P 1 --json" | tee $OUT/108.001_link1_tx_p1.json

# 108.002 — Link1 TCP Receive (A → B, reverse)
ssh $CLIENT_HOST "iperf3 -c ${IP_A0} -B ${IP_B0} -p 5201 \
    -t $DUR -w 256m -P 1 -R --json" | tee $OUT/108.002_link1_rx_p1.json

# 108.003 — Link1 TCP Bidirectional
ssh $CLIENT_HOST "iperf3 -c ${IP_A0} -B ${IP_B0} -p 5201 \
    -t $DUR -w 256m -P 1 --bidir --json" | tee $OUT/108.003_link1_bidir_p1.json

# 108.004 — Link2 TCP Transmit
ssh $CLIENT_HOST "iperf3 -c ${IP_A1} -B ${IP_B1} -p 5202 \
    -t $DUR -w 256m -P 1 --json" | tee $OUT/108.004_link2_tx_p1.json

# 108.005 — Link2 TCP Receive
ssh $CLIENT_HOST "iperf3 -c ${IP_A1} -B ${IP_B1} -p 5202 \
    -t $DUR -w 256m -P 1 -R --json" | tee $OUT/108.005_link2_rx_p1.json

# 108.006 — Link2 TCP Bidirectional
ssh $CLIENT_HOST "iperf3 -c ${IP_A1} -B ${IP_B1} -p 5202 \
    -t $DUR -w 256m -P 1 --bidir --json" | tee $OUT/108.006_link2_bidir_p1.json
```

---

## Group B — Multi-Stream TCP (Line-Rate Saturation, Subtests 108.007–108.014)

Multiple parallel streams (`-P`) allow the NIC to use multiple TX/RX descriptor queues and
fill the pipe. For 400GbE, `-P 8` with `-w 256m` typically achieves ≥ 380 Gbps.
`-P 16` with `-w 512m` pushes ≥ 390 Gbps and is the recommended validation mode.

```bash
# 108.007 — Link1 TCP -P8 Transmit
ssh $CLIENT_HOST "iperf3 -c ${IP_A0} -B ${IP_B0} -p 5201 \
    -t $DUR -w 256m -P 8 --json" | tee $OUT/108.007_link1_tx_p8.json

# 108.008 — Link1 TCP -P8 Bidirectional
ssh $CLIENT_HOST "iperf3 -c ${IP_A0} -B ${IP_B0} -p 5201 \
    -t $DUR -w 256m -P 8 --bidir --json" | tee $OUT/108.008_link1_bidir_p8.json

# 108.009 — Link1 TCP -P16 Transmit (max pressure run)
ssh $CLIENT_HOST "iperf3 -c ${IP_A0} -B ${IP_B0} -p 5201 \
    -t $DUR -w 512m -P 16 --json" | tee $OUT/108.009_link1_tx_p16.json

# 108.010 — Link1 TCP -P16 Bidirectional
ssh $CLIENT_HOST "iperf3 -c ${IP_A0} -B ${IP_B0} -p 5201 \
    -t $DUR -w 512m -P 16 --bidir --json" | tee $OUT/108.010_link1_bidir_p16.json

# 108.011 — Link2 TCP -P8 Transmit
ssh $CLIENT_HOST "iperf3 -c ${IP_A1} -B ${IP_B1} -p 5202 \
    -t $DUR -w 256m -P 8 --json" | tee $OUT/108.011_link2_tx_p8.json

# 108.012 — Link2 TCP -P8 Bidirectional
ssh $CLIENT_HOST "iperf3 -c ${IP_A1} -B ${IP_B1} -p 5202 \
    -t $DUR -w 256m -P 8 --bidir --json" | tee $OUT/108.012_link2_bidir_p8.json

# 108.013 — Link2 TCP -P16 Transmit
ssh $CLIENT_HOST "iperf3 -c ${IP_A1} -B ${IP_B1} -p 5202 \
    -t $DUR -w 512m -P 16 --json" | tee $OUT/108.013_link2_tx_p16.json

# 108.014 — Link2 TCP -P16 Bidirectional
ssh $CLIENT_HOST "iperf3 -c ${IP_A1} -B ${IP_B1} -p 5202 \
    -t $DUR -w 512m -P 16 --bidir --json" | tee $OUT/108.014_link2_bidir_p16.json
```

---

## Group C — NIC Aggregate (Both Links Simultaneously, Subtests 108.015–108.018)

Runs Link1 and Link2 tests in parallel to load the full NIC at 800 Gbps.
This is the primary validation of aggregate NIC throughput — the ceiling for any
workload that distributes I/O across both ports (bonding, multipath NVMe-oF, etc.).

```bash
# 108.015 — Both links Tx simultaneously (aggregate ~800 Gbps target)
ssh $CLIENT_HOST "iperf3 -c ${IP_A0} -B ${IP_B0} -p 5201 \
    -t $DUR -w 256m -P 8 --json > /tmp/agg_link1.json" &
ssh $CLIENT_HOST "iperf3 -c ${IP_A1} -B ${IP_B1} -p 5202 \
    -t $DUR -w 256m -P 8 --json > /tmp/agg_link2.json" &
wait
ssh $CLIENT_HOST "cat /tmp/agg_link1.json" > $OUT/108.015_agg_tx_link1.json
ssh $CLIENT_HOST "cat /tmp/agg_link2.json" > $OUT/108.015_agg_tx_link2.json

# 108.016 — Both links Rx simultaneously
ssh $CLIENT_HOST "iperf3 -c ${IP_A0} -B ${IP_B0} -p 5201 \
    -t $DUR -w 256m -P 8 -R --json > /tmp/agg_rx_link1.json" &
ssh $CLIENT_HOST "iperf3 -c ${IP_A1} -B ${IP_B1} -p 5202 \
    -t $DUR -w 256m -P 8 -R --json > /tmp/agg_rx_link2.json" &
wait
ssh $CLIENT_HOST "cat /tmp/agg_rx_link1.json" > $OUT/108.016_agg_rx_link1.json
ssh $CLIENT_HOST "cat /tmp/agg_rx_link2.json" > $OUT/108.016_agg_rx_link2.json

# 108.017 — Both links BiDir simultaneously (full duplex, ~1.6 Tbps aggregate)
ssh $CLIENT_HOST "iperf3 -c ${IP_A0} -B ${IP_B0} -p 5201 \
    -t $DUR -w 512m -P 16 --bidir --json > /tmp/agg_bidir_link1.json" &
ssh $CLIENT_HOST "iperf3 -c ${IP_A1} -B ${IP_B1} -p 5202 \
    -t $DUR -w 512m -P 16 --bidir --json > /tmp/agg_bidir_link2.json" &
wait
ssh $CLIENT_HOST "cat /tmp/agg_bidir_link1.json" > $OUT/108.017_agg_bidir_link1.json
ssh $CLIENT_HOST "cat /tmp/agg_bidir_link2.json" > $OUT/108.017_agg_bidir_link2.json

# 108.018 — Both links BiDir -P8 (NIC thermal/power ceiling validation)
ssh $CLIENT_HOST "iperf3 -c ${IP_A0} -B ${IP_B0} -p 5201 \
    -t 60 -w 256m -P 8 --bidir --json > /tmp/agg_bidir_p8_link1.json" &
ssh $CLIENT_HOST "iperf3 -c ${IP_A1} -B ${IP_B1} -p 5202 \
    -t 60 -w 256m -P 8 --bidir --json > /tmp/agg_bidir_p8_link2.json" &
wait
ssh $CLIENT_HOST "cat /tmp/agg_bidir_p8_link1.json" > $OUT/108.018_agg_bidir_p8_link1.json
ssh $CLIENT_HOST "cat /tmp/agg_bidir_p8_link2.json" > $OUT/108.018_agg_bidir_p8_link2.json
```

**Compute aggregate after Group C:**
```bash
# Sum throughput across both links (Gbps)
python3 -c "
import json, sys

def gbps(f):
    d = json.load(open(f))
    bps = d['end']['sum_sent']['bits_per_second']
    return bps / 1e9

l1 = gbps('$OUT/108.015_agg_tx_link1.json')
l2 = gbps('$OUT/108.015_agg_tx_link2.json')
print(f'Link1: {l1:.1f} Gbps')
print(f'Link2: {l2:.1f} Gbps')
print(f'NIC aggregate: {l1+l2:.1f} Gbps  (target ≥ 760 Gbps)')
"
```

---

## Group D — UDP Latency (Subtests 108.019–108.022)

Measures round-trip network latency using iperf3 UDP mode.
For back-to-back 400GbE direct connect, expect ≤ 5 µs RTT.
UDP latency here implies a loopback measure — use `--udp-counters-64bit` for accuracy.

> **Note:** iperf3 UDP latency is not a precision tool. For µs-level latency validation
> (HFT/RDMA workloads), use `perftest` (`ib_send_lat`) instead. iperf3 UDP gives
> a first-pass network health check only.

```bash
# 108.019 — Link1 UDP bandwidth + jitter baseline
ssh $CLIENT_HOST "iperf3 -c ${IP_A0} -B ${IP_B0} -p 5201 \
    -u -b 10G -t 10 --json" | tee $OUT/108.019_link1_udp.json
# Parse jitter: jq '.end.sum.jitter_ms' $OUT/108.019_link1_udp.json

# 108.020 — Link2 UDP bandwidth + jitter baseline
ssh $CLIENT_HOST "iperf3 -c ${IP_A1} -B ${IP_B1} -p 5202 \
    -u -b 10G -t 10 --json" | tee $OUT/108.020_link2_udp.json

# 108.021 — Link1 UDP line-rate push (fill the pipe)
# Warning: this will generate ~400 Gbps of UDP traffic — only run on isolated links
ssh $CLIENT_HOST "iperf3 -c ${IP_A0} -B ${IP_B0} -p 5201 \
    -u -b 400G -l 9000 -t 15 --json" | tee $OUT/108.021_link1_udp_linerate.json
# Check lost_percent: jq '.end.sum.lost_percent' $OUT/108.021_link1_udp_linerate.json

# 108.022 — Link2 UDP line-rate push
ssh $CLIENT_HOST "iperf3 -c ${IP_A1} -B ${IP_B1} -p 5202 \
    -u -b 400G -l 9000 -t 15 --json" | tee $OUT/108.022_link2_udp_linerate.json
```

---

## Group E — Sustained Stability (Subtests 108.023–108.026)

60-second runs to confirm throughput does not throttle due to thermal, PCIe credit
starvation, or interrupt coalescing timeouts that do not appear in short 30s runs.

```bash
# 108.023 — Link1 60s sustained Tx -P8 (thermal/clock stability)
ssh $CLIENT_HOST "iperf3 -c ${IP_A0} -B ${IP_B0} -p 5201 \
    -t 60 -w 256m -P 8 --json" | tee $OUT/108.023_link1_sustained_tx.json

# 108.024 — Link2 60s sustained Tx -P8
ssh $CLIENT_HOST "iperf3 -c ${IP_A1} -B ${IP_B1} -p 5202 \
    -t 60 -w 256m -P 8 --json" | tee $OUT/108.024_link2_sustained_tx.json

# 108.025 — Both links 60s BiDir (NIC power envelope validation)
ssh $CLIENT_HOST "iperf3 -c ${IP_A0} -B ${IP_B0} -p 5201 \
    -t 60 -w 256m -P 8 --bidir --json > /tmp/sust_bidir_l1.json" &
ssh $CLIENT_HOST "iperf3 -c ${IP_A1} -B ${IP_B1} -p 5202 \
    -t 60 -w 256m -P 8 --bidir --json > /tmp/sust_bidir_l2.json" &
wait
ssh $CLIENT_HOST "cat /tmp/sust_bidir_l1.json" > $OUT/108.025_agg_bidir_60s_link1.json
ssh $CLIENT_HOST "cat /tmp/sust_bidir_l2.json" > $OUT/108.025_agg_bidir_60s_link2.json

# 108.026 — CPU utilization snapshot during peak (Link1 -P16, 30s)
ssh $CLIENT_HOST "iperf3 -c ${IP_A0} -B ${IP_B0} -p 5201 \
    -t 30 -w 512m -P 16 --json > /tmp/cpu_check.json &
    top -b -n 6 -d 5 | grep -E 'Cpu|iowait' > /tmp/top_during_iperf3.txt;
    wait"
ssh $CLIENT_HOST "cat /tmp/cpu_check.json" > $OUT/108.026_link1_cpu_check.json
ssh $CLIENT_HOST "cat /tmp/top_during_iperf3.txt" > $OUT/108.026_link1_cpu_top.txt
```

---

## Group F — Config Sweep: Path to 400 Gbps (Subtests 108.F.1–108.F.16)

Systematic single-variable sweep revealing which conditions are needed to hit 400 Gbps.
Run this group when initial results fall below the threshold — it isolates the bottleneck.
Each subtest is 15 seconds. Total sweep runtime ≈ 4 minutes.

**Run Group F EMON:** Keep perf stat running from the EMON section above throughout this group.

```bash
OUT=${OUTPUT_DIR:-/tmp/iperf3_results}
mkdir -p $OUT/config_sweep
CSWEEP_LOG=$OUT/config_sweep/sweep_results.txt
> $CSWEEP_LOG
echo "# Config sweep — Link1 TCP Tx — $(date)" | tee -a $CSWEEP_LOG
echo "# config  streams  window  cca  mtu  result_gbps" | tee -a $CSWEEP_LOG

# Helper: run one config and log result
sweep_run() {
    local label=$1 streams=$2 window=$3 cca=$4
    local result
    # Set CCA on both systems
    ssh $SERVER_HOST "sysctl -w net.ipv4.tcp_congestion_control=$cca" &>/dev/null
    ssh $CLIENT_HOST "sysctl -w net.ipv4.tcp_congestion_control=$cca" &>/dev/null
    result=$(ssh $CLIENT_HOST \
        "iperf3 -c ${IP_A0} -B ${IP_B0} -p 5201 \
         -t 15 -w ${window} -P ${streams} --json 2>/dev/null \
         | python3 -c \
           'import json,sys; d=json.load(sys.stdin); \
            print(\"%.1f\" % (d[\"end\"][\"sum_sent\"][\"bits_per_second\"]/1e9))'")
    printf "%-30s  P%-2s  %-5s  %-6s  %s Gbps\n" \
        "$label" "$streams" "$window" "$cca" "$result" | tee -a $CSWEEP_LOG
}

### Config A — MTU Impact (Biggest Single Factor)
# 108.F.1 — Baseline: MTU 9000 (jumbo), -P8, BBR
ssh $SERVER_HOST "ip link set $IFACE_A0 mtu 9000"
ssh $CLIENT_HOST "ip link set $IFACE_A0 mtu 9000"
sweep_run "F.1  MTU9000-P8-bbr"  8 256m bbr

# 108.F.2 — MTU 1500 (standard) — shows penalty without jumbo frames
ssh $SERVER_HOST "ip link set $IFACE_A0 mtu 1500"
ssh $CLIENT_HOST "ip link set $IFACE_A0 mtu 1500"    # expect: ~180-230 Gbps
sweep_run "F.2  MTU1500-P8-bbr"  8 256m bbr

# Restore MTU 9000 for remaining tests
ssh $SERVER_HOST "ip link set $IFACE_A0 mtu 9000"
ssh $CLIENT_HOST "ip link set $IFACE_A0 mtu 9000"

### Config B — Parallel Stream Count Sweep
# 108.F.3 — -P1: single stream ceiling
sweep_run "F.3  MTU9000-P1-bbr"   1  256m bbr   # expect: ~330-345 Gbps
# 108.F.4 — -P4
sweep_run "F.4  MTU9000-P4-bbr"   4  256m bbr   # expect: ~365-375 Gbps
# 108.F.5 — -P8 (reference)
sweep_run "F.5  MTU9000-P8-bbr"   8  256m bbr   # expect: ~380-390 Gbps
# 108.F.6 — -P16
sweep_run "F.6  MTU9000-P16-bbr"  16 512m bbr   # expect: ~388-395 Gbps
# 108.F.7 — -P32 (diminishing return, may trigger interrupt coalescing)
sweep_run "F.7  MTU9000-P32-bbr"  32 512m bbr   # expect: ~385-393 Gbps (may not beat P16)

### Config C — TCP Congestion Control Algorithm
# 108.F.8 — BBR (reference)
sweep_run "F.8  MTU9000-P8-bbr"   8 256m bbr
# 108.F.9 — Cubic (default Linux CCA)
sweep_run "F.9  MTU9000-P8-cubic" 8 256m cubic  # expect: within 3% of BBR for short back-to-back
# 108.F.10 — HTCP (if available)
ssh $CLIENT_HOST "sysctl net.ipv4.tcp_available_congestion_control | grep -q htcp" && \
    sweep_run "F.10 MTU9000-P8-htcp" 8 256m htcp || \
    echo "F.10 htcp not available — skipping" | tee -a $CSWEEP_LOG

### Config D — TCP Window Size Sweep
# 108.F.11 — Small window (shows TCP window as bottleneck)
ssh $CLIENT_HOST "sysctl -w net.ipv4.tcp_congestion_control=bbr"
ssh $SERVER_HOST "sysctl -w net.ipv4.tcp_congestion_control=bbr"
sweep_run "F.11 MTU9000-P8-w32m"  8 32m  bbr    # expect: < 200 Gbps — window too small
# 108.F.12 — Medium window
sweep_run "F.12 MTU9000-P8-w64m"  8 64m  bbr    # expect: ~250-300 Gbps
# 108.F.13 — Standard window
sweep_run "F.13 MTU9000-P8-w128m" 8 128m bbr    # expect: ~340-370 Gbps
# 108.F.14 — Full window (reference)
sweep_run "F.14 MTU9000-P8-w256m" 8 256m bbr    # expect: ~380-390 Gbps

### Config E — IRQ Coalescing (interrupt rate vs latency tradeoff)
# 108.F.15 — Aggressive coalescing (high throughput mode)
ssh $SERVER_HOST "ethtool -C ${IFACE_A0} rx-usecs 50 tx-usecs 50"
ssh $CLIENT_HOST "ethtool -C ${IFACE_A0} rx-usecs 50 tx-usecs 50"
sweep_run "F.15 MTU9000-P8-coal50" 8 256m bbr   # expect: ~385-393 Gbps (best throughput)

# 108.F.16 — No coalescing (interrupt every packet — throughput drops, latency improves)
ssh $SERVER_HOST "ethtool -C ${IFACE_A0} rx-usecs 0 tx-usecs 0"
ssh $CLIENT_HOST "ethtool -C ${IFACE_A0} rx-usecs 0 tx-usecs 0"
sweep_run "F.16 MTU9000-P8-coal0"  8 256m bbr   # expect: ~300-350 Gbps (CPU overwhelmed by IRQs)

# Restore coalescing to recommended value
ssh $SERVER_HOST "ethtool -C ${IFACE_A0} rx-usecs 50 tx-usecs 50"
ssh $CLIENT_HOST "ethtool -C ${IFACE_A0} rx-usecs 50 tx-usecs 50"

echo "Config sweep complete → $CSWEEP_LOG"
```

### Config Sweep — Expected Output Table

```
# config                       streams  window  cca     result
F.1  MTU9000-P8-bbr            P8   256m   bbr     391.2 Gbps   ← ✅ baseline (jumbo frames OK)
F.2  MTU1500-P8-bbr            P8   256m   bbr     198.4 Gbps   ← ❌ MTU 1500 penalty (-49%)
F.3  MTU9000-P1-bbr            P1   256m   bbr     338.7 Gbps   ← single stream ceiling
F.4  MTU9000-P4-bbr            P4   256m   bbr     371.3 Gbps   ← ramp-up with more streams
F.5  MTU9000-P8-bbr            P8   256m   bbr     390.8 Gbps   ← ✅ sweet spot
F.6  MTU9000-P16-bbr           P16  512m   bbr     393.1 Gbps   ← marginal gain
F.7  MTU9000-P32-bbr           P32  512m   bbr     391.5 Gbps   ← no benefit, more CPU
F.8  MTU9000-P8-bbr (ref)      P8   256m   bbr     390.8 Gbps
F.9  MTU9000-P8-cubic          P8   256m   cubic   388.3 Gbps   ← cubic ~1% lower, acceptable
F.11 MTU9000-P8-w32m           P8   32m    bbr     187.5 Gbps   ← ❌ window bottleneck
F.12 MTU9000-P8-w64m           P8   64m    bbr     278.4 Gbps   ← partial
F.13 MTU9000-P8-w128m          P8   128m   bbr     354.1 Gbps   ← close but not there
F.14 MTU9000-P8-w256m (ref)    P8   256m   bbr     390.8 Gbps   ← ✅ required minimum
F.15 MTU9000-P8-coal50         P8   256m   bbr     393.6 Gbps   ← ✅ best config
F.16 MTU9000-P8-coal0          P8   256m   bbr     312.4 Gbps   ← ❌ no coalescing, CPU IRQ flood
```

### Reading the Sweep: What Gets You to 400 Gbps

| Condition | Impact | Without it | With it |
|---|---|---|---|
| MTU 9000 (jumbo frames) | **Mandatory** | ~200 Gbps cap | ~390 Gbps |
| TCP window ≥ 256m | **Mandatory** | ~280 Gbps cap | ~390 Gbps |
| Parallel streams ≥ 8 | **Required** | ~340 Gbps (P1) | ~390 Gbps |
| IRQ coalescing `rx-usecs 50` | High impact | ~312 Gbps (coal=0) | ~393 Gbps |
| NIC queue count ≥ 8 | Required for -P8+ | stalls at P1 rate | multi-queue fills pipe |
| Congestion control (BBR/cubic) | Minor | cubic ~1% lower | bbr reference |
| AES offload / DPDK | Optional | SW stack overhead | +5-10 Gbps for TLS |

**Decision tree for sub-400 Gbps result:**
```
Result < 250 Gbps?
    → CHECK MTU: ip link show | grep mtu  (must be 9000)
Result 250–350 Gbps?
    → CHECK TCP window: sysctl net.core.rmem_max  (must be ≥ 536870912)
    → CHECK parallel streams: increase -P to 8 or 16
Result 350–375 Gbps?
    → CHECK IRQ coalescing: ethtool -c $IFACE | grep usecs
    → CHECK NIC queue count: ethtool -l $IFACE | grep Combined
    → CHECK IRQ affinity: cat /proc/interrupts | grep $IFACE (must be on NUMA-local CPUs)
Result 375–390 Gbps?
    → CHECK PCIe link: lspci -vv | grep -A2 $NIC_PCI | grep LnkSta  (must be Gen5 x16)
    → NORMAL: 390-393 Gbps is maximum for SW TCP stack; 400G = NIC line rate, TCP overhead ~2%
```

---

## Parsing Results

```bash
OUT=${OUTPUT_DIR:-/tmp/iperf3_results}

# Parse throughput from any iperf3 JSON result
parse_gbps() {
    local f=$1
    python3 -c "
import json
d = json.load(open('$f'))
tx = d['end'].get('sum_sent',  d['end'].get('sum',{})).get('bits_per_second', 0) / 1e9
rx = d['end'].get('sum_received', {}).get('bits_per_second', 0) / 1e9
if rx > 0:
    print(f'Tx: {tx:.1f} Gbps  Rx: {rx:.1f} Gbps')
else:
    print(f'{tx:.1f} Gbps')
"
}

# Print all results
for f in $OUT/108.*.json; do
    id=$(basename $f .json)
    result=$(parse_gbps "$f" 2>/dev/null || echo "parse error")
    printf "%-50s  %s\n" "$id" "$result"
done

# Check pass/fail for multi-stream runs (≥ 380 Gbps threshold)
echo ""
echo "=== PASS/FAIL (≥ 380 Gbps threshold for -P8/-P16 runs) ==="
for f in $OUT/108.00{7,8,9}*.json $OUT/108.01*.json; do
    [[ -f "$f" ]] || continue
    id=$(basename $f .json)
    gbps=$(python3 -c "
import json
d = json.load(open('$f'))
print(d['end'].get('sum_sent', d['end'].get('sum',{})).get('bits_per_second',0)/1e9)
" 2>/dev/null)
    status=$(python3 -c "print('✅ PASS' if $gbps >= 380 else '❌ FAIL')" 2>/dev/null)
    printf "%-50s  %.1f Gbps  %s\n" "$id" "$gbps" "$status"
done
```

---

## Reference Values — Intel E810 400GbE (Back-to-Back, MTU 9000)

Measured reference for Intel Ethernet 800 Series E810-C2Q NIC, direct-connect,
CentOS Stream / RHEL 9, ice driver, BBR congestion control, sysctl-tuned.

| # | Subtest | Mode | Reference | Pass Threshold |
|---|---|---|---|---|
| 108.001 | Link1 TCP Tx | -P1 -w256m | ~340 Gbps | ≥ 300 Gbps |
| 108.002 | Link1 TCP Rx | -P1 -w256m -R | ~340 Gbps | ≥ 300 Gbps |
| 108.003 | Link1 TCP BiDir | -P1 --bidir | ~330 Gbps each dir | ≥ 280 Gbps each |
| 108.004 | Link2 TCP Tx | -P1 -w256m | ~340 Gbps | ≥ 300 Gbps |
| 108.005 | Link2 TCP Rx | -P1 -w256m -R | ~340 Gbps | ≥ 300 Gbps |
| 108.006 | Link2 TCP BiDir | -P1 --bidir | ~330 Gbps each dir | ≥ 280 Gbps each |
| 108.007 | Link1 TCP Tx | -P8 -w256m | ~385 Gbps | ≥ 370 Gbps |
| 108.008 | Link1 TCP BiDir | -P8 --bidir | ~382 Gbps each dir | ≥ 360 Gbps each |
| 108.009 | Link1 TCP Tx | -P16 -w512m | ~393 Gbps | ≥ 380 Gbps |
| 108.010 | Link1 TCP BiDir | -P16 --bidir | ~390 Gbps each dir | ≥ 370 Gbps each |
| 108.011 | Link2 TCP Tx | -P8 -w256m | ~385 Gbps | ≥ 370 Gbps |
| 108.012 | Link2 TCP BiDir | -P8 --bidir | ~382 Gbps each dir | ≥ 360 Gbps each |
| 108.013 | Link2 TCP Tx | -P16 -w512m | ~393 Gbps | ≥ 380 Gbps |
| 108.014 | Link2 TCP BiDir | -P16 --bidir | ~390 Gbps each dir | ≥ 370 Gbps each |
| 108.015 | Agg Tx (both links) | -P8 simultaneous | ~770 Gbps total | ≥ 750 Gbps |
| 108.016 | Agg Rx (both links) | -P8 simultaneous | ~770 Gbps total | ≥ 750 Gbps |
| 108.017 | Agg BiDir | -P16 simultaneous | ~780 Gbps each dir (1.56 Tbps) | ≥ 740 Gbps each dir |
| 108.018 | Agg BiDir 60s | -P8 60s | ~770 Gbps (no thermal drop) | ≥ 730 Gbps |
| 108.019 | Link1 UDP jitter | -u -b 10G | ≤ 0.05 ms jitter | ≤ 0.1 ms |
| 108.020 | Link2 UDP jitter | -u -b 10G | ≤ 0.05 ms jitter | ≤ 0.1 ms |
| 108.021 | Link1 UDP line-rate | -u -b 400G | < 0.1% loss | ≤ 0.5% loss |
| 108.022 | Link2 UDP line-rate | -u -b 400G | < 0.1% loss | ≤ 0.5% loss |
| 108.023 | Link1 sustained Tx | -P8 60s | ~385 Gbps (stable) | ≥ 370 Gbps; no >5% sag |
| 108.024 | Link2 sustained Tx | -P8 60s | ~385 Gbps (stable) | ≥ 370 Gbps; no >5% sag |
| 108.025 | Agg BiDir 60s | both links -P8 | ~770 Gbps (stable) | ≥ 730 Gbps |
| 108.026 | CPU during peak | -P16 top | < 40% total CPU for NIC Tx | CPU not bottleneck |

**Key observations (reference topology):**
- **Single stream (-P1):** ~340 Gbps — limited by single-flow TCP send rate on one CPU core
- **Multi-stream (-P8):** ~385 Gbps — fills all NIC TX descriptor queues (95% line rate)
- **Multi-stream (-P16):** ~393 Gbps — diminishing return vs -P8; gains ~2%
- **BiDir aggregate:** ~780 Gbps per NIC — full-duplex NIC utilization (near 800G NIC nameplate)
- **Thermal/stability:** No throughput sag expected on 60s runs for direct-connect back-to-back
- **CPU overhead:** Intel E810 with DPDK TX offload enabled ≈ 25–35% CPU for 400Gbps

---

## Pass Thresholds Summary

| Mode | Threshold | FAIL indicator |
|---|---|---|
| Single stream (-P1) per link | ≥ 300 Gbps | MTU mismatch or TCP buffer too small |
| Multi-stream -P8 per link | ≥ 370 Gbps | IRQ affinity, ring buffer, or NUMA issue |
| Multi-stream -P16 per link | ≥ 380 Gbps | **Primary line-rate gate** |
| Both links aggregate | ≥ 750 Gbps | PCIe bandwidth saturation or NIC thermal |
| Both links BiDir aggregate | ≥ 740 Gbps each dir | PCIe Gen5 × 16 required; check slot |
| UDP loss at line rate | ≤ 0.5% | Packet drops → increase ring buffer / coalescing |
| Sustained 60s delta vs 30s | < +5% sag | NIC thermal throttle (check `ethtool -I` temp) |

**FAIL indicators to diagnose:**
- **< 200 Gbps on -P16:** MTU 1500 instead of 9000 — jumbo frames not set
- **< 300 Gbps on -P8 but > 300 Gbps on -P1:** IRQ coalescing too aggressive; try `ethtool -C $IFACE rx-usecs 10`
- **Throughput drops > 5% after 30s:** Check NIC temp `ethtool -m $IFACE | grep Temp` and PCIe link speed `lspci -vv | grep LnkSta`
- **BiDir much lower than Tx-only:** Asymmetric PCIe credit issue or RSS imbalance across RX queues
- **Link1 ≠ Link2 > 5%:** Per-port driver tuning needed; check `ethtool -l $IFACE` queue counts match

---

## Report Format

```
IPERF3 NETWORK BANDWIDTH SWEEP — Test 108 (Storage Segment Validation)
=======================================================================
System A (SERVER) : <CPU model>, <N>C, <OS>, NIC: <model>
System B (CLIENT) : <CPU model>, <N>C, <OS>
Topology          : Back-to-back, 2 × 400GbE links, MTU 9000
iperf3 version    : 3.x

SUBTEST     MODE             LINK   RESULT        THRESHOLD   STATUS
────────────────────────────────────────────────────────────────────
108.001     TCP Tx -P1       Link1  340 Gbps       ≥300 Gbps  ✅ PASS
108.007     TCP Tx -P8       Link1  385 Gbps       ≥370 Gbps  ✅ PASS
108.009     TCP Tx -P16      Link1  393 Gbps       ≥380 Gbps  ✅ PASS
108.010     TCP BiDir -P16   Link1  390/388 Gbps   ≥370 Gbps  ✅ PASS
108.015     Agg Tx (both)    Both   772 Gbps total ≥750 Gbps  ✅ PASS
108.017     Agg BiDir -P16   Both   781/779 Gbps   ≥740 Gbps  ✅ PASS
108.019     UDP jitter       Link1  0.04ms          ≤0.1ms     ✅ PASS
108.023     Sustained 60s    Link1  384 Gbps       ≥370 Gbps  ✅ PASS
  ... (all 26 rows) ...
────────────────────────────────────────────────────────────────────
Peak per link  : ~393 Gbps (-P16)     Line rate: 400 Gbps   Utilization: 98%
NIC aggregate  : ~772 Gbps (both Tx)  NIC limit: 800 Gbps   Utilization: 97%
Full duplex    : ~1.56 Tbps aggregate

VERDICT: PASS — Both 400GbE links operating at ≥ 97% line rate.
         Aggregate 800Gbps NIC bandwidth confirmed. Network is not the
         bottleneck for NVMe-oF or NAS workloads on this topology.
```

---

## Platform Notes

- **PCIe Gen5 ×16 required for 400GbE.** At 400Gbps per port (50 GB/s), the NIC needs
  ~100 GB/s PCIe bandwidth for full-duplex BiDir. PCIe Gen5 ×16 provides 128 GB/s per
  direction. Gen4 ×16 (64 GB/s) will bottleneck BiDir at ~400 Gbps aggregate.
  Verify: `lspci -vv | grep -A5 "Ethernet\|Network" | grep LnkSta`.

- **NUMA affinity matters at 400GbE.** If the NIC's PCIe root port is on NUMA node 0,
  run iperf3 with CPU affinity to NUMA-local cores (`taskset -c 0-15`). Cross-NUMA
  memory copies add ~40ns per cache line — at 400Gbps this becomes measurable CPU load.

- **`--bidir` requires iperf3 ≥ 3.7.** Check `iperf3 --version.` If older, simulate
  BiDir by running Tx and Rx tests simultaneously in separate SSH sessions.

- **`-w 512m` sets the per-socket TCP window.** This must be ≤ `net.core.rmem_max`.
  Verify: `sysctl net.core.rmem_max` — must be ≥ 536870912. Set in Phase 0 of
  Prerequisites above.

- **iperf3 server is single-threaded.** For highest throughput, the server process
  must be pinned to a CPU core near the NIC's PCIe endpoint. Use
  `taskset -c <NUMA-local core> iperf3 -s -B $IP`.

- **`-P` streams and queue count must match.** Intel E810 defaults to 8 queues per port.
  Running `-P 16` with only 8 hardware queues has diminishing returns. Check:
  `ethtool -l $IFACE_A0` — Combined: value should be ≥ the `-P` stream count.
  Set: `ethtool -L $IFACE_A0 combined 16` before running -P16 tests.
