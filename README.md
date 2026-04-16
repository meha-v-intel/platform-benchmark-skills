# Intel Platform Benchmark Skills for GitHub Copilot

GitHub Copilot skills for running Intel Xeon platform micro-benchmarks. Clone this repo and ask Copilot to run any benchmark — it knows the exact commands, tools, pass/fail criteria, and GNR baseline values.

All skills are validated against Intel BKM (Best Known Method) documents.

---

## Setup Guide

> **New to VS Code or GitHub Copilot?** This section walks you through everything you need — from installing VS Code to asking Copilot to run your first benchmark.

### Step 1 — Decide where to run your benchmarks

The benchmarks in this repo run **directly on the target system**. Before you clone anything, decide which machine will actually run the benchmarks:

| Your situation | What to do |
|---|---|
| **Benchmarking your local machine** | Clone this repo to your local machine, then open it in VS Code there |
| **Benchmarking a remote server or lab system** | Use VS Code Remote SSH to connect to that server first, then clone and open the repo there |

> **Why does this matter?**  
> GitHub Copilot runs commands inside VS Code's integrated terminal — on whichever machine VS Code is connected to. If VS Code is open on your laptop but your benchmark target is a remote server, Copilot would need a separate SSH login for every single command it runs. The correct setup is to open VS Code **directly on the target machine** so Copilot's terminal is already there.

---

### Step 2 — Install VS Code and GitHub Copilot

If you haven't set these up yet:

