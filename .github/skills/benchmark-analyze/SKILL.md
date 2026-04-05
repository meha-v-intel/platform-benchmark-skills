---
name: benchmark-analyze
description: "Analyze benchmark results and EMON telemetry to identify bottlenecks and predict tuning improvements. Use when: analyzing benchmark output, identifying performance bottlenecks, getting tuning recommendations, predicting improvement from system changes, understanding CPU or memory performance issues, generating benchmark insights report, what-if tuning analysis."
argument-hint: "[--session-id <id>]"
allowed-tools: Bash
---

# Benchmark Analysis, Bottleneck Detection & Predictions

Parses benchmark results, EMON telemetry, and system configuration from a completed session.
Identifies bottlenecks per domain, generates tuning recommendations with **quantified
predicted improvement ranges** and confidence levels based on Intel platform validation data.

## Variables Required

| Variable | Description | Example |
|---|---|---|
| `$SESSION_ID` | Session to analyze | `20260405T120000-a3f9c1` |
| `$USER_INTENT` | Original stated goal (for report framing) | `"validate for 3-tier banking"` |

---

## Step 1 — Load Inputs

```python
import json, os, re, glob

SESSION_ID = os.environ.get('SESSION_ID', '')
if not SESSION_ID:
    # Fall back to most recent session
    dirs = sorted(glob.glob('./results/*/sysconfig.json'), reverse=True)
    if dirs:
        SESSION_ID = dirs[0].split('/')[2]

BASE    = f'./results/{SESSION_ID}'
BENCH   = f'{BASE}/bench'
EMON    = f'{BASE}/emon'
SYSCONF = f'{BASE}/sysconfig.json'

sysconfig = {}
if os.path.exists(SYSCONF):
    sysconfig = json.load(open(SYSCONF))

USER_INTENT = os.environ.get('USER_INTENT', 'platform validation')
```

---

## Step 2 — Parse Benchmark Results

```python
# KPI extraction patterns per benchmark
PATTERNS = {
    'max_freq_mhz':     (r'Bzy_MHz[:\s]+(\d+)',                 'cpu'),
    'c2c_cycles':       (r'max\s+(\d+)\s+cycles',               'cpu'),
    'mem_latency_ns':   (r'(\d+\.?\d*)\s*ns',                   'memory'),
    'mem_bw_gbps':      (r'(\d+\.?\d*)\s*GBps',                 'memory'),
    'amx_bf16_gflops':  (r'(\d+\.?\d*)\s*GFLOPS.*BF16',        'amx'),
    'amx_int8_tops':    (r'(\d+\.?\d*)\s*TOPS.*INT8',           'amx'),
    'wakeup_median_us': (r'median[:\s]+(\d+\.?\d*)',            'wakeup'),
    'wakeup_max_us':    (r'max[:\s]+(\d+\.?\d*)',               'wakeup'),
}

THRESHOLDS = {
    'max_freq_mhz':     ('>=', 3600,  'GNR: 3300 MHz'),
    'c2c_cycles':       ('<=', 180,   'GNR: 63–71 cycles intra-SNC'),
    'mem_latency_ns':   ('<=', 139,   'GNR: 116 ns'),
    'mem_bw_gbps':      ('>=', 1454,  'GNR: 158 GB/s per socket'),
    'amx_bf16_gflops':  ('>=', 12600, 'GNR: 12,600 GFLOPS iso-core'),
    'amx_int8_tops':    ('>=', 22900, 'GNR: 22,900 TOPS iso-core'),
    'wakeup_median_us': ('<=', 90,    'GNR: 1.59 µs (wult)'),
    'wakeup_max_us':    ('<=', 260,   'GNR: 10.59 µs (wult)'),
}

results = {}

def extract_kpi(log_path, pattern):
    try:
        text = open(log_path).read()
        m = re.search(pattern, text, re.IGNORECASE)
        return float(m.group(1)) if m else None
    except FileNotFoundError:
        return None

def check_pass(kpi, value, op, threshold):
    if value is None:
        return 'N/A'
    if op == '>=':
        return 'PASS' if value >= threshold else 'FAIL'
    if op == '<=':
        return 'PASS' if value <= threshold else 'FAIL'
    return 'UNKNOWN'

bench_logs = {
    'cpu':     glob.glob(f'{BENCH}/cpu*.log') + glob.glob(f'{BENCH}/max_freq*.log') + glob.glob(f'{BENCH}/turbo*.log'),
    'memory':  glob.glob(f'{BENCH}/mem*.log') + glob.glob(f'{BENCH}/mlc*.log'),
    'amx':     glob.glob(f'{BENCH}/amx*.log'),
    'wakeup':  glob.glob(f'{BENCH}/wakeup*.log') + glob.glob(f'{BENCH}/wult*.log'),
}

kpis = {}
for kpi_name, (pattern, domain) in PATTERNS.items():
    for log in bench_logs.get(domain, []):
        val = extract_kpi(log, pattern)
        if val is not None:
            kpis[kpi_name] = val
            break
```

