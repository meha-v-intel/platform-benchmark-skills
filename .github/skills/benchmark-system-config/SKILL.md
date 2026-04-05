---
name: benchmark-system-config
description: "Collect full system configuration from remote benchmark machine. Use when: discovering platform details, collecting system info before benchmarks, identifying CPU model, memory config, BIOS settings, kernel parameters, checking hardware topology, understanding the system under test, platform inventory, sysconfig collection."
allowed-tools: Bash
---

# System Configuration Collection

Collects comprehensive hardware and software configuration from the remote machine.
Output is saved to `./results/${SESSION_ID}/sysconfig.json` and cross-referenced by
`benchmark-analyze` for bottleneck detection and tuning predictions.

## Variables Required (set by AGENTS.md Phase 4)

| Variable | Description | Example |
|---|---|---|
| `$LAB_HOST` | SSH target (from benchmark-auth) | `lab-target` |
| `$SESSION_ID` | Current session identifier | `20260405T120000-a3f9c1` |
| `$OUTPUT_DIR` | Remote results directory | `/tmp/benchmarks/2026-04-05T12-00-00` |

## Variables Exported by This Skill

| Variable | Description |
|---|---|
| `$PLATFORM_ID` | 12-char SHA256 hash of CPU model + logical CPU count |
| `$SYSCONFIG_JSON` | Local path to `./results/${SESSION_ID}/sysconfig.json` |

---

## Step 1 — Collect CPU Configuration

```bash
ssh $LAB_HOST "
echo '=== CPU_MODEL ==='
grep -m1 'model name' /proc/cpuinfo

echo '=== MICROCODE ==='
grep -m1 'microcode' /proc/cpuinfo

echo '=== TOPOLOGY ==='
lscpu

echo '=== NUMA ==='
numactl --hardware

echo '=== CACHE ==='
lscpu | grep -i cache

echo '=== FREQUENCY ==='
cpupower frequency-info 2>/dev/null || cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq

echo '=== TURBO ==='
cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null
cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null

echo '=== GOVERNOR ==='
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null

echo '=== CSTATES ==='
paste \
  <(cat /sys/devices/system/cpu/cpu0/cpuidle/state*/name 2>/dev/null) \
  <(cat /sys/devices/system/cpu/cpu0/cpuidle/state*/latency 2>/dev/null)

echo '=== CPUIDLE_DRIVER ==='
cat /sys/devices/system/cpu/cpuidle/current_driver 2>/dev/null

echo '=== HT ==='
lscpu | grep 'Thread(s) per core'

echo '=== CPU_FLAGS ==='
grep -m1 '^flags' /proc/cpuinfo | tr ' ' '\n' | grep -E '^(amx|avx512|ht|smx|vmx|rdma)' | sort -u
" > /tmp/sysconfig_cpu.txt
```

## Step 2 — Collect Memory Configuration

```bash
ssh $LAB_HOST "
echo '=== DIMMS ==='
dmidecode -t memory 2>/dev/null | grep -E '^\s+(Size|Speed|Type:|Manufacturer|Part Number|Bank Locator|Locator):' | grep -v 'No Module'

echo '=== MEM_TOTAL ==='
free -h

echo '=== NUMA_MEMORY ==='
numactl --hardware | grep -E 'node [0-9]+ size'

echo '=== HUGEPAGES ==='
grep -i huge /proc/meminfo

echo '=== THP ==='
cat /sys/kernel/mm/transparent_hugepage/enabled

echo '=== NUMA_BALANCING ==='
cat /proc/sys/kernel/numa_balancing
" > /tmp/sysconfig_mem.txt
```

## Step 3 — Collect BIOS / Firmware Information

```bash
ssh $LAB_HOST "
echo '=== BIOS ==='
dmidecode -t bios 2>/dev/null | grep -E '(Vendor|Version|Release Date):'

echo '=== SYSTEM ==='
dmidecode -t system 2>/dev/null | grep -E '(Manufacturer|Product Name|Version):'

echo '=== CHASSIS ==='
dmidecode -t chassis 2>/dev/null | grep -E '(Manufacturer|Type):'
" > /tmp/sysconfig_bios.txt
```

## Step 4 — Collect OS / Kernel Configuration

```bash
ssh $LAB_HOST "
echo '=== OS ==='
cat /etc/os-release | grep -E '^(NAME|VERSION|ID)='

echo '=== KERNEL ==='
uname -r

echo '=== KERNEL_CMDLINE ==='
cat /proc/cmdline

echo '=== SELINUX ==='
getenforce 2>/dev/null || echo 'not present'

echo '=== IRQBALANCE ==='
systemctl is-active irqbalance 2>/dev/null

echo '=== SWAP ==='
swapon --show 2>/dev/null || echo 'none'

echo '=== DISK_TMP ==='
df -h /tmp | tail -1

echo '=== NPROC ==='
nproc --all
" > /tmp/sysconfig_os.txt
```

## Step 5 — Collect Power and Thermal State

```bash
ssh $LAB_HOST "
echo '=== POWER_PROFILE ==='
tuned-adm active 2>/dev/null || echo 'tuned not active'

echo '=== PSTATE ==='
cat /sys/devices/system/cpu/intel_pstate/status 2>/dev/null || echo 'intel_pstate not active'

echo '=== ENERGY_PERF_BIAS ==='
x86_energy_perf_policy 2>/dev/null | head -3 || echo 'not available'

echo '=== PKG_POWER_LIMIT_UW ==='
cat /sys/class/powercap/intel-rapl/intel-rapl:0/constraint_0_power_limit_uw 2>/dev/null || echo 'not available'

echo '=== THERMAL ==='
sensors 2>/dev/null | grep -E '(Package|Core 0)' | head -5 || echo 'sensors not installed'
" > /tmp/sysconfig_power.txt
```