1. Download and install [Visual Studio Code](https://code.visualstudio.com/)
2. Open VS Code, go to the **Extensions** sidebar (`Ctrl+Shift+X`), and install:
   - **GitHub Copilot** — AI completions + Copilot CLI support
   - **GitHub Copilot Chat** — provides the Chat view where Copilot CLI sessions run
3. Sign in with your GitHub account when prompted

---

### Step 3 — (Remote benchmarking only) Connect VS Code to your benchmark server via SSH

If your benchmark target is a remote server or lab system, do this before cloning the repo:

1. In VS Code's Extensions sidebar, install **Remote - SSH**
2. Open the Command Palette (`Ctrl+Shift+P`) and run **Remote-SSH: Connect to Host...**
3. Enter your server's address (e.g. `user@myserver.intel.com`)
4. VS Code will reconnect — the status bar at the bottom-left will show the remote host name

→ Full guide: [VS Code Remote Development using SSH](https://code.visualstudio.com/docs/remote/ssh)

> After connecting remotely, all terminals, file edits, and Copilot commands run on the remote server — not your laptop. This is exactly what you want for benchmarking.

---

### Step 4 — (Intel network users) Set proxies before installing anything

If you are on Intel's corporate network, package downloads (`dnf`, `pip`, `cargo`, `git clone`, etc.) may be blocked without these proxy settings. Run the following **before cloning the repo or installing any tools**:

```bash
export ftp_proxy=http://proxy-dmz.intel.com:911
export http_proxy=http://proxy-us.intel.com:911
export https_proxy=http://proxy-us.intel.com:912
export no_proxy=134.134.0.0/16,192.168.0.0/16,172.16.0.0/12,10.0.0.0/8,localhost,.local,10.54.27.105,10.96.0.0/12,10.54.27.55,172.25.226.133,intel.com,.intel.com,10.244.0.0/16,10.96.0.1,127.0.0.0/8,10.54.27.19
export socks_proxy=http://proxy-dmz.intel.com:1080
```

To make these permanent across sessions, add them to `~/.bashrc` or `/etc/environment`.

---

### Step 5 — Choose a working directory, clone the repo, and open your workspace

Pick a root working directory on your target machine — somewhere convenient for storing benchmark results, packages, and data files. Your home directory (`~`) is a good default; you can also use a dedicated folder like `/data/benchmarks` or `/workspace`.

Open a terminal in VS Code (`Ctrl+\``) and clone the repo into that directory:

```bash
cd ~    # or wherever your working directory is
git clone https://github.com/meha-v-intel/platform-benchmark-skills.git
```

Then in VS Code go to **File → Open Folder** and open your **working directory** (e.g. `~`) — not the repo subfolder itself.

This opens your working directory as a **[VS Code workspace](https://code.visualstudio.com/docs/editing/workspaces/workspaces)**. Copilot CLI will automatically discover the skill files inside `platform-benchmark-skills/.github/skills/` — the repo just needs to exist somewhere within the opened workspace folder.

> **Why not open the repo folder directly?**  
> Opening a broader working directory lets you access benchmark results, package builds, and other files alongside the skills repo from one VS Code window. Copilot CLI can still find the skills regardless.

---

### Step 6 — Start a Copilot CLI session and run benchmarks

The benchmarks are driven by **GitHub Copilot CLI** — an autonomous agent that runs commands in your terminal, interprets results, and iterates, all without you writing individual commands.

**No separate install needed.** VS Code automatically installs and configures Copilot CLI when you have the GitHub Copilot extension.

→ Full guide: [Copilot CLI sessions in VS Code](https://code.visualstudio.com/docs/copilot/agents/copilot-cli)

**To open a Copilot CLI session**, use any of these options:

- Open the Chat view (`Ctrl+Alt+I`) → click the **Session Target** dropdown → select **Copilot CLI**
- Command Palette (`Ctrl+Shift+P`) → **Chat: New Copilot CLI Session**
- Type `copilot` directly in VS Code's integrated terminal

When prompted to choose an isolation mode, select **Workspace isolation** so the agent can run commands and access files directly in your workspace.

Then describe what you want in plain English:

```
run the preflight checks
run all benchmarks
what is the memory latency on this system?
run the AMX benchmark and tell me if the result looks normal
```

Copilot CLI reads the skill files, discovers your system's configuration, and runs the correct commands automatically. You do not need to know the individual commands.

---

## How to use

1. Clone this repo into your project (or add it as a submodule)
2. Open the project in VS Code with GitHub Copilot Chat enabled
3. Ask Copilot in natural language:

```
run the preflight checks
run the CPU benchmarks
run the wakeup latency benchmark
what is the memory latency on this system?
```

Copilot automatically loads the relevant skill and runs the correct commands for your system.

---

## Skills

| Skill | What it runs | Typical runtime |
|---|---|---|
| `benchmark-preflight` | NUMA topology check + C-state enumeration | ~10s |
| `benchmark-cpu` | Max frequency, turbo curve, core-to-core latency | ~5 min |
| `benchmark-memory` | DRAM latency (multichase), bandwidth (PKB), latency-BW curve (MLC) | ~45 min |
| `benchmark-amx` | AMX BF16 + INT8 throughput via oneDNN benchdnn | ~5 min |
| `benchmark-wakeup` | C6 wakeup latency via Intel wult (TDT backend) | ~5–35 min |
| `run-benchmark` | Orchestrator — dispatches to any of the above | varies |

---

## Pass/fail criteria

| Benchmark | Metric | Pass threshold | GNR reference |
|---|---|---|---|
| NUMA check | Node count | = 1 (single domain) | 6 nodes (SNC3) |
| C-state check | cpuidle driver | intel_idle | intel_idle |
| Max frequency | Bzy_MHz | ≥ 3600 MHz | 3300 MHz |
| Core-to-core latency | Mean round-trip | ≤ 180 cycles | 63–71 cycles |
| Memory latency | 2 GiB working set | ≤ 139 ns | 116 ns |
| AMX BF16 (iso-core 8C) | Throughput | > 12.6 TFLOPS | 12.6 TFLOPS |
| AMX INT8 (iso-core 8C) | Throughput | > 22.9 TOPS | 22.9 TOPS |
| Wakeup latency | Median | ≤ 90 µs | 1.59 µs |
| Wakeup latency | Max | ≤ 260 µs | 10.59 µs |

---

## Prerequisites by benchmark

| Benchmark | Required tools |
|---|---|
| Preflight | `numactl` |
| CPU (max-freq, turbo) | `turbostat`, `cpupower` |
| CPU (core-to-core) | `cargo` + `git` (builds [nviennot/core-to-core-latency](https://github.com/nviennot/core-to-core-latency)) |
| Memory latency | `multichase` (via PKB or standalone build) |
| Memory bandwidth | PerfKitBenchmarker (PKB) |
| Memory lat-BW curve | Intel MLC v3.12 (download from Intel) |
| AMX | Intel oneDNN `benchdnn` (built from source or pre-built) |
| Wakeup | Intel `wult` v1.12+ (installed automatically by the skill) |

---

## Platform

These skills were developed and validated on:

- **Intel Diamond Rapids (DMR)** — 1S × 32C × 1T, single NUMA domain
- CentOS Stream 10, kernel 6.18.0 (BKC)
- GNR baselines from Intel Xeon 6985P-C (2S × 60C, SNC3, Ubuntu 24.04)

Skills adapt automatically to the system they run on. Core counts, NUMA topology, and tool paths are discovered at runtime, not hardcoded.

---

## Repository structure

```
.github/skills/
├── run-benchmark/              # Orchestrator skill
│   ├── SKILL.md
│   └── references/             # Detailed per-benchmark reference docs
│       ├── preflight.md
│       ├── cpu-benchmarks.md
│       ├── memory-benchmarks.md
│       ├── amx-benchmark.md
│       └── wakeup-benchmark.md
├── benchmark-preflight/
│   └── SKILL.md
├── benchmark-cpu/
│   ├── SKILL.md
│   └── scripts/
│       └── turbo_curve_imperia_final.sh   # BKM-provided script
├── benchmark-memory/
│   ├── SKILL.md
│   └── scripts/
│       └── run_mlc_lat_bw.sh              # BKM-provided MLC sweep script
├── benchmark-amx/
│   └── SKILL.md
└── benchmark-wakeup/
    └── SKILL.md
```

---

## BKM validation

Every command in these skills was validated line-by-line against Intel internal BKM documents:

- `NUMA_CHECK_BKM_NEW_BIOS`
- `C_STATE_CHECK_BKM_NEW_BIOS`
- `MAX_FREQ_TEST_BKM`
- `TURBO_CURVE_BKM`
- `CORE_TO_CORE_LATENCY_BKM_NEW_BIOS`
- `MEMORY_LATENCY_PKB_BKM_NEW_BIOS`
- `MEMORY_BANDWIDTH_PKB_BKM_NEW_BIOS`
- `MEMORY_LATENCY_BANDWIDTH_CURVE_BKM`
- `AMX_PERFORMANCE_BKM_NEW_BIOS_GNR`
- `WAKEUP_LATENCY_BKM_NEW_BIOS`