---

## Step 3 — Parse EMON Signals

```python
emon_signals = {}
perf_file = f'{EMON}/perf_stat.txt'

if os.path.exists(perf_file):
    text = open(perf_file).read()
    for line in text.splitlines():
        m = re.match(r'\s*([\d,\.]+)\s+([\w\-\./:]+)', line)
        if m:
            val_str = m.group(1).replace(',', '')
            try:
                emon_signals[m.group(2)] = float(val_str)
            except ValueError:
                pass

cycles = emon_signals.get('cycles', 0)
instrs = emon_signals.get('instructions', 0)
ipc    = instrs / cycles if cycles > 0 else None

llc_miss  = emon_signals.get('LLC-load-misses', 0)
llc_loads = emon_signals.get('LLC-loads', 1)
llc_miss_rate = llc_miss / llc_loads * 100 if llc_loads > 0 else None

branch_miss  = emon_signals.get('branch-misses', 0)
branch_total = emon_signals.get('branch-instructions', 1)
branch_miss_rate = branch_miss / branch_total * 100 if branch_total > 0 else None

l3_miss = emon_signals.get('mem_load_retired.l3_miss', None)
amx_int8 = emon_signals.get('amx_retired.int8_type', None)
amx_bf16 = emon_signals.get('amx_retired.bf16_type', None)
```

---

## Step 4 — Identify Bottlenecks

