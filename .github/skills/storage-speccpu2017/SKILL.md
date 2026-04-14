---
name: storage-speccpu2017
description: "Run SPEC CPU 2017 SPECrate integer and floating-point benchmarks for storage segment validation Test 103. Use when: measuring SPECrate2017_int_base, measuring SPECrate2017_fp_base, benchmarking CPU integer throughput, benchmarking CPU FP throughput, validating CPU compute performance for storage workloads, comparing DMR vs GNR CPU rate performance, running SPEC CPU 2017 intrate or fprate."
argument-hint: "[intrate|fprate|intrate-quick|all]"
allowed-tools: Bash
---

# SPEC CPU 2017 — SPECrate Integer & FP (Storage Test 103)

Measures **SPECrate2017_int_base** and **SPECrate2017_fp_base** — the industry-standard
multi-copy CPU throughput benchmark. Rate metrics exercise all cores simultaneously,
making them a strong proxy for CPU compute capacity in storage controller workloads
(compression offload, checksum computation, encryption, protocol processing).

> **Test 103 scope:** intrate (10 benchmarks) + fprate (10 benchmarks), base tuning,
> `--noreportable` for internal validation. Three iterations required for a valid score.

**Install location (DMR):** `/opt/spec2017`  
**Config used (DMR):** `gcc8.2.0-lin-O2-rate-20200520.cfg` (pre-built GCC 8.2.0 binaries)  
**Argument:** `$ARGUMENTS` — `intrate`, `fprate`, `intrate-quick` (single benchmark sanity check), or `all`

---

## Platform Notes — GNR vs DMR Side-by-Side

This skill was developed by exploring a working GNR reference system and adapting for DMR.
The table below documents every meaningful difference so Copilot can reproduce either setup.

| Item | GNR (reference, `172.26.36.136`) | DMR (this system, local) |
|---|---|---|
| **CPU** | Intel Xeon 6972P, 2S × 96c × 2T = 384 logical CPUs | Intel DMR, 1S × 32c × 1T = 32 logical CPUs |
| **NUMA topology** | 6 NUMA nodes (3 per socket) | 1 NUMA node |
| **OS** | Ubuntu 24.04.1 LTS (Noble Numbat) | CentOS Stream 10 (Coughlan) |
| **System GCC** | GCC 13.3.0 (Ubuntu) | GCC 14.2.1 (Red Hat) |
| **SPEC version** | **1.0.2** | **1.1.8** |
| **SPEC install path** | `/root/CPU2017_1.0.2/` | `/opt/spec2017/` |
| **Config file** | `gcc8.1.0-lin-O2-rate-20180626.cfg` | `gcc8.2.0-lin-O2-rate-20200520.cfg` |
| **Config path** | `/root/CPU2017_1.0.2/config/gcc8.1.0-lin-O2-rate-20180626.cfg` | `/opt/spec2017/config/gcc8.2.0-lin-O2-rate-20200520.cfg` |
| **GCC path in config** | `%define gccpath /usr/local/gcc-8.1.0` (⚠️ **dir does NOT exist** — binaries were pre-built and already in `benchspec/*/exe/`) | `%define gccpath /usr/local/gcc-8.2.0` (⚠️ **dir does NOT exist** — pre-built binaries from tarball overlay used) |
| **Compiler that built benchmarks** | GCC 8.1.0 (confirmed via `strings` on binary) | GCC 8.2.0 (pre-built from Intel cargo tarball) |
| **Benchmark binary label** | `*.gcc8.1.0-lin-O2-rate-20180626` | `*.gcc8.2.0-lin-O2-rate-20200520` |
| **Copies** | `26` (hardcoded — only ~13% of the 192 physical cores) | `32` (all physical cores) |
| **runcpu wrapper** | `numactl --interleave=all runcpu ...` (multi-socket NUMA interleave) | `runcpu ...` (no wrapper — single NUMA node) |
| **Topology detection** | `./numa-detection.sh` + `specperl nhmtopology.pl` → writes `topo.txt` → passed as `--define $b` | Not used (1-NUMA, no topology defines needed) |
| **SMT flag** | `--define smt-on` (HT enabled on GNR) | Not used (1T/core on DMR, no HT) |
| **Extra defines** | `--define cores=26 --define invoke_with_interleave --define $b` | None (all optional for single-socket) |
| **libnsl.so.1** | Exists natively (`/lib/x86_64-linux-gnu/libnsl.so.1`) — Ubuntu ships it | **Missing** — must create symlink: `ln -sf /lib64/libnsl.so.3 /lib64/libnsl.so.1` |
| **numactl version** | 2.0.18 | 2.0.18 |
| **Run scripts** | `/root/CPU2017_1.0.2/cpu2017_intrate.sh`, `cpu2017_fprate.sh` | `/opt/spec2017/cpu2017_intrate.sh`, `cpu2017_fprate.sh`, `cpu2017_intrate_quick.sh` |
| **Support scripts** | `/root/CPU2017_1.0.2/numa-detection.sh`, `nhmtopology.pl` (topology detection for multi-socket) | `/opt/spec2017/numa-detection.sh` (copied from GNR, not used in run command) |
| **gcc.xml flags file** | `/root/CPU2017_1.0.2/gcc.xml` | `/opt/spec2017/gcc.xml` (copied from GNR) |
| **Pre-built binary source** | Already present in SPEC 1.0.2 install (origin unknown) | Intel cargo: `http://cce-docker-cargo.sh.intel.com/software/FOR-INTEL-cpu2017-1.1.0-gcc8.2.0-lin-primarytargets-baseonly-binaries-20200520.tar.xz` |
| **ISO source** | Already installed — no ISO needed | Intel cargo: `http://cce-docker-cargo.sh.intel.com/software/speccpu.iso` |

