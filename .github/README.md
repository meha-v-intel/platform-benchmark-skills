# Platform Benchmark Skills — Rack / Single-Node DMR

**Branch:** `rack-skills`
**Scope:** GitHub Copilot CLI skills for Intel DMR rack and single-node system setup, benchmarking, and workload management
**Audience:** Engineers bringing up, validating, and running workloads on Diamond Rapids (DMR) rack systems

---

## Setup Guide

> **New to VS Code or GitHub Copilot?** This section walks you through everything you need — from installing VS Code to asking Copilot to set up Slurm or run benchmarks on your DMR system.

### Step 1 — Decide where to run your benchmarks

The skills in this repo run **directly on the target system** (your DMR rack or lab server). Before cloning anything, decide which machine will actually run them:

| Your situation | What to do |
|---|---|
| **Working directly on the DMR system** | Open VS Code on that machine, clone there, done |
| **Working from a laptop / workstation** | Use VS Code Remote SSH to connect to the DMR system first, then clone and open the repo there |

> **Why does this matter?**  
> GitHub Copilot runs commands inside VS Code's integrated terminal — on whichever machine VS Code is connected to. If VS Code is open on your laptop but the DMR system is remote, Copilot would need a separate SSH login for every command. The correct setup is to open VS Code **directly on the DMR system** so Copilot's terminal is already there.

---

### Step 2 — Install VS Code and GitHub Copilot

If you haven't set these up yet:

1. Download and install [Visual Studio Code](https://code.visualstudio.com/)
2. Open VS Code, go to the **Extensions** sidebar (`Ctrl+Shift+X`), and install:
   - **GitHub Copilot**
   - **GitHub Copilot Chat**
3. Sign in with your GitHub account when prompted

---

### Step 3 — (Remote access only) Connect VS Code to the DMR system via SSH

If your DMR target is a remote rack server:

1. In VS Code's Extensions sidebar, install **Remote - SSH**
2. Open the Command Palette (`Ctrl+Shift+P`) and run **Remote-SSH: Connect to Host...**
3. Enter your server's address (e.g. `user@dmr-system.intel.com`)
4. VS Code will reconnect — the status bar at the bottom-left will show the remote host name

→ Full guide: [VS Code Remote Development using SSH](https://code.visualstudio.com/docs/remote/ssh)

> After connecting remotely, all terminals, file edits, and Copilot commands run on the DMR system — not your laptop. This is exactly what you want.

---

### Step 4 — (Intel network users) Set proxies before installing anything

If you are on Intel's corporate network, package downloads (`dnf`, `pip`, `cargo`, `git clone`, etc.) may be blocked without proxy settings. Run the following **before cloning the repo or installing any tools**:

```bash
export ftp_proxy=http://proxy-dmz.intel.com:911
export http_proxy=http://proxy-us.intel.com:911
export https_proxy=http://proxy-us.intel.com:912
export no_proxy=134.134.0.0/16,192.168.0.0/16,172.16.0.0/12,10.0.0.0/8,localhost,.local,10.54.27.105,10.96.0.0/12,10.54.27.55,172.25.226.133,intel.com,.intel.com,10.244.0.0/16,10.96.0.1,127.0.0.0/8,10.54.27.19
export socks_proxy=http://proxy-dmz.intel.com:1080
```

To make these permanent across sessions, add them to `~/.bashrc` or `/etc/environment`.

---

### Step 5 — Clone this repo and open it as your workspace

Once VS Code is connected to the right machine, open a terminal in VS Code (`Ctrl+\``) and run:

```bash
git clone https://github.com/meha-v-intel/platform-benchmark-skills.git
cd platform-benchmark-skills
git checkout rack-skills
```

Then in VS Code go to **File → Open Folder** and select the `platform-benchmark-skills` folder.

This opens the repo as your **[VS Code workspace](https://code.visualstudio.com/docs/editing/workspaces/workspaces)**. Copilot automatically discovers all the skill files inside `.github/skills/` and knows how to set up Slurm, run benchmarks, and collect EMON traces on your system.

---

### Step 6 — Ask Copilot to get to work

Open **GitHub Copilot Chat** (`Ctrl+Shift+I`) and type in plain English — no commands needed:

```
install and configure Slurm on this system
run the full job scheduling test battery
run all platform benchmarks and give me a summary
collect EMON traces while running the memory bandwidth benchmark
```

Copilot uses the **[Copilot CLI agent](https://code.visualstudio.com/docs/copilot/agents/copilot-cli)** within your workspace to discover your system's configuration and execute the correct commands automatically.

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
