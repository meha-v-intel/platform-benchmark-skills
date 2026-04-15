---
name: rack-slurm
description: "Install, configure, and operate Slurm Workload Manager on an Intel DMR single-node
  or rack system. Use when: setting up Slurm from source, configuring job scheduling on a single
  node, creating partitions for workload isolation, submitting batch jobs, debugging slurmd
  startup, troubleshooting controller connectivity, running multi-partition job scheduling tests,
  setting up job arrays, job dependencies, or testing backfill scheduling on a solo DMR system."
argument-hint: "[install|configure|start|test|all]"
allowed-tools: Bash
---

# Slurm Workload Manager — DMR Rack / Single-Node Setup

Slurm is an open-source cluster management and job scheduling system. This skill covers
full installation from GitHub source, single-node multi-partition configuration, and
hands-on job scheduling validation on Intel DMR hardware.

**Scope:** Install from source, MUNGE auth, 4-partition single-node config, job submission
testing (sbatch, srun, arrays, dependencies, scancel).

---

## Platform Notes (dmr-bkc, this system)

```
System    : 1S×32C×1T (container-visible), ~31 GiB RAM
            Physical board: 224-CPU Diamond Rapids, but container exposes 32 CPUs
OS        : CentOS Stream 10 (Coughlan)
Kernel    : 6.18.0-dmr.bkc.6.18.3.8.3.x86_64
Slurm ver : 26.05.0-0rc1 (built from github.com/SchedMD/slurm master)
Install   : /usr/local/slurm/{bin,sbin,lib}
Config    : /etc/slurm/{slurm.conf,cgroup.conf}
Auth      : MUNGE 0.5.15 (munge-0.5.15-11.el10)
LAN IP    : 10.3.173.163  ← use this, not the routed external IP
```

---

## Variables

| Variable | Value on dmr-bkc | Description |
|---|---|---|
| `$SLURM_PREFIX` | `/usr/local/slurm` | Installation prefix |
| `$SLURM_CONF` | `/etc/slurm` | Config directory |
| `$SLURM_STATE` | `/var/lib/slurm` | State save location |
| `$SLURM_SPOOL` | `/tmp/slurmd` | slurmd spool dir |
| `$NODE_IP` | `10.3.173.163` | LAN IP (must match `NodeAddr`) |
| `$NODE_CPUS` | `32` | Actual CPUs visible to slurmd |
| `$NODE_MEM` | `31000` | Actual RAM in MB (leave ~600 MB headroom) |

```bash
SLURM_PREFIX=/usr/local/slurm
SLURM_CONF=/etc/slurm
SLURM_STATE=/var/lib/slurm
NODE_IP=$(ip addr show | awk '/inet / && !/127\.0\.0\.1/{print $2}' | cut -d/ -f1 | head -1)
NODE_CPUS=$(nproc)
NODE_MEM=$(free -m | awk '/Mem:/{print $2 - 600}')
NODE_NAME=$(hostname -s)
```

---

## Prerequisites

```bash
# Verify MUNGE installed
rpm -q munge munge-libs munge-devel || dnf install -y munge munge-libs munge-devel

# Verify build deps (all present on dmr-bkc)
rpm -q gcc make autoconf automake libtool pam-devel readline-devel hwloc-devel \
    mariadb-devel || dnf install -y gcc make autoconf automake libtool \
    pam-devel readline-devel hwloc-devel mariadb-devel

# Verify Slurm binaries
$SLURM_PREFIX/bin/sinfo --version 2>/dev/null || echo "Slurm not installed — run install"

# Verify daemons running
ps aux | grep -E "slurm[cd]|munged" | grep -v grep
```

---

## Group A — Installation from Source

### A-1: Clone and Build

```bash
cd /root
git clone https://github.com/SchedMD/slurm.git
cd slurm

# Configure: sysconfdir must match where slurm.conf will live
./configure --prefix=$SLURM_PREFIX --sysconfdir=$SLURM_CONF \
            --with-munge=/usr 2>&1 | tail -5

# Build (4 parallel jobs, takes ~2 min on dmr-bkc)
make -j4 2>&1 | tail -10

# Install
make install 2>&1 | tail -5

# Register libraries
ldconfig -n $SLURM_PREFIX/lib
```

### A-2: Create slurm User and Directories

```bash
useradd -r -U -d /var/lib/slurm -s /bin/false slurm 2>/dev/null || true
id slurm   # verify: uid=985(slurm) gid=983(slurm)

mkdir -p $SLURM_STATE $SLURM_SPOOL /var/log/slurm
chown -R slurm:slurm $SLURM_STATE /var/log/slurm $SLURM_CONF
chmod 755 $SLURM_STATE /var/log/slurm
```

### A-3: Set Up MUNGE