### GNR Run Command (verbatim)
```bash
# /root/CPU2017_1.0.2/cpu2017_intrate.sh on GNR
cd /home/sld/CPU2017_1.0.2   # ← note: /home/sld, not /root
. ./shrc
ulimit -s unlimited
echo always > /sys/kernel/mm/transparent_hugepage/enabled
. ./numa-detection.sh
rm -rf topo.txt
specperl nhmtopology.pl       # generates topo.txt with topology string
b=$(cat topo.txt)             # e.g. "2sock-6node-96core"
numactl --interleave=all \
  runcpu --define default-platform-flags --copies 26 \
    -c gcc8.1.0-lin-O2-rate-20180626.cfg \
    --define smt-on --ignore_errors \
    --define cores=26 --define $b \
    --define invoke_with_interleave --define drop_caches \
    --tune base --noreportable -o all -n 3 intrate
```

### DMR Run Command (this system)
```bash
# /opt/spec2017/cpu2017_intrate.sh on DMR
cd /opt/spec2017
. ./shrc
ulimit -s unlimited
echo always > /sys/kernel/mm/transparent_hugepage/enabled
rm -rf /opt/spec2017/benchspec/CPU/*/run/*   # ← DMR-specific: prevent copy numbering drift
sync; echo 3 > /proc/sys/vm/drop_caches
runcpu --define default-platform-flags --copies 32 \
  -c gcc8.2.0-lin-O2-rate-20200520.cfg \
  --ignore_errors --define drop_caches \
  --tune base --noreportable -o all -n 3 intrate
# No numactl --interleave (1 NUMA node)
# No --define smt-on (1T/core)
# No --define $topology (single socket)
```

### Key Takeaways for Adapting to a New System
1. **Config file must match binary label** — the `label =` line in the `.cfg` must match the `exe/` directory name suffix
2. **GCC path in config (`%define gccpath`) can be a non-existent path** if pre-built binaries are already in `benchspec/*/exe/` — SPEC only uses the path for `--action build` recompilation
3. **`numactl --interleave=all` wrapper** is only needed for multi-socket systems; drop it for 1-socket
4. **Topology defines** (`--define $b`, `--define cores=N`) are GNR/multi-socket specific; not required for 1S
5. **libnsl.so.1** — Ubuntu ships it natively; RHEL/CentOS 10 does not — always check first

---

## Variables

| Variable | Description | Default |
|---|---|---|
| `SPEC_DIR` | SPEC install root | `/opt/spec2017` |
| `COPIES` | Number of parallel copies | `32` (= physical core count on DMR 1S) |
| `ITERATIONS` | Runs per benchmark for averaging | `3` (minimum for valid score) |
| `CONFIG` | Config file label | `gcc8.2.0-lin-O2-rate-20200520.cfg` |

---

## Prerequisites