```python
bottlenecks = []

# CPU bottlenecks
freq = kpis.get('max_freq_mhz')
if freq and freq < 3600:
    bottlenecks.append({
        'id': 'B-CPU-FREQ', 'domain': 'CPU',
        'observed': f'{freq:.0f} MHz', 'expected': '≥3600 MHz (formal), ~2799 MHz DMR BKC',
        'delta': f'{(freq-3600)/3600*100:+.1f}%',
        'emon_signal': f"IPC={ipc:.2f}" if ipc else 'N/A',
        'sysconfig_note': f"governor={sysconfig.get('cpu',{}).get('governor','?')}, "
                          f"turbo_disabled={sysconfig.get('cpu',{}).get('turbo_disabled','?')}",
    })

if ipc and ipc < 1.0:
    bottlenecks.append({
        'id': 'B-CPU-IPC', 'domain': 'CPU',
        'observed': f'IPC={ipc:.2f}', 'expected': '>1.5 for compute workloads',
        'delta': f'{(ipc-1.5)/1.5*100:+.1f}%',
        'emon_signal': f"branch_miss_rate={branch_miss_rate:.1f}%" if branch_miss_rate else 'N/A',
        'sysconfig_note': 'Low IPC may indicate memory stalls or branch mispredictions.',
    })

c2c = kpis.get('c2c_cycles')
if c2c and c2c > 180:
    bottlenecks.append({
        'id': 'B-CPU-C2C', 'domain': 'CPU',
        'observed': f'{c2c:.0f} cycles', 'expected': '≤180 cycles',
        'delta': f'{(c2c-180)/180*100:+.1f}%',
        'emon_signal': f"IPC={ipc:.2f}" if ipc else 'N/A',
        'sysconfig_note': f"irqbalance={sysconfig.get('os',{}).get('irqbalance_active','?')}",
    })

# Memory bottlenecks
latency = kpis.get('mem_latency_ns')
if latency and latency > 139:
    bottlenecks.append({
        'id': 'B-MEM-LAT', 'domain': 'Memory',
        'observed': f'{latency:.1f} ns', 'expected': '≤139 ns',
        'delta': f'{(latency-139)/139*100:+.1f}%',
        'emon_signal': f"LLC miss rate={llc_miss_rate:.1f}%" if llc_miss_rate else 'N/A',
        'sysconfig_note': f"THP={sysconfig.get('memory',{}).get('transparent_hugepages','?')}, "
                          f"numa_balancing={sysconfig.get('memory',{}).get('numa_balancing_enabled','?')}",
    })

bw = kpis.get('mem_bw_gbps')
if bw and bw < 1454:
    bottlenecks.append({
        'id': 'B-MEM-BW', 'domain': 'Memory',
        'observed': f'{bw:.0f} GBps', 'expected': '≥1454 GBps',
        'delta': f'{(bw-1454)/1454*100:+.1f}%',
        'emon_signal': f"L3 miss={l3_miss:,.0f}" if l3_miss else 'N/A',
        'sysconfig_note': f"NUMA nodes={sysconfig.get('cpu',{}).get('numa_nodes','?')}",
    })

if llc_miss_rate and llc_miss_rate > 5.0:
    bottlenecks.append({
        'id': 'B-MEM-LLC', 'domain': 'Memory',
        'observed': f'LLC miss rate {llc_miss_rate:.1f}%', 'expected': '<5%',
        'delta': f'+{llc_miss_rate - 5:.1f}pp above threshold',
        'emon_signal': f"LLC-load-misses={llc_miss:,.0f}",
        'sysconfig_note': 'High LLC miss rate → workload exceeds LLC capacity → DRAM pressure.',
    })

# AI/AMX bottlenecks
bf16 = kpis.get('amx_bf16_gflops')
if bf16 and bf16 < 12600:
    bottlenecks.append({
        'id': 'B-AMX-BF16', 'domain': 'AI/AMX',
        'observed': f'{bf16:.0f} GFLOPS', 'expected': '>12,600 GFLOPS',
        'delta': f'{(bf16-12600)/12600*100:+.1f}%',
        'emon_signal': f"amx_bf16_ops={amx_bf16:,.0f}" if amx_bf16 else 'N/A',
        'sysconfig_note': f"OMP threads / binding affects AMX utilization.",
    })

# Wakeup latency bottlenecks
wake_med = kpis.get('wakeup_median_us')
if wake_med and wake_med > 90:
    bottlenecks.append({
        'id': 'B-WAKE-MED', 'domain': 'Latency',
        'observed': f'{wake_med:.1f} µs median', 'expected': '≤90 µs',
        'delta': f'{(wake_med-90)/90*100:+.1f}%',
        'emon_signal': 'N/A (wakeup is hardware latency)',
        'sysconfig_note': f"C-states={sysconfig.get('cpu',{}).get('c_states','?')}",
    })
```

---

## Step 5 — Tuning Recommendations with Predictions