## Step 6 — Copy Raw Configs from Remote

```bash
scp ${LAB_HOST}:/tmp/sysconfig_*.txt ./results/${SESSION_ID}/
```

## Step 7 — Serialize to JSON and Export

```python
import json, re, hashlib, datetime, os, subprocess

SESSION_ID = os.environ.get('SESSION_ID', 'unknown')
OUT_DIR = f'./results/{SESSION_ID}'
os.makedirs(OUT_DIR, exist_ok=True)

def read(fname):
    try:
        return open(f'{OUT_DIR}/{fname}').read()
    except FileNotFoundError:
        return ''

def section(text, key):
    m = re.search(rf'=== {key} ===(.*?)(?====|\Z)', text, re.DOTALL)
    return m.group(1).strip() if m else ''

cpu_raw  = read('sysconfig_cpu.txt')
mem_raw  = read('sysconfig_mem.txt')
bios_raw = read('sysconfig_bios.txt')
os_raw   = read('sysconfig_os.txt')
pwr_raw  = read('sysconfig_power.txt')

# CPU
model_m   = re.search(r'model name\s*:\s*(.+)', section(cpu_raw, 'CPU_MODEL'))
ucode_m   = re.search(r'microcode\s*:\s*(.+)', section(cpu_raw, 'MICROCODE'))
lscpu     = section(cpu_raw, 'TOPOLOGY')
sockets_m = re.search(r'Socket\(s\)\s*:\s*(\d+)', lscpu)
cores_m   = re.search(r'Core\(s\) per socket\s*:\s*(\d+)', lscpu)
threads_m = re.search(r'Thread\(s\) per core\s*:\s*(\d+)', lscpu)
numa_m    = re.search(r'NUMA node\(s\)\s*:\s*(\d+)', lscpu)
nproc_m   = re.search(r'(\d+)', section(os_raw, 'NPROC'))

# Memory
thp       = section(mem_raw, 'THP')
numa_bal  = section(mem_raw, 'NUMA_BALANCING')
hugepages = section(mem_raw, 'HUGEPAGES')

config = {
    'collected_at': datetime.datetime.utcnow().isoformat() + 'Z',
    'cpu': {
        'model':             model_m.group(1).strip()   if model_m   else 'unknown',
        'microcode':         ucode_m.group(1).strip()   if ucode_m   else 'unknown',
        'sockets':           int(sockets_m.group(1))    if sockets_m else None,
        'cores_per_socket':  int(cores_m.group(1))      if cores_m   else None,
        'threads_per_core':  int(threads_m.group(1))    if threads_m else None,
        'logical_cpus':      int(nproc_m.group(1))      if nproc_m   else None,
        'numa_nodes':        int(numa_m.group(1))        if numa_m    else None,
        'governor':          section(cpu_raw, 'GOVERNOR'),
        'turbo_disabled':    section(cpu_raw, 'TURBO').strip() == '1',
        'cpuidle_driver':    section(cpu_raw, 'CPUIDLE_DRIVER'),
        'c_states':          [l.strip() for l in section(cpu_raw, 'CSTATES').splitlines() if l.strip()],
        'ht_enabled':        section(cpu_raw, 'HT').strip().endswith('2'),
        'cpu_flags':         [f.strip() for f in section(cpu_raw, 'CPU_FLAGS').splitlines() if f.strip()],
    },
    'memory': {
        'dimm_info':              section(mem_raw,  'DIMMS'),
        'transparent_hugepages':  thp.split()[0] if thp else 'unknown',
        'numa_balancing_enabled': numa_bal.strip() == '1',
        'hugepages_raw':          hugepages,
    },
    'bios': {
        'info': section(bios_raw, 'BIOS'),
    },
    'os': {
        'release':            section(os_raw, 'OS'),
        'kernel':             section(os_raw, 'KERNEL'),
        'cmdline':            section(os_raw, 'KERNEL_CMDLINE'),
        'irqbalance_active':  'active' in section(os_raw, 'IRQBALANCE'),
        'selinux':            section(os_raw, 'SELINUX'),
    },
    'power': {
        'profile':          section(pwr_raw, 'POWER_PROFILE'),
        'pstate_status':    section(pwr_raw, 'PSTATE'),
        'pkg_power_limit':  section(pwr_raw, 'PKG_POWER_LIMIT_UW'),
    },
}

platform_str = f"{config['cpu']['model']}-{config['cpu']['logical_cpus']}c"
config['platform_id'] = hashlib.sha256(platform_str.encode()).hexdigest()[:12]

out_path = f'{OUT_DIR}/sysconfig.json'
with open(out_path, 'w') as f:
    json.dump(config, f, indent=2)

print(f"PLATFORM_ID={config['platform_id']}")
print(f"SYSCONFIG_JSON={out_path}")
```

## Report Format

```
SYSTEM CONFIGURATION
====================
CPU        : <model>
             <N>S × <N>C × <N>T = <N> logical CPUs, <N> NUMA node(s)
Microcode  : <version>
Governor   : <performance|powersave|...>
Turbo      : <enabled|disabled>
C-States   : <list with exit latencies>
cpuidle    : <driver>
HT         : <enabled|disabled>
AMX        : <present|absent>  (from CPU flags)

Memory     : <total>
THP        : <always|madvise|never>
HugePages  : <count × size>
NUMA Bal.  : <enabled|disabled>

BIOS       : <vendor + version>
OS         : <distro + version>
Kernel     : <uname -r>
IRQbalance : <active|inactive>
Power Prof : <tuned profile>

Platform ID: <12-char hash>
Saved to   : ./results/<session-id>/sysconfig.json
```