```bash
# Verify SPEC is installed
ls /opt/spec2017/bin/runcpu || { echo "SPEC not installed — run install_speccpu2017.sh first"; exit 1; }

# Source the environment
cd /opt/spec2017 && source ./shrc
runcpu --version   # expect: runcpu v6612, linux-x86_64 tools

# Verify GCC8 pre-built binaries are present
ls /opt/spec2017/benchspec/CPU/505.mcf_r/exe/*gcc8* | head -3
# Expected: mcf_r_base.gcc8.2.0-lin-O2-rate-20200520 (and other variants)

# Verify libnsl.so.1 (required by specperl on RHEL/CentOS 10)
ls /lib64/libnsl.so.1 2>/dev/null || {
    dnf install -y libnsl2
    ln -sf /lib64/libnsl.so.3 /lib64/libnsl.so.1
    ldconfig
}

# numactl required for copy binding
which numactl || dnf install -y numactl
```

---

## Installation (if not yet installed)

```bash
bash /root/install_speccpu2017.sh /opt/spec2017
```

> The install script downloads from the Intel cargo server:
> - `speccpu.iso` — SPEC harness + benchmark source/data (~3 GB)
> - `cpu2017-gcc8.tar.xz` — GCC 8.2.0 pre-built binaries (multiple ISA targets)
> - `cpu2017-gcc12.tar.xz` — GCC 12.1.0 pre-built binaries (optional, higher perf)
>
> **Known issue — ISO 8.3 filename truncation**: The ISO uses ISO 9660 Level 1 which
> truncates all filenames to 8.3 format (e.g. `SCRIPTS.MIS/EXEC_TES`). Standard
> `mount -o loop` does not expose long names. The install script handles this by
> extracting with `7z` and creating correct symlinks before running `install.sh`.
>
> **Known issue — libnsl.so.1 missing on EL10**: `specperl` links against `libnsl.so.1`
> which is absent on CentOS Stream 10 / RHEL 10. Fix: install `libnsl2` and symlink
> `libnsl.so.3 → libnsl.so.1` (ABI-compatible). See Prerequisites above.

---

## Pre-Run System Configuration

Apply before every run — these settings are critical for reproducibility:

```bash
# 1. Unlimited stack (required — some benchmarks crash without this)
ulimit -s unlimited

# 2. Transparent Huge Pages — always on (matches GNR reference config)
echo always > /sys/kernel/mm/transparent_hugepage/enabled
cat /sys/kernel/mm/transparent_hugepage/enabled   # confirm: [always]

# 3. Drop page cache to start from clean memory state
sync; echo 3 > /proc/sys/vm/drop_caches

# 4. Clean stale run directories (CRITICAL — see Known Issues below)
rm -rf /opt/spec2017/benchspec/CPU/*/run/*
```

---

## Test 103a — SPECrate2017 Integer (intrate)

**Argument:** `intrate` | **Runtime:** ~5–7 hours (32 copies, 3 iterations, 2.2 GHz)

```bash
cd /opt/spec2017 && source ./shrc
ulimit -s unlimited
echo always > /sys/kernel/mm/transparent_hugepage/enabled
rm -rf /opt/spec2017/benchspec/CPU/*/run/*
sync; echo 3 > /proc/sys/vm/drop_caches

runcpu \
  --define default-platform-flags \
  --copies 32 \
  -c gcc8.2.0-lin-O2-rate-20200520.cfg \
  --ignore_errors \
  --define drop_caches \
  --tune base \
  --noreportable \
  -o all \
  -n 3 \
  intrate
```

Results: `/opt/spec2017/result/CPU2017.NNN.intrate.refrate.txt`

---

## Test 103b — SPECrate2017 Floating Point (fprate)

**Argument:** `fprate` | **Runtime:** ~5–7 hours (32 copies, 3 iterations, 2.2 GHz)

```bash
cd /opt/spec2017 && source ./shrc
ulimit -s unlimited
echo always > /sys/kernel/mm/transparent_hugepage/enabled
rm -rf /opt/spec2017/benchspec/CPU/*/run/*
sync; echo 3 > /proc/sys/vm/drop_caches

runcpu \
  --define default-platform-flags \
  --copies 32 \
  -c gcc8.2.0-lin-O2-rate-20200520.cfg \
  --ignore_errors \
  --define drop_caches \
  --tune base \
  --noreportable \
  -o all \
  -n 3 \
  fprate
```

Results: `/opt/spec2017/result/CPU2017.NNN.fprate.refrate.txt`

---

## Test 103 Quick Sanity Check (intrate-quick)

**Argument:** `intrate-quick` | **Runtime:** ~20–25 minutes | **Use:** Verify setup before a full run