```python
# Prediction table: bottleneck_id → list of (action, metric, pred_low%, pred_high%, confidence, basis)
TUNING_DB = {
    'B-CPU-FREQ': [
        ('Verify power limit: cat /sys/class/powercap/intel-rapl/intel-rapl:0/constraint_0_power_limit_uw',
         'CPU frequency', 5, 20, 'Medium', 'TDP throttle is common cause of below-BKC frequency'),
        ('Set performance governor: cpupower frequency-set -g performance',
         'CPU frequency', 5, 15, 'High', 'Intel BKM for benchmark runs; validated on DMR/GNR'),
        ('Check BIOS Turbo Boost setting (must be enabled)',
         'CPU frequency', 10, 25, 'High', 'Turbo disabled = hard cap at base freq'),
    ],
    'B-CPU-IPC': [
        ('Pin IRQ affinity away from benchmark cores: service irqbalance stop + set_irq_affinity',
         'IPC / execution efficiency', 3, 8, 'Medium', 'IRQ interference reduces effective IPC'),
        ('Disable address space layout randomization: echo 0 > /proc/sys/kernel/randomize_va_space',
         'Branch prediction accuracy', 2, 5, 'Low', 'ASLR perturbs branch predictor training'),
    ],
    'B-CPU-C2C': [
        ('Disable irqbalance and pin IRQ affinity: systemctl stop irqbalance',
         'Core-to-core latency', 10, 20, 'Medium', 'IRQ migration causes cache coherency traffic'),
        ('Disable hyperthreading for pure latency workloads (BIOS)',
         'Per-core cache partition', 5, 15, 'Medium', 'HT sharing of L1/L2 degrades c2c latency'),
    ],
    'B-MEM-LAT': [
        ('Enable 1GB HugePages: echo N > /sys/kernel/mm/hugepages/hugepages-1048576kB/nr_hugepages',
         'Memory latency', 8, 12, 'High', 'Reduces TLB misses; validated on Intel DMR/GNR'),
        ('Set THP to never: echo never > /sys/kernel/mm/transparent_hugepage/enabled',
         'Memory latency variance', 3, 6, 'Medium', 'THP compaction causes latency spikes'),
        ('Disable NUMA balancing: echo 0 > /proc/sys/kernel/numa_balancing',
         'Memory latency', 2, 5, 'Medium', 'Prevents page migration during measurement'),
        ('Pre-fault memory with mmap/memset before benchmarking',
         'First-access latency', 5, 10, 'High', 'Eliminates page fault overhead from results'),
    ],
    'B-MEM-BW': [
        ('Increase benchmark thread count to match NPROC',
         'Memory bandwidth', 10, 30, 'High', 'BW scales with active threads up to saturation'),
        ('Enable memory interleaving across NUMA nodes (if multi-NUMA): numactl --interleave=all',
         'Memory bandwidth', 5, 15, 'Medium', 'Distributes traffic across memory controllers'),
        ('Verify memory channels populated: dmidecode -t memory | grep Size',
         'Memory bandwidth', 20, 50, 'High', 'Unpopulated DIMM slots halve available channels'),
    ],
    'B-MEM-LLC': [
        ('Reduce benchmark working set size to fit in LLC',
         'LLC hit rate', 30, 60, 'High', 'Direct cause — working set exceeds LLC capacity'),
        ('Use NUMA-local allocation: numactl --localalloc',
         'LLC miss → DRAM latency', 5, 15, 'Medium', 'Remote NUMA LLC misses add ~60–80 ns'),
    ],
    'B-AMX-BF16': [
        ('Tune OMP_NUM_THREADS to match physical core count: export OMP_NUM_THREADS=$(nproc)',
         'AMX throughput', 10, 30, 'High', 'Under-threading is the most common AMX underperformance cause'),
        ('Set OMP_PROC_BIND=close OMP_PLACES=cores for iso-core tests',
         'AMX throughput', 5, 15, 'Medium', 'Reduces cross-NUMA AMX memory traffic'),
        ('Verify DNNL_MAX_CPU_ISA=AMX is set (not AVX512)',
         'AMX vs AVX512 selection', 15, 40, 'High', 'Without this, oneDNN may not select AMX kernels'),
    ],
    'B-WAKE-MED': [
        ('Disable deep C-states for RT workloads: cpupower idle-set --disable-by-latency 10',
         'Wakeup latency (median)', 20, 50, 'High', 'Prevents entry into C6 — eliminates slow exit path'),
        ('Use idle=poll kernel parameter (adds to cmdline)',
         'Wakeup latency (max)', 30, 60, 'Medium', 'Keeps cores spinning — eliminates C-state entirely; high power cost'),
        ('Pin application to isolated CPUs: isolcpus= on kernel cmdline',
         'Wakeup latency jitter', 10, 25, 'Medium', 'Isolates cores from OS scheduler interruptions'),
    ],
}

recommendations = []
for b in bottlenecks:
    bid = b['id']
    for action, metric, pred_lo, pred_hi, confidence, basis in TUNING_DB.get(bid, []):
        current = b['observed']
        recommendations.append({
            'bottleneck': bid,
            'action':     action,
            'metric':     metric,
            'pred_range': f'{pred_lo}%–{pred_hi}%',
            'confidence': confidence,
            'basis':      basis,
            'current':    current,
        })
```

