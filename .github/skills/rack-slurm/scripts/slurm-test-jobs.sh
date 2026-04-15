#!/bin/bash
# slurm-test-jobs.sh — Submit a full battery of Slurm job tests across all partitions
# Tests: sbatch basics, SLURM env vars, srun tasks, multi-partition, arrays, dependencies, scancel
# Usage: bash slurm-test-jobs.sh [--partition batch|debug|fast|long|all]
# Prereq: slurmctld + slurmd running, sinfo shows idle nodes
set -euo pipefail

SLURM_BIN=${SLURM_BIN:-/usr/local/slurm/bin}
OUTDIR=${OUTDIR:-/tmp/slurm_tests_$(date +%Y%m%d_%H%M%S)}
PART=${1:-debug}  # Default to debug (30min limit) for quick tests

export PATH="$SLURM_BIN:$PATH"

mkdir -p "$OUTDIR"
PASS=0
FAIL=0
log() { echo "[$(date '+%H:%M:%S')] $*"; }
pass() { log "PASS: $*"; (( PASS++ )) || true; }
fail() { log "FAIL: $*"; (( FAIL++ )) || true; }

check_slurm() {
  sinfo &>/dev/null || { echo "ERROR: Slurm not running. Run slurm-start.sh first." >&2; exit 1; }
  log "Slurm is up. Starting tests → $OUTDIR"
  sinfo --long
  echo ""
}

wait_job() {
  local jobid=$1 timeout=${2:-30}
  local elapsed=0
  while (( elapsed < timeout )); do
    local state
    state=$(squeue --jobs="$jobid" --noheader -o "%T" 2>/dev/null || echo "GONE")
    [[ "$state" == "GONE" || "$state" == "" ]] && return 0
    sleep 2; (( elapsed += 2 ))
  done
  return 1
}

# ── Test 1: Basic sbatch + SLURM env vars ────────────────────────────────────
run_test1() {
  log "Test 1: Basic sbatch + SLURM environment variables"
  local out="$OUTDIR/t1_env.out"
  local jid
  jid=$(sbatch -p $PART --job-name=t1_env --ntasks=1 --time=00:02:00 \
    --output="$out" \
    --wrap='echo "JOB_ID=$SLURM_JOB_ID JOB_NAME=$SLURM_JOB_NAME PARTITION=$SLURM_JOB_PARTITION"; echo "NODE=$SLURM_JOB_NODELIST NODES=$SLURM_JOB_NUM_NODES CLUSTER=$SLURM_CLUSTER_NAME"' \
    | awk '{print $4}')

  log "  Submitted job $jid to partition=$PART"
  wait_job "$jid" 30

  if grep -q "JOB_ID=$jid" "$out" 2>/dev/null; then
    pass "T1: SLURM_JOB_ID=$jid visible in job ($(grep PARTITION "$out"))"
  else
    fail "T1: output missing or JOB_ID wrong (expected $jid)"
  fi
  echo ""
}

# ── Test 2: srun parallel tasks + SLURM_PROCID ───────────────────────────────
run_test2() {
  log "Test 2: srun with 4 parallel tasks + SLURM_PROCID"
  local out="$OUTDIR/t2_srun.out"
  local jid
  jid=$(sbatch -p $PART --job-name=t2_srun --ntasks=4 --cpus-per-task=2 --time=00:02:00 \
    --output="$out" \
    --wrap='srun -n4 bash -c "echo task ProcID=\$SLURM_PROCID Step=\$SLURM_STEP_ID PID=\$\$"' \
    | awk '{print $4}')

  log "  Submitted job $jid"
  wait_job "$jid" 30

  local got
  got=$(grep -c "ProcID=" "$out" 2>/dev/null || echo 0)
  if (( got == 4 )); then
    pass "T2: 4 srun tasks ran with ProcID 0-3"
  else
    fail "T2: expected 4 ProcID lines, got $got"
    cat "$out" 2>/dev/null
  fi
  echo ""
}

# ── Test 3: Multi-partition submission ───────────────────────────────────────
run_test3() {
  log "Test 3: Submit one job to each partition"
  declare -A jids
  for part in batch debug fast long; do
    local jid
    jid=$(sbatch -p $part --job-name=t3_${part} --ntasks=1 --time=00:01:00 \
      --output="$OUTDIR/t3_${part}.out" \
      --wrap="echo 'part=\$SLURM_JOB_PARTITION job=\$SLURM_JOB_ID'; sleep 3" \
      | awk '{print $4}')
    jids[$part]=$jid
    log "  Submitted $jid → $part"
  done

  log "  Queue snapshot:"
  squeue -o "%.7i %.10P %.12j %.2t %.10M %R"

  # Wait for all to finish
  for part in batch debug fast long; do
    wait_job "${jids[$part]}" 60
  done

  # Verify each output
  local ok=0
  for part in batch debug fast long; do
    grep -q "part=$part" "$OUTDIR/t3_${part}.out" 2>/dev/null && (( ok++ )) || true
  done
  (( ok == 4 )) && pass "T3: All 4 partitions ran jobs" || fail "T3: Only $ok/4 partitions ran"
  echo ""
}

