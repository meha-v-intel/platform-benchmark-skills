# Platform Benchmark Skills — Rack / Single-Node DMR

**Branch:** `rack-skills`
**Scope:** GitHub Copilot CLI skills for Intel DMR rack and single-node system setup, benchmarking, and workload management
**Audience:** Engineers bringing up, validating, and running workloads on Diamond Rapids (DMR) rack systems

---

## Skills in This Branch

| Skill | Invoke | Purpose |
|---|---|---|
| [`rack-slurm`](skills/rack-slurm/) | `/rack-slurm` | Install, configure, and operate Slurm on a DMR system |
| [`run-benchmark`](skills/run-benchmark/) | `/run-benchmark [name\|all]` | Run CPU, memory, AMX, wakeup, and core-to-core benchmarks |
| [`emon-workload-sweep`](skills/emon-workload-sweep/) | `/emon-workload-sweep` | Collect EMON traces while sweeping workload configs |
| [`create-skill`](skills/create-skill/) | `/create-skill` | Write new SKILL.md files (meta skill) |

---

## rack-slurm

**Full skill:** [skills/rack-slurm/SKILL.md](skills/rack-slurm/SKILL.md)

Slurm Workload Manager (SchedMD) installed from GitHub source and configured for single-node DMR operation. The skill covers the complete workflow from bare system to running job queues.

### What it sets up

- **MUNGE 0.5.15** — authentication daemon (RHEL/CentOS package)
- **Slurm 26.05.0** — built from source, installed to `/usr/local/slurm/`
- **4-partition config** — batch / debug / fast / long all share the physical node, enabling backfill scheduling tests without a real cluster
- **Backfill scheduler** — jobs fill idle CPU gaps across partitions by priority

### Single-node partitioning model

All 4 partitions point at `dmr-bkc` (the single node). This is intentional:

```
PartitionName=batch  MaxTime=UNLIMITED  Priority=1  Default=YES
PartitionName=debug  MaxTime=00:30:00   Priority=2
PartitionName=fast   MaxTime=00:10:00   Priority=3
PartitionName=long   MaxTime=7-00:00:00 Priority=0
```

- `debug` (Priority 2) jumps ahead of `batch` (Priority 1) when the node frees up
- `long` (Priority 0) only runs when no higher-priority jobs are pending
- Jobs submitted to different partitions queue against each other — real scheduling behavior on one machine

### Bundled scripts

| Script | What it does |
|---|---|
| [`scripts/slurm-install.sh`](skills/rack-slurm/scripts/slurm-install.sh) | Full install from source: packages → build → user → conf → systemd → start |
| [`scripts/gen-slurm-conf.sh`](skills/rack-slurm/scripts/gen-slurm-conf.sh) | Auto-detects LAN IP / CPU count / RAM → writes `slurm.conf` + `cgroup.conf` |
| [`scripts/slurm-start.sh`](skills/rack-slurm/scripts/slurm-start.sh) | Starts munge + slurmctld + slurmd; prints `sinfo` on success |
| [`scripts/slurm-test-jobs.sh`](skills/rack-slurm/scripts/slurm-test-jobs.sh) | 7-test PASS/FAIL battery covering sbatch, srun, arrays, dependencies, scancel |

### Key troubleshooting notes

| Problem | Fix |
|---|---|
| `sinfo: Unable to contact slurm controller` | `SlurmctldHost=hostname(LAN_IP)` — hostname resolves to a firewalled external IP on DMR |
| `slurmd: cannot create cgroup context for cgroup/v2` | `CgroupPlugin=cgroup/v1` in `cgroup.conf` |
| `slurmd: cgroup namespace 'cpuset' not mounted` | `ProctrackType=proctrack/linuxproc` in `slurm.conf` |
| Node shows `inval` in `sinfo` | `CPUs=` in conf must exactly match `nproc` |
| `CLUSTER NAME MISMATCH fatal` | `rm -f /var/lib/slurm/*` then restart |

### Quick start (on a fresh DMR system)

```bash
# Install everything from source
bash skills/rack-slurm/scripts/slurm-install.sh

# Or if already installed, just start daemons
bash skills/rack-slurm/scripts/slurm-start.sh

# Run the full job test battery
bash skills/rack-slurm/scripts/slurm-test-jobs.sh
```

### Key Slurm commands

```bash
sinfo --long                          # partition + node status
squeue -o "%.7i %.10P %.12j %.2t %R" # queue with custom format
sbatch -p debug --wrap='echo hi'      # inline job submission
sbatch --array=1-5 myjob.sh           # job array
sbatch --dependency=afterok:N job.sh  # run after job N succeeds
scancel <jobid>                       # cancel job
scontrol show node dmr-bkc            # node CPU/mem/state detail
scontrol reconfigure                  # reload slurm.conf live
```

---

## Other Skills (brief)

### run-benchmark
Orchestrates DMR platform micro-benchmarks: CPU frequency sweep, turbo curve, core-to-core latency, memory latency/bandwidth (MLC), AMX BF16/INT8 throughput, and C-state wakeup latency. Invoke with `/run-benchmark all` or a specific benchmark name.

### emon-workload-sweep
Deploys EMON/SEP alongside a workload sweep, collects hardware performance counter traces per config point, and guides analysis through DMR-specific PMU metrics. Includes EMON reference files for Diamond Rapids (JSON metric definitions, user guide).

### create-skill
Meta skill for writing new SKILL.md files. Covers frontmatter schema, description patterns, argument-hint design, benchmark vs task vs reference skill types, and common pitfalls. Use this to add new skills to this repo.

---

## Platform

| Field | Value |
|---|---|
| System | Intel Diamond Rapids (DMR), 1S×32C×1T (container-visible), ~31 GiB RAM |
| OS | CentOS Stream 10 (Coughlan) |
| Kernel | `6.18.0-dmr.bkc.6.18.3.8.3.x86_64` |
| Slurm | 26.05.0-0rc1, built from [SchedMD/slurm](https://github.com/SchedMD/slurm) |
| Auth | MUNGE 0.5.15 |