Runs only `505.mcf_r` (1 iteration). If this passes, the full suite will run correctly.

```bash
cd /opt/spec2017 && source ./shrc
ulimit -s unlimited
echo always > /sys/kernel/mm/transparent_hugepage/enabled
rm -rf /opt/spec2017/benchspec/CPU/*/run/*
sync; echo 3 > /proc/sys/vm/drop_caches

runcpu \
  --define default-platform-flags \
  --copies 32 \
  -c gcc8.2.0-lin-O2-rate-20200520.cfg \
  --ignore_errors \
  --define drop_caches \
  --tune base \
  --noreportable \
  -o all \
  -n 1 \
  505.mcf_r
```

> Also available as a shell script: `bash /opt/spec2017/cpu2017_intrate_quick.sh`

---

## Reading Results

```bash
RESULT_FILE=$(ls -t /opt/spec2017/result/CPU2017.*.intrate.refrate.txt 2>/dev/null | head -1)
echo "Latest result: $RESULT_FILE"

# Overall score
grep "Est\. SPEC" $RESULT_FILE

# Per-benchmark scores (selected/final rows)
awk '/^=+$/{p=1} p && /^\s+[0-9]+\./{print}' $RESULT_FILE | grep '\*'

# Check for INVALID run markers
grep "INVALID\|not enough runs\|Unknown flags" $RESULT_FILE | head -5
```

---

## GNR Reference Baselines (Intel Xeon 6972P, 26 copies, Jan 2026)

| Benchmark | GNR Copies | GNR Time (s) | GNR Ratio |
|---|---|---|---|
| 500.perlbench_r | 26 | 283 | 146 |
| 502.gcc_r | 26 | 244 | 151 |
| 505.mcf_r | 26 | 384 | 109 |
| 520.omnetpp_r | 26 | 492 | 69.3 |
| 523.xalancbmk_r | 26 | 289 | 94.9 |
| 525.x264_r | 26 | 359 | 127 |
| 531.deepsjeng_r | 26 | 303 | 98.2 |
| 541.leela_r | 26 | 473 | 91.1 |
| 548.exchange2_r | 26 | 284 | 240 |
| 557.xz_r | 26 | 456 | 61.5 |
| **Est. SPECrate2017_int_base** | | | **110** |
| **Est. SPECrate2017_fp_base** | | | **101** |

> GNR used only 26 copies on a 192-core (96c × 2S) system — a fraction of capacity.
> Config: `gcc8.1.0-lin-O2-rate-20180626.cfg`, `--noreportable`, 3 iterations.

## DMR Observed (505.mcf_r only, 32 copies, 1 iteration, Apr 2026)

| Benchmark | DMR Copies | DMR Time (s) | DMR Ratio |
|---|---|---|---|
| 505.mcf_r | 32 | 1194 | 43.3 |

> DMR is ~3× slower on mcf_r vs GNR. Expected — mcf_r is **memory-latency bound**,
> and DMR runs at 2.2 GHz vs GNR's ~3.0 GHz base, with a different memory subsystem.
> Full intrate score for DMR has not yet been established (Test 103 = blocked).

---

## Per-Benchmark Characteristics & Expected Runtimes on DMR

| Benchmark | Type | Memory sensitivity | Est. DMR time/iter (32 copies) |
|---|---|---|---|
| 500.perlbench_r | Integer (Perl interpreter) | Medium | ~15–20 min |
| 502.gcc_r | Integer (GCC compiler) | Medium | ~15–20 min |
| 505.mcf_r | Integer (network simplex) | **Very High** ⚠️ | ~20–25 min |
| 520.omnetpp_r | Integer (C++ simulation) | High | ~20–25 min |
| 523.xalancbmk_r | Integer (XML transform) | Medium | ~15 min |
| 525.x264_r | Integer (video encode) | Low-Medium | ~15 min |
| 531.deepsjeng_r | Integer (chess engine) | Low | ~12–15 min |
| 541.leela_r | Integer (Go engine) | Low | ~12–15 min |
| 548.exchange2_r | Integer (Fortran chess) | Low | ~10–12 min |
| 557.xz_r | Integer (compression) | Medium-High | ~25–30 min |

**Total intrate wall time estimate (3 iterations):** ~5–7 hours at 2.2 GHz, 32 copies.

---

## Known Issues & Fixes

### 1. Run directory CPU binding mismatch ⚠️ (Critical)

