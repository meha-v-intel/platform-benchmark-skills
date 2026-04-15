#!/bin/bash
# slurm-start.sh — Start MUNGE + slurmctld + slurmd cleanly on a DMR single-node system
# Usage: bash slurm-start.sh [--clean]
# --clean: remove stale state files first (required after ClusterName change)
set -euo pipefail

PREFIX=${PREFIX:-/usr/local/slurm}
SLURM_STATE=${SLURM_STATE:-/var/lib/slurm}

export PATH="$PREFIX/bin:$PREFIX/sbin:$PATH"

CLEAN=0
[[ "${1:-}" == "--clean" ]] && CLEAN=1

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# 1. MUNGE
if ! pgrep -x munged &>/dev/null; then
  log "Starting MUNGE..."
  systemctl start munge || /usr/sbin/munged -f
fi
pgrep -x munged &>/dev/null && log "MUNGE running ✓" || { echo "ERROR: munged failed"; exit 1; }

# 2. Kill any stale Slurm processes
if pgrep -f slurmctld &>/dev/null || pgrep -f "slurmd$" &>/dev/null; then
  log "Stopping existing Slurm daemons..."
  pkill -f slurmctld 2>/dev/null || true
  pkill -f "slurmd$" 2>/dev/null || true
  sleep 1
fi

# 3. Clean state (avoids CLUSTER NAME MISMATCH errors)
if (( CLEAN )); then
  log "Clearing stale state files..."
  rm -f "$SLURM_STATE"/*
fi

# 4. slurmctld
log "Starting slurmctld..."
"$PREFIX/sbin/slurmctld"
sleep 1

# Verify slurmctld port open
if ! pgrep -f slurmctld &>/dev/null; then
  echo "ERROR: slurmctld failed to start. Check: journalctl -xeu slurmctld" >&2
  exit 1
fi
log "slurmctld running (PID $(pgrep -f slurmctld | head -1)) ✓"

# 5. slurmd
log "Starting slurmd..."
"$PREFIX/sbin/slurmd"
sleep 2

if ! pgrep -f "slurmd$" &>/dev/null; then
  echo "ERROR: slurmd failed to start. Try: $PREFIX/sbin/slurmd -D -vv" >&2
  exit 1
fi
log "slurmd running (PID $(pgrep -f "slurmd$" | head -1)) ✓"

# 6. Status
echo ""
log "=== Cluster Status ==="
sinfo --long
echo ""
log "=== Node ==="
scontrol show node "$(hostname -s)" | grep -E "State|CPUTot|RealMemory|Partitions"
echo ""
log "Slurm is ready. PATH: $PREFIX/bin added."
log "Commands: sinfo  squeue  sbatch  srun  salloc  scancel  scontrol"