```bash
# Fix ownership before starting (munge UID is ~986)
chown -R munge:munge /var/log/munge /var/lib/munge /etc/munge
chmod 755 /var/log/munge /var/lib/munge
chmod 600 /etc/munge/munge.key

# Generate key if not present
[ -f /etc/munge/munge.key ] || /usr/sbin/mungekey

# Start and enable
systemctl start munge && systemctl enable munge
systemctl status munge | grep Active
```

### A-4: Add Slurm to PATH

```bash
echo 'export PATH="/usr/local/slurm/bin:/usr/local/slurm/sbin:$PATH"' >> ~/.bashrc
export PATH="/usr/local/slurm/bin:/usr/local/slurm/sbin:$PATH"
```

---

## Group B — Configuration

### B-1: cgroup.conf

cgroup/v2 may not be mounted on DMR BKC kernels. Use v1 with constraints disabled:

```bash
cat > $SLURM_CONF/cgroup.conf << 'EOF'
CgroupPlugin=cgroup/v1
ConstrainCores=no
ConstrainDevices=no
ConstrainRAMSpace=no
ConstrainSwapSpace=no
EOF
```

> **Note:** Even with all constraints disabled, `cgroup/v1` needs at least `cpuset` and
> `freezer` namespaces mounted. If they're absent, switch `ProctrackType` to
> `proctrack/linuxproc` in `slurm.conf` — this won't track processes via cgroups
> at all, but is sufficient for single-node testing.

### B-2: slurm.conf — Single-Node, Multi-Partition

This configuration exposes one physical node as 4 scheduling partitions:

```bash
NODE_IP=$(ip addr show | awk '/inet / && !/127\.0\.0\.1/{print $2}' | cut -d/ -f1 | head -1)
NODE_NAME=$(hostname -s)
NODE_CPUS=$(nproc)
NODE_MEM=$(( $(free -m | awk '/Mem:/{print $2}') - 600 ))

cat > $SLURM_CONF/slurm.conf << EOF
# Slurm — Single-Node DMR Configuration
# Generated $(date)

ClusterName=dmr-testbed
SlurmctldHost=${NODE_NAME}(${NODE_IP})
SlurmUser=slurm
SlurmctldPort=6817
SlurmdPort=6818
AuthType=auth/munge
StateSaveLocation=${SLURM_STATE}
SlurmdSpoolDir=${SLURM_SPOOL}

SchedulerType=sched/backfill
SelectType=select/linear
TaskPlugin=task/none
JobAcctGatherType=jobacct_gather/none
ProctrackType=proctrack/linuxproc

# Node: use LAN IP directly — avoids external DNS resolution failures
NodeName=${NODE_NAME} NodeAddr=${NODE_IP} CPUs=${NODE_CPUS} \\
    Sockets=1 CoresPerSocket=${NODE_CPUS} ThreadsPerCore=1 \\
    RealMemory=${NODE_MEM}

# Partitions — all share the same physical node
# Higher Priority = runs before lower-priority partitions when resources free
PartitionName=batch Nodes=${NODE_NAME} MaxTime=UNLIMITED  Priority=1 Default=YES
PartitionName=debug Nodes=${NODE_NAME} MaxTime=00:30:00   Priority=2
PartitionName=fast  Nodes=${NODE_NAME} MaxTime=00:10:00   Priority=3
PartitionName=long  Nodes=${NODE_NAME} MaxTime=7-00:00:00 Priority=0

PriorityType=priority/basic
EOF
```

**Why 4 partitions on 1 node?** With `SchedulerType=sched/backfill`, different
partitions have different priorities and time limits. This lets you observe:
- Job queuing and preemption when resources are exhausted
- How `debug` (Priority=2) jumps ahead of `batch` (Priority=1) when the node frees
- `long` (Priority=0) only runs when nothing else is pending
- Backfill filling gaps with shorter jobs

### B-3: Systemd Service Files

```bash
cat > /etc/systemd/system/slurmctld.service << 'EOF'
[Unit]
Description=Slurm controller daemon
After=network.target munge.service
Wants=munge.service
ConditionPathExists=/etc/slurm/slurm.conf

[Service]
Type=forking
ExecStart=/usr/local/slurm/sbin/slurmctld
ExecReload=/bin/kill -HUP $MAINPID
LimitNOFILE=infinity
LimitMEMLOCK=infinity
Restart=on-failure
RestartSec=30s

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/slurmd.service << 'EOF'
[Unit]
Description=Slurm node daemon
After=network.target munge.service
Wants=munge.service
ConditionPathExists=/etc/slurm/slurm.conf

[Service]
Type=forking
ExecStart=/usr/local/slurm/sbin/slurmd
ExecReload=/bin/kill -HUP $MAINPID
LimitNOFILE=infinity
LimitMEMLOCK=infinity
LimitSTACK=infinity
Restart=on-failure
RestartSec=30s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable slurmctld slurmd
```