**Symptom:** Run directory named `run_base_refrate_*.0064-0095` on a 32-core system.  
**Cause:** SPEC increments copy numbers across runs. If prior runs (even killed ones)
left run directories in `benchspec/CPU/*/run/`, the next run starts numbering from
where they left off. On a 32-core system, copies 64–95 don't exist, so numactl
binding falls back to default (may land anywhere) — results are valid but CPU
affinity is wrong.  
**Fix:** Always clean run directories before starting a run:
```bash
rm -rf /opt/spec2017/benchspec/CPU/*/run/*
```

### 2. libnsl.so.1 missing on EL10

**Symptom:** `specperl: error while loading shared libraries: libnsl.so.1: cannot open shared object file`  
**Cause:** `specperl` (the SPEC-bundled Perl binary) was compiled against `libnsl.so.1`,
which was removed in glibc 2.36+ (EL10 ships glibc 2.39).  
**Fix:**
```bash
dnf install -y libnsl2
ln -sf /lib64/libnsl.so.3 /lib64/libnsl.so.1
ldconfig
```
> libnsl.so.3 is ABI-compatible with libnsl.so.1 for the NIS/hostname calls specperl uses.

### 3. "Did not have enough runs" in result

**Symptom:** Result file shows `# 505.mcf_r (base) did not have enough runs!`  
**Cause:** `-n 1` (single iteration) was used. SPEC requires 3 iterations for a
valid score; with fewer it reports as invalid.  
**Fix:** Use `-n 3` for all production runs. Use `-n 1` only for sanity checking.

### 4. mcf_r appears hung for 15–25 minutes

**Symptom:** Terminal shows `Running 505.mcf_r refrate (ref) base ... (32 copies)` and
appears stuck.  
**Cause:** 505.mcf_r is memory-latency bound and legitimately takes 20+ minutes at
2.2 GHz. Verify it is actually running:
```bash
ps aux | grep mcf_r | grep -v grep | wc -l   # should be 32
top -bn1 | head -5                            # load average should be ~32
```
If 32 processes at 100% CPU → normal, let it run.

### 5. Score marked INVALID in result file

**Symptom:** Result file has `INVALID RUN` banners.  
**Cause (common):** `--noreportable` was used (expected for internal runs — this is fine).  
**Cause (unexpected):** Unknown compiler flags referenced in config, or checksums failed.  
**Fix for reportable run:** Remove `--noreportable` and ensure flagsurl points to a
valid flags XML file. For internal benchmarking, INVALID due to `--noreportable` is
acceptable and expected.

---

## Pass / Fail Thresholds

> DMR full-suite baseline is not yet established (Test 103 blocked). Thresholds
> will be set from the first clean 3-iteration full run. Interim guidance:

| Metric | GNR Reference | Interim DMR Target | Notes |
|---|---|---|---|
| SPECrate2017_int_base | 110 (26c) | TBD (32c) | Expect lower ratio/copy due to 2.2 GHz vs 3.0 GHz |
| SPECrate2017_fp_base | 101 (26c) | TBD (32c) | FP benchmarks more sensitive to FPU units |
| 505.mcf_r ratio | 109 | ~40–50 | Memory-latency bound; 3× slower expected |
| Run time (intrate, 3 iter) | ~3–4 hrs (GNR) | ~5–7 hrs (DMR) | Based on mcf_r extrapolation |

---

## Useful runcpu Options Reference

| Option | Purpose | Example |
|---|---|---|
| `--copies N` | Set number of parallel copies | `--copies 32` |
| `-n N` | Number of iterations | `-n 3` |
| `--ignore_errors` | Don't abort on single benchmark failure | recommended |
| `--noreportable` | Skip official validation checks | for internal use |
| `-o all` | Produce all output formats (txt, pdf, csv, html) | recommended |
| `--tune base` | Base tuning only (no peak) | for internal use |
| `--size test` | Tiny workload size (minutes, not hours) | quick smoke test |
| `--action build` | Rebuild benchmarks from source | if binaries are corrupt |
| `intrate` | Run all 10 integer rate benchmarks | |
| `fprate` | Run all 10 FP rate benchmarks | |
| `505.mcf_r` | Run single benchmark by name | |

---

## Cleanup

```bash
# Remove run directories after results are collected (saves ~10–50 GB)
rm -rf /opt/spec2017/benchspec/CPU/*/run/*

# Keep result files — they are small and useful for comparison
ls /opt/spec2017/result/
```