# ── Test 4: Job array ─────────────────────────────────────────────────────────
run_test4() {
  log "Test 4: Job array (5 tasks, SLURM_ARRAY_TASK_ID 1-5)"
  local jid
  jid=$(sbatch -p batch --array=1-5 --job-name=t4_array --time=00:01:00 \
    --output="$OUTDIR/t4_array_%A_%a.out" \
    --wrap='echo "array=$SLURM_ARRAY_JOB_ID task=$SLURM_ARRAY_TASK_ID"' \
    | awk '{print $4}')

  log "  Array job $jid submitted"
  # Arrays run sequentially on 1 node — wait up to 60s
  wait_job "${jid}_5" 60 || wait_job "$jid" 60 || sleep 10

  local got
  got=$(cat "$OUTDIR"/t4_array_*.out 2>/dev/null | grep -c "task=" || echo 0)
  (( got == 5 )) && pass "T4: All 5 array tasks ran (SLURM_ARRAY_TASK_ID 1-5)" \
                 || fail "T4: Expected 5 array tasks, got $got"
  cat "$OUTDIR"/t4_array_*.out 2>/dev/null | sort -t= -k3 -n
  echo ""
}

# ── Test 5: Job dependency (afterok) ─────────────────────────────────────────
run_test5() {
  log "Test 5: --dependency=afterok (child runs after parent succeeds)"
  local j1 j2
  j1=$(sbatch -p fast --time=00:01:00 --job-name=t5_parent \
    --output="$OUTDIR/t5_parent.out" \
    --wrap='echo "parent=$SLURM_JOB_ID done at $(date +%s)"' | awk '{print $4}')

  j2=$(sbatch -p fast --time=00:01:00 --dependency=afterok:$j1 --job-name=t5_child \
    --output="$OUTDIR/t5_child.out" \
    --wrap='echo "child=$SLURM_JOB_ID ran after $SLURM_JOB_DEPENDENCY at $(date +%s)"' | awk '{print $4}')

  log "  Parent=$j1  Child=$j2 (afterok:$j1)"
  squeue --priority -o "%.7i %.10P %.12j %.2t %R" | head -5
  wait_job "$j1" 30 && wait_job "$j2" 30

  local pt ct
  pt=$(grep -o 'done at [0-9]*' "$OUTDIR/t5_parent.out" 2>/dev/null | awk '{print $3}' || echo 0)
  ct=$(grep -o 'at [0-9]*' "$OUTDIR/t5_child.out" 2>/dev/null | tail -1 | awk '{print $2}' || echo 0)

  if grep -q "parent=$j1" "$OUTDIR/t5_parent.out" 2>/dev/null && \
     grep -q "child=$j2" "$OUTDIR/t5_child.out" 2>/dev/null; then
    pass "T5: Dependency chain executed (parent $j1 → child $j2)"
    [[ -n "$pt" && -n "$ct" && "$ct" -ge "$pt" ]] 2>/dev/null && log "  Child started after parent (epoch $pt → $ct)"
  else
    fail "T5: Dependency chain broken"
    cat "$OUTDIR/t5_parent.out" "$OUTDIR/t5_child.out" 2>/dev/null
  fi
  echo ""
}

# ── Test 6: scancel ───────────────────────────────────────────────────────────
run_test6() {
  log "Test 6: scancel removes job from queue"
  local jid
  jid=$(sbatch -p long --time=1:00:00 --job-name=t6_cancel \
    --output="$OUTDIR/t6_cancel.out" \
    --wrap='sleep 600' | awk '{print $4}')

  log "  Submitted long-running job $jid"
  sleep 1
  local pre_q
  pre_q=$(squeue --jobs="$jid" --noheader 2>/dev/null | wc -l)
  scancel "$jid"
  sleep 1
  local post_q
  post_q=$(squeue --jobs="$jid" --noheader 2>/dev/null | wc -l)

  (( pre_q > 0 && post_q == 0 )) && pass "T6: Job $jid appeared then was cancelled" \
                                  || fail "T6: pre=$pre_q post=$post_q (expected 1→0)"
  echo ""
}

# ── Test 7: scontrol show node ────────────────────────────────────────────────
run_test7() {
  log "Test 7: scontrol show node shows CPU/memory allocation"
  local node
  node=$(hostname -s)
  local out
  out=$(scontrol show node "$node")

  echo "$out" | grep -E "State|CPUAlloc|CPUTot|RealMemory|Partitions"

  echo "$out" | grep -q "State=IDLE" && pass "T7: Node $node is IDLE" || \
  echo "$out" | grep -q "State=ALLOC" && pass "T7: Node $node is ALLOCATED (jobs running)" || \
  fail "T7: Unexpected node state"
  echo ""
}

# ── Main ──────────────────────────────────────────────────────────────────────
check_slurm

run_test1
run_test2
run_test3
run_test4
run_test5
run_test6
run_test7

echo "════════════════════════════════════════"
echo "Results: PASS=$PASS  FAIL=$FAIL  ($(( PASS + FAIL )) tests)"
echo "Outputs: $OUTDIR"
echo "════════════════════════════════════════"
(( FAIL == 0 )) && echo "ALL TESTS PASSED ✓" || echo "SOME TESTS FAILED ✗"
