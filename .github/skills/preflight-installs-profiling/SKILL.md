---
name: preflight-installs-profiling
description: "Pre-flight installs for profiling on a new Intel platform system. Use when: setting up a new system for profiling, installing Intel oneAPI, SEP driver, perf, financial-samples, platform-benchmark-skills, preparing environment for benchmarking or profiling workloads."
argument-hint: "[check|install|all]"
allowed-tools: Bash
---

# Pre-Flight Installs for Profiling

Bootstrap a fresh Intel platform system with all tools required for benchmarking and profiling workloads. Run once on a new system before any benchmark or profiling session.

Default argument: `all` — runs every step. Pass `check` to audit what is already present without installing anything.

---

## Step 1 — System Prerequisites

```bash
ARG=${1:-all}

echo "=============================="
echo " PRE-FLIGHT INSTALLS: STEP 1  "
echo " System prerequisites         "
echo "=============================="

check_tool() { command -v "$1" &>/dev/null && echo "  [OK]  $1" || echo "  [MISSING] $1"; }

check_tool git
check_tool gcc
check_tool g++
check_tool make
check_tool cmake
check_tool perf
check_tool node
check_tool npm
check_tool python3

if [[ "$ARG" == "check" ]]; then
    echo "check-only mode — no installs performed"
    exit 0
fi

# perf — must match running kernel
KERNEL=$(uname -r)
echo "Kernel: $KERNEL"
if ! command -v perf &>/dev/null; then
    # Try dnf first (RHEL/CentOS Stream), fall back to apt (Ubuntu/Debian)
    if command -v dnf &>/dev/null; then
        sudo dnf install -y perf || sudo dnf install -y "kernel-tools-$(uname -r)" 2>/dev/null || true
    elif command -v apt-get &>/dev/null; then
        sudo apt-get install -y linux-tools-common "linux-tools-$(uname -r)" linux-tools-generic
    fi
else
    echo "  perf already installed: $(perf --version)"
fi

# Build-essential utilities
if command -v dnf &>/dev/null; then
    sudo dnf install -y git gcc gcc-c++ make cmake numactl numactl-devel \
        msr-tools kernel-tools python3 python3-pip 2>&1 | tail -5
elif command -v apt-get &>/dev/null; then
    sudo apt-get install -y git gcc g++ make cmake numactl \
        msr-tools linux-tools-common python3 python3-pip 2>&1 | tail -5
fi

echo "Step 1 complete."
```

---

## Step 2 — Intel oneAPI Toolkit

```bash
echo "=============================="
echo " PRE-FLIGHT INSTALLS: STEP 2  "
echo " Intel oneAPI Toolkit          "
echo "=============================="

ONEAPI_ROOT=${ONEAPI_ROOT:-/opt/intel/oneapi}

if [[ -f "$ONEAPI_ROOT/setvars.sh" ]]; then
    echo "  [OK]  Intel oneAPI found at $ONEAPI_ROOT"
    source "$ONEAPI_ROOT/setvars.sh" --force > /dev/null 2>&1 || true
    echo "  icpx : $(icpx --version 2>/dev/null | head -1 || echo 'not in PATH after setvars')"
    echo "  vtune: $(vtune --version 2>/dev/null | head -1 || echo 'not in PATH after setvars')"
else
    echo "  [MISSING] Intel oneAPI not found at $ONEAPI_ROOT"
    echo ""
    echo "  Install Intel oneAPI Base + HPC Toolkit 2025.x manually:"
    echo "  https://www.intel.com/content/www/us/en/developer/tools/oneapi/toolkits.html"
    echo ""
    echo "  Quick install (network):"
    echo "    wget https://registrationcenter-download.intel.com/akdlm/IRC_NAS/oneapi-for-intel-cpu/l_BaseKit_p_2025.3.0.tgz"
    echo "    tar xzf l_BaseKit_p_2025.3.0.tgz && cd l_BaseKit_p_2025.3.0"
    echo "    sudo ./install.sh --cli-config-file silent.cfg"
    echo ""
    echo "  Required components: compiler, vtune, advisor, dnnl, mkl, ipp, tbb"
    echo "  After install, re-run this skill."
    exit 1
fi
```