---

## Group C — Starting and Verifying

### C-1: Start Daemons

```bash
# Option A: via helper script (see scripts/slurm-start.sh)
/usr/local/slurm/bin/slurm-start

# Option B: manually
rm -f $SLURM_STATE/*           # clear stale state if ClusterName changed
/usr/local/slurm/sbin/slurmctld
sleep 1
/usr/local/slurm/sbin/slurmd
sleep 2
```

### C-2: Verify

```bash
# All 4 partitions should show idle
sinfo --long

# Node detail — verify CPUTot, RealMemory match slurm.conf
scontrol show node $(hostname -s)

# Check both daemons
ps aux | grep -E "slurm[cd]" | grep -v grep
```

**Expected sinfo output:**
```
PARTITION AVAIL  TIMELIMIT   JOB_SIZE  NODES STATE NODELIST
batch*       up   infinite 1-infinite      1  idle dmr-bkc
debug        up      30:00 1-infinite      1  idle dmr-bkc
fast         up      10:00 1-infinite      1  idle dmr-bkc
long         up 7-00:00:00 1-infinite      1  idle dmr-bkc
```

---

## Group D — Job Scheduling Tests

### D-1: Basic sbatch

```bash
sbatch --partition=debug --ntasks=4 --cpus-per-task=2 --time=00:01:00 \
  --output=/tmp/slurm_%j.out \
  --wrap='echo "Job=$SLURM_JOB_ID Part=$SLURM_JOB_PARTITION Node=$SLURM_JOB_NODELIST"; srun -n4 bash -c "echo ProcID=\$SLURM_PROCID PID=\$\$"'

# Check output
sleep 5 && cat /tmp/slurm_*.out
```

### D-2: Multi-Partition Queue

```bash
# Submit to all partitions simultaneously
for part in batch debug fast long; do
  sbatch -p $part --job-name=test_${part} --ntasks=1 --time=00:01:00 \
    --output=/tmp/slurm_%j_${part}.out \
    --wrap="echo '[job \$SLURM_JOB_ID] partition=\$SLURM_JOB_PARTITION'; sleep 5"
done

# Watch queue (jobs queue behind each other since node is shared)
squeue -o "%.7i %.10P %.12j %.2t %.10M %.4C %R"
```

### D-3: Job Array

```bash
sbatch --partition=batch --array=1-5 --job-name=array_test \
  --output=/tmp/slurm_array_%A_%a.out --time=00:01:00 \
  --wrap='echo "Array=$SLURM_ARRAY_JOB_ID Task=$SLURM_ARRAY_TASK_ID"'

sleep 8 && cat /tmp/slurm_array_*.out | sort -t= -k2 -n
```

### D-4: Job Dependency Chain

```bash
# Parent must succeed before child runs
J1=$(sbatch -p fast --time=00:01:00 --output=/tmp/parent_%j.out \
  --wrap='echo "Parent $SLURM_JOB_ID done at $(date)"' | awk '{print $4}')

J2=$(sbatch -p fast --time=00:01:00 --dependency=afterok:$J1 \
  --output=/tmp/child_%j.out \
  --wrap='echo "Child $SLURM_JOB_ID ran after parent at $(date)"' | awk '{print $4}')

echo "Parent=$J1  Child=$J2 (afterok:$J1)"
squeue --priority -o "%.7i %.10P %.12j %.2t %R"

sleep 15 && cat /tmp/parent_*.out /tmp/child_*.out
```

### D-5: Cancel Test

```bash
JOBID=$(sbatch -p long --time=1:00:00 --wrap='sleep 600' | awk '{print $4}')
squeue --jobs=$JOBID -o "%.7i %.10P %.12j %.2t %R"
scancel $JOBID
sleep 1 && squeue   # should be empty
```

---

## Key Slurm Environment Variables (set inside jobs)