---

## Step 6 — Generate Report

```python
cpu    = sysconfig.get('cpu', {})
intent = USER_INTENT

print(f"\n{'='*60}")
print(f"BENCHMARK INSIGHTS — {intent.upper()}")
print(f"{'='*60}")
print(f"Session  : {SESSION_ID}")
print(f"Platform : {cpu.get('model','?')}")
print(f"          {cpu.get('sockets','?')}S × {cpu.get('cores_per_socket','?')}C × {cpu.get('threads_per_core','?')}T = {cpu.get('logical_cpus','?')} logical CPUs")
print(f"          {cpu.get('numa_nodes','?')} NUMA node(s)")
print(f"OS       : {sysconfig.get('os',{}).get('release','?')[:60]}")
print()

print("RESULTS SUMMARY")
print("-" * 40)
for kpi_name, (pattern, domain) in PATTERNS.items():
    val = kpis.get(kpi_name)
    if val is not None:
        op, threshold, baseline = THRESHOLDS[kpi_name]
        status = check_pass(kpi_name, val, op, threshold)
        delta  = (val - threshold) / threshold * 100
        sign   = '+' if delta > 0 else ''
        print(f"  {kpi_name:<22}: {status}  {val:.1f}  (threshold: {op}{threshold}, {baseline}, {sign}{delta:.1f}%)")

if not kpis:
    print("  No benchmark result logs found in", BENCH)

if ipc is not None:
    print()
    print("EMON SIGNALS")
    print("-" * 40)
    ipc_status = "healthy" if ipc >= 1.5 else "LOW — possible memory stall or misprediction"
    print(f"  IPC              : {ipc:.2f}  ({ipc_status})")
    if llc_miss_rate is not None:
        llc_status = "healthy" if llc_miss_rate < 5 else "ELEVATED — DRAM pressure likely"
        print(f"  LLC Miss Rate    : {llc_miss_rate:.1f}%  ({llc_status})")
    if branch_miss_rate is not None:
        print(f"  Branch Miss Rate : {branch_miss_rate:.2f}%")
    if amx_bf16:
        print(f"  AMX BF16 ops     : {amx_bf16:,.0f}")
    if amx_int8:
        print(f"  AMX INT8 ops     : {amx_int8:,.0f}")

if bottlenecks:
    print()
    print("BOTTLENECKS DETECTED")
    print("-" * 40)
    for i, b in enumerate(bottlenecks, 1):
        print(f"  [{b['id']}] {b['domain']}: {b['observed']} (expected {b['expected']}, {b['delta']})")
        print(f"           EMON: {b['emon_signal']}")
        print(f"           Config: {b['sysconfig_note']}")
else:
    print()
    print("BOTTLENECKS DETECTED")
    print("-" * 40)
    print("  None — all measured KPIs within threshold.")

if recommendations:
    print()
    print("TUNING RECOMMENDATIONS & PREDICTIONS")
    print("-" * 40)
    for i, r in enumerate(recommendations, 1):
        print(f"  [T{i}] Bottleneck : {r['bottleneck']}")
        print(f"       Action     : {r['action']}")
        print(f"       Metric     : {r['metric']}")
        print(f"       Current    : {r['current']}")
        print(f"       Predicted  : {r['pred_range']} improvement")
        print(f"       Confidence : {r['confidence']}")
        print(f"       Basis      : {r['basis']}")
        print()

# Overall verdict
all_pass = all(
    check_pass(k, kpis[k], THRESHOLDS[k][0], THRESHOLDS[k][1]) == 'PASS'
    for k in kpis if k in THRESHOLDS
)
verdict = 'PASS' if all_pass and kpis else ('FAIL' if kpis else 'INCOMPLETE')
print(f"OVERALL VERDICT: {verdict}")
print(f"{'='*60}\n")
```