**Pass**: `setvars.sh` found and `icpx` resolves after sourcing.
**Fail**: oneAPI not installed — follow the printed URL to download and install before continuing.

---

## Step 3 — SEP Driver (VTune Kernel Sampling)

SEP (Sampling Enabling Product) is required for hardware event-based sampling (PEBS, LBR, uncore PMU) via VTune and `perf`.

```bash
echo "=============================="
echo " PRE-FLIGHT INSTALLS: STEP 3  "
echo " SEP Driver                    "
echo "=============================="

source "${ONEAPI_ROOT:-/opt/intel/oneapi}/setvars.sh" --force > /dev/null 2>&1 || true

# Locate sepdk — try standalone install first, fall back to VTune-bundled
SEPDK_DIR=$(find /opt/intel/sep_private* /opt/intel/oneapi/vtune/*/sepdk \
    -maxdepth 0 -type d 2>/dev/null | sort -V | tail -1)

if [[ -z "$SEPDK_DIR" ]]; then
    echo "  [MISSING] sepdk not found under /opt/intel/"
    echo "  SEP is bundled with VTune. Ensure VTune is installed (Step 2)."
    echo "  Alternatively download SEP standalone from:"
    echo "  https://www.intel.com/content/www/us/en/developer/articles/tool/vtune-profiler.html"
    exit 1
fi

echo "  sepdk found: $SEPDK_DIR"

# Check if SEP driver is already loaded
if lsmod | grep -q sep5; then
    echo "  [OK]  SEP driver already loaded: $(lsmod | grep sep5 | awk '{print $1}')"
else
    echo "  Building and installing SEP driver from $SEPDK_DIR/src ..."
    cd "$SEPDK_DIR/src"
    sudo ./build-driver -ni 2>&1 | tail -10
    sudo ./insmod-sep -g vtune -pu 2>&1 | tail -5
    # Persist across reboots
    sudo ./boot-script --install 2>&1 | tail -3 || true
fi

lsmod | grep sep && echo "  [OK]  SEP driver loaded" || echo "  [WARN] SEP driver not in lsmod after install"

# Validate perf + SEP together
echo "--- perf event smoke test ---"
perf stat -e cycles,instructions -o /tmp/perf_smoke.txt -- sleep 0.1 2>&1 | tail -5
cat /tmp/perf_smoke.txt 2>/dev/null | grep -E "cycles|instructions" || true
echo "Step 3 complete."
```

**Pass**: `lsmod | grep sep5` returns a module entry and `perf stat` reports hardware counters without `<not supported>`.
**Fail**: Driver build error — check kernel headers are installed (`dnf install kernel-devel-$(uname -r)` or `apt-get install linux-headers-$(uname -r)`).

---

## Step 4 — Node.js and npm Tools

```bash
echo "=============================="
echo " PRE-FLIGHT INSTALLS: STEP 4  "
echo " Node.js + npm tools           "
echo "=============================="

node --version 2>/dev/null || {
    echo "  [MISSING] node — install Node.js 18+ via nvm or system package manager"
    if command -v dnf &>/dev/null; then
        sudo dnf install -y nodejs npm
    elif command -v apt-get &>/dev/null; then
        sudo apt-get install -y nodejs npm
    fi
}

echo "  node : $(node --version 2>/dev/null)"
echo "  npm  : $(npm --version 2>/dev/null)"

# Configure npm global prefix (no sudo required)
mkdir -p ~/.npm-global
npm config set prefix ~/.npm-global
export PATH="$PATH:$HOME/.npm-global/bin"

# Install pdf-to-text (used for PDF result parsing)
if [[ -d ~/.npm-global/lib/node_modules/pdf-to-text ]]; then
    echo "  [OK]  pdf-to-text already installed"
else
    npm install -g pdf-to-text 2>&1 | tail -3
    echo "  [OK]  pdf-to-text installed"
fi

# Persist PATH update
PROFILE_LINE='export PATH="$PATH:$HOME/.npm-global/bin"'
grep -qF "$PROFILE_LINE" ~/.bashrc || echo "$PROFILE_LINE" >> ~/.bashrc
echo "Step 4 complete."
```