| Variable | Meaning |
|---|---|
| `$SLURM_JOB_ID` | Unique job ID |
| `$SLURM_JOB_NAME` | Job name |
| `$SLURM_JOB_PARTITION` | Partition the job is running in |
| `$SLURM_JOB_NODELIST` | Allocated node(s) |
| `$SLURM_JOB_NUM_NODES` | Number of allocated nodes |
| `$SLURM_CPUS_ON_NODE` | CPUs available on this node |
| `$SLURM_CPUS_PER_TASK` | CPUs per task (from `--cpus-per-task`) |
| `$SLURM_NTASKS` | Total task count |
| `$SLURM_PROCID` | MPI rank / task ID (0-indexed within srun) |
| `$SLURM_ARRAY_JOB_ID` | Parent job ID for arrays |
| `$SLURM_ARRAY_TASK_ID` | This task's index within the array |
| `$SLURM_STEP_ID` | Job step ID (increments per `srun`) |
| `$SLURM_CLUSTER_NAME` | Cluster name from slurm.conf |

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `sinfo: Unable to contact slurm controller` | slurmctld listening on wrong IP (external DNS vs LAN) | Add `SlurmctldHost=hostname(LAN_IP)` and `NodeAddr=LAN_IP` |
| `slurmd: Unable to determine NodeName` | `NodeName` in conf doesn't match `hostname -s` | Use `NodeName=$(hostname -s)` in conf or pass `--nodename` |
| `slurmd: cannot create cgroup context for cgroup/v2` | cgroup/v2 plugin compiled in but kernel doesn't expose v2 hierarchy | Set `CgroupPlugin=cgroup/v1` in cgroup.conf |
| `slurmd: cgroup namespace 'cpuset' not mounted` | cgroup/v1 nsps not mounted in container/BKC kernel | Switch `ProctrackType=proctrack/linuxproc` in slurm.conf |
| `slurmctld: CLUSTER NAME MISMATCH` | State files from a different `ClusterName` exist | `rm -f /var/lib/slurm/*` then restart |
| `slurmctld: Duplicate SlurmctldHost records` | Both `ControlMachine` (old) and `SlurmctldHost` (new) set | Remove `ControlMachine`; use only `SlurmctldHost` |
| Node shows `inval` in sinfo | CPUs/memory in conf don't match what slurmd auto-detects | Set `CPUs=$(nproc)`, `RealMemory=$(free -m \| awk '/Mem:/{print $2-600}')` |
| `Parsing error at unrecognized key: LogLevel` | `LogLevel` is a per-daemon flag, not a slurm.conf key | Remove from conf; pass `-v` to daemon instead |
| `Parsing error at unrecognized key: Timeout` | Same — removed in newer Slurm versions | Remove `SlurmctldTimeout`/`SlurmdTimeout` from conf |
| Jobs stuck `PD (Resources)` | Node is fully allocated; backfill waiting for slot | Normal — jobs run when node frees; use `squeue --start` to see ETA |
| Jobs stuck `PD (Nodes required... reserved for...)` | Lower-priority partition waiting for higher-priority drain | Normal — `long` (Priority=0) waits for `debug`/`batch` to drain |
| `munge: Error: Logfile is insecure` | Log file owned by root, not munge user | `chown -R munge:munge /var/log/munge /var/lib/munge /etc/munge` |

---

## Quick Reference Commands

```bash
# Cluster status
sinfo                          # brief partition/node view
sinfo -l                       # long format (job size, state details)
sinfo -N -o "%.15N %.6t %.4c %.6m"  # node-oriented, CPUs+mem

# Job queue
squeue                         # all jobs
squeue --me                    # my jobs only
squeue --partition=debug       # filter by partition
squeue --priority              # sorted by priority
squeue --start                 # show expected start times
squeue -o "%.7i %.10P %.12j %.2t %.10M %.4C %R"  # custom format

# Job control
sbatch myjob.sh                # submit batch script
sbatch --wrap='cmd'            # inline command (no script needed)
scancel <jobid>                # cancel job
scancel --partition=long       # cancel all jobs in a partition
scancel --state=PD             # cancel all pending

# Admin inspection
scontrol show node dmr-bkc     # full node state
scontrol show partition        # full partition config
scontrol show job <jobid>      # full job state
scontrol reconfigure           # reload slurm.conf without restart

# Daemon management (after install)
slurm-start                    # start all daemons (helper script)
killall slurmctld slurmd       # stop all (or use systemctl)
systemctl restart slurmctld    # restart controller only
scontrol show config | grep -E "Scheduler|Select|Proctrack"  # confirm active plugins
```

---

## Scripts Reference

| Script | Purpose |
|---|---|
| [`scripts/slurm-install.sh`](scripts/slurm-install.sh) | Full build + install from source on CentOS/RHEL |
| [`scripts/slurm-start.sh`](scripts/slurm-start.sh) | Start munge + slurmctld + slurmd; print sinfo |
| [`scripts/slurm-test-jobs.sh`](scripts/slurm-test-jobs.sh) | Submit test jobs across all partitions and verify |
| [`scripts/gen-slurm-conf.sh`](scripts/gen-slurm-conf.sh) | Auto-detect system params and write slurm.conf |

---

## Cleanup

```bash
# Stop daemons
killall slurmctld slurmd 2>/dev/null || true

# Remove state (required before ClusterName change)
rm -f /var/lib/slurm/*

# Clean job output files
rm -f /tmp/slurm_*.out /tmp/slurm_*.err
rm -f /tmp/slurm_array_*.out /tmp/parent_*.out /tmp/child_*.out
```