---

## Step 5 — Clone Required Repositories

```bash
echo "=============================="
echo " PRE-FLIGHT INSTALLS: STEP 5  "
echo " Repository setup              "
echo "=============================="

WORKDIR=${PROFILING_WORKDIR:-$HOME/ww16}
mkdir -p "$WORKDIR"

clone_or_update() {
    local NAME=$1
    local URL=$2
    local DIR="$WORKDIR/$NAME"
    if [[ -d "$DIR/.git" ]]; then
        echo "  [OK]  $NAME already cloned — pulling latest"
        git -C "$DIR" pull --ff-only 2>&1 | tail -2
    else
        echo "  Cloning $NAME ..."
        git clone "$URL" "$DIR" 2>&1 | tail -3
        echo "  [OK]  $NAME cloned to $DIR"
    fi
}

# financial-samples — Monte Carlo workloads, Asian options, HPC grid benchmarks
clone_or_update "financial-samples" "https://github.com/intel-sandbox/financial-samples"

# platform-benchmark-skills — Copilot skills for Intel platform micro-benchmarks
clone_or_update "platform-benchmark-skills" "https://github.com/meha-v-intel/platform-benchmark-skills"

echo ""
echo "  Repos available at: $WORKDIR"
ls "$WORKDIR"
echo "Step 5 complete."
```

> **Note:** If this system sits behind a corporate proxy, set git proxy first:
> ```bash
> git config --global http.proxy  http://proxy-us.intel.com:911
> git config --global https.proxy http://proxy-us.intel.com:911
> ```

---

## Step 6 — Final Validation Report

```bash
echo ""
echo "================================================"
echo " PRE-FLIGHT INSTALLS — FINAL VALIDATION REPORT "
echo "================================================"

PASS=0; FAIL=0
chk() {
    local label=$1; shift
    if eval "$@" &>/dev/null; then
        echo "  [PASS] $label"
        ((PASS++))
    else
        echo "  [FAIL] $label"
        ((FAIL++))
    fi
}

source "${ONEAPI_ROOT:-/opt/intel/oneapi}/setvars.sh" --force > /dev/null 2>&1 || true
export PATH="$PATH:$HOME/.npm-global/bin"
WORKDIR=${PROFILING_WORKDIR:-$HOME/ww16}

chk "git"                         "command -v git"
chk "gcc"                         "command -v gcc"
chk "make"                        "command -v make"
chk "perf"                        "command -v perf"
chk "perf hw counters"            "perf stat -e cycles -- sleep 0.01 2>&1 | grep -v '<not supported>'"
chk "python3"                     "command -v python3"
chk "node >= 18"                  "node -e 'process.exit(parseInt(process.version.slice(1))>=18?0:1)'"
chk "npm"                         "command -v npm"
chk "pdf-to-text"                 "test -d $HOME/.npm-global/lib/node_modules/pdf-to-text"
chk "Intel oneAPI setvars.sh"     "test -f ${ONEAPI_ROOT:-/opt/intel/oneapi}/setvars.sh"
chk "icpx (Intel C++ compiler)"   "command -v icpx"
chk "vtune"                       "command -v vtune"
chk "SEP driver loaded"           "lsmod | grep -q sep"
chk "financial-samples cloned"    "test -d $WORKDIR/financial-samples/.git"
chk "platform-benchmark-skills"   "test -d $WORKDIR/platform-benchmark-skills/.git"

echo ""
echo "  PASSED: $PASS   FAILED: $FAIL"
echo "================================================"

if [[ $FAIL -gt 0 ]]; then
    echo "  STATUS: INCOMPLETE — resolve FAIL items above before benchmarking"
    exit 1
else
    echo "  STATUS: READY — all prerequisites satisfied"
fi
```