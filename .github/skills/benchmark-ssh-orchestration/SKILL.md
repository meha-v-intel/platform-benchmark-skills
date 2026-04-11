---
name: benchmark-ssh-orchestration
description: >
  Set up passwordless SSH between two benchmark systems, run remote commands
  non-interactively, and orchestrate server/client benchmark workloads (e.g.
  iperf3) across multiple machines from a single control script.
  Use when: setting up multi-system benchmarks, running iperf3 server/client,
  coordinating remote command execution, parallel SSH execution, scripted
  multi-host testing.
applyTo: "**/*.sh"
---

# Benchmark SSH Orchestration

## Context

This skill teaches how to set up and use SSH for non-interactive benchmark
orchestration across two or more Linux systems. Patterns are derived from
production Node.js SSH automation (using the `ssh2` library) translated into
equivalent, simpler **bash idioms** suited for benchmark scripts.

The core insight from the rack-management reference implementation:
- **Non-interactive is mandatory** — never let a benchmark script block on
  a password prompt. Use key-based auth (preferred) or `sshpass`.
- **TOFU host key** — accept the key on first connect; don't fail with
  `StrictHostKeyChecking=yes` in a lab environment.
- **Collect stdout + stderr separately** and check exit codes.
- **Parallel execution** (equivalent to `Promise.all`) = bash background `&` + `wait`.
- **Sequential execution** = plain sequential SSH calls.
- **Timeouts** = wrap with `timeout <seconds> ssh ...`.

---

## Prerequisites

```bash
# Both systems must have:
which iperf3 ssh sshpass || dnf install -y iperf3 openssh-clients sshpass

# Verify ssh client version (must be >= 7.6 for modern key types)
ssh -V
```

---

## Phase 1 — SSH Key Setup (Preferred: No Password)

Run once from the **control system** (the one running the benchmark script):

```bash
# Generate an ed25519 key specifically for benchmarking
ssh-keygen -t ed25519 -f ~/.ssh/bench_key -N "" -C "bench"

# Copy public key to the remote system (enter password once)
ssh-copy-id -i ~/.ssh/bench_key.pub root@$REMOTE_HOST

# Create ~/.ssh/config entry so scripts don't need flags
cat >> ~/.ssh/config <<'EOF'

Host bench-remote
    HostName $REMOTE_HOST
    User root
    IdentityFile ~/.ssh/bench_key
    StrictHostKeyChecking accept-new
    ConnectTimeout 10
    ServerAliveInterval 30
    ServerAliveCountMax 3
EOF

# Verify passwordless login works
ssh bench-remote "hostname && date"
```

**Why `StrictHostKeyChecking=accept-new`** — trust on first use (TOFU),
same as the rack-management `createHostKeyVerifier()`. Rejects changed keys
(MITM protection) but never blocks on the first connection.

---

## Phase 2 — Bash `run_remote()` Helper

A reusable function that mirrors the rack-management `executeSSHCommand()`:
- Collects stdout + stderr separately
- Returns exit code
- Enforces a hard timeout

```bash
#!/usr/bin/env bash
# Source this or paste into benchmark scripts

REMOTE=bench-remote          # SSH config alias
TIMEOUT_CMD=30               # seconds per remote command

# run_remote <cmd> [timeout_seconds]
# Prints stdout; stderr goes to /tmp/ssh_stderr.txt
# Returns the remote exit code
run_remote() {
    local cmd="$1"
    local tmo="${2:-$TIMEOUT_CMD}"
    timeout "$tmo" ssh "$REMOTE" "$cmd" 2>/tmp/ssh_stderr.txt
    local rc=$?
    if [[ $rc -eq 124 ]]; then
        echo "ERROR: remote command timed out after ${tmo}s: $cmd" >&2
    fi
    return $rc
}

# run_remote_bg <cmd>  — fire-and-forget (parallel)
run_remote_bg() {
    ssh "$REMOTE" "$1" &
}
```

Usage:

```bash
OUT=$(run_remote "cat /proc/cpuinfo | grep 'model name' | head -1")
echo "Remote CPU: $OUT"
```

---

## Phase 3 — Sequential Command Execution

Equivalent to the `runNext()` recursive pattern in the rack-management
`ssh2` implementation, translated to a simple loop:

```bash
# Sequential: each command waits for the previous to finish
declare -a SETUP_CMDS=(
    "modprobe ib_umad 2>/dev/null; true"
    "ethtool -G \$IFACE_B rx 8192 tx 8192"
    "ip link set \$IFACE_B mtu 9000"
    "sysctl -w net.core.rmem_max=536870912"
    "sysctl -w net.ipv4.tcp_rmem='4096 87380 536870912'"
)

for cmd in "${SETUP_CMDS[@]}"; do
    echo "Remote: $cmd"
    run_remote "$cmd" || { echo "FAILED: $cmd"; exit 1; }
done
```

---

## Phase 4 — Parallel Execution (Promise.all Equivalent)

Equivalent to `Promise.all(systems.map(s => executeSSHCommand(s, ...)))`.
Use background processes `&` and `wait`:

```bash
# Apply sysctl tuning on BOTH systems simultaneously
sysctl -w net.core.rmem_max=536870912 &    # local (this system)
run_remote_bg "sysctl -w net.core.rmem_max=536870912"  # remote
wait   # wait for both to finish
echo "Tuning applied on both systems."
```

With output capture (each job writes to a temp file):

```bash
run_parallel() {
    local label="$1"; shift
    local cmd="$@"
    $cmd > "/tmp/par_${label}.out" 2>&1 &
    echo $!   # return PID for later wait
}

PID_LOCAL=$(run_parallel  local  "iperf3 -c $IP_B0 -p 5201 -t 30 --json")
PID_REMOTE=$(run_parallel remote "ssh $REMOTE iperf3 -c $IP_A0 -p 5211 -t 30 --json")
wait $PID_LOCAL $PID_REMOTE
cat /tmp/par_local.out | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['end']['sum_sent']['bits_per_second']/1e9, 'Gbps TX')"
```

---

## Phase 5 — Server/Client Coordination Pattern

The critical pattern for iperf3: start the **server** on one host, wait
briefly for it to be ready, then run the **client** on the other host.

### Option A — Server on the Remote Host (most common)

```bash
# 1. Kill any stale server
run_remote "pkill -x iperf3 2>/dev/null; true"
sleep 1

# 2. Start iperf3 server on remote in background
run_remote "nohup iperf3 -s -p 5201 --one-off > /tmp/iperf3_server.log 2>&1 &"

# 3. Wait for server to be ready (check port is open)
for i in $(seq 1 10); do
    run_remote "ss -tlnp | grep -q ':5201'" && break
    sleep 0.5
done

# 4. Run client locally
iperf3 -c "$REMOTE_IP" -p 5201 -t 30 -P 8 --json | tee /tmp/iperf3_result.json

# 5. Cleanup server
run_remote "pkill -x iperf3 2>/dev/null; true"
```

### Option B — Server on This Host, Client on Remote

```bash
# 1. Start local server
pkill -x iperf3 2>/dev/null; sleep 0.5
iperf3 -s -p 5201 -D   # -D = daemon mode

# 2. Wait for local port
for i in $(seq 1 10); do
    ss -tlnp | grep -q ':5201' && break
    sleep 0.5
done

# 3. Run client from remote
run_remote "iperf3 -c $LOCAL_IP -p 5201 -t 30 -P 8 --json" | tee /tmp/iperf3_result.json

# 4. Kill local server
pkill -x iperf3 2>/dev/null
```

### Option C — Full Bidirectional Test (Two Parallel iperf3 Streams)

```bash
# Server A → B (remote runs client): run in background
run_remote "iperf3 -c $IP_A0 -p 5201 -t 30 -P 8 --json" \
    > /tmp/iperf3_AtoB.json &
PID_AtoB=$!

# Server B → A (local runs client): run in background  
iperf3 -c "$REMOTE_IP_0" -p 5211 -t 30 -P 8 --json \
    > /tmp/iperf3_BtoA.json &
PID_BtoA=$!

wait $PID_AtoB $PID_BtoA

# Parse results
parse_gbps() { python3 -c "import json,sys; d=json.load(open('$1')); print(round(d['end']['sum_sent']['bits_per_second']/1e9,2))" 2>/dev/null || echo "N/A"; }
echo "A→B: $(parse_gbps /tmp/iperf3_AtoB.json) Gbps"
echo "B→A: $(parse_gbps /tmp/iperf3_BtoA.json) Gbps"
```

---

## Phase 6 — sshpass Fallback (Password Auth Without Keys)

If key setup is not yet done and password auth must be used:

```bash
# Install sshpass (available in EPEL / standard repos)
dnf install -y sshpass

# Set password via environment variable (never embed in scripts)
export BENCH_PASS="your_password_here"

# Define REMOTE using sshpass wrapper
ssh_pw() {
    sshpass -e ssh \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=~/.ssh/known_hosts \
        -o ConnectTimeout=10 \
        root@"$REMOTE_HOST" "$@"
}
# SSHPASS env var = sshpass -e reads from it (avoids command-line exposure)
export SSHPASS="$BENCH_PASS"

ssh_pw "hostname && uname -r"
```

> **Security note**: Key-based auth is always preferred. Use `sshpass` only
> for initial setup before keys are deployed. Never hardcode passwords.

---

## Phase 7 — Verify & Troubleshoot

```bash
# Test connectivity (equivalent to testNetworkConnection in rack-management)
nc -z -w 5 "$REMOTE_HOST" 22 && echo "SSH port reachable" || echo "UNREACHABLE"

# Test authentication (equivalent to testSSHWithSSH2Enhanced)
ssh -o BatchMode=yes -o ConnectTimeout=10 bench-remote "echo OK" \
    && echo "Auth OK" || echo "Auth FAILED"

# Debug algorithm negotiation (from SSH-Connection-Guide.md)
ssh -vvv bench-remote "hostname" 2>&1 | grep -E "kex|cipher|hmac|host key"

# Check modern algorithm support on remote (from SSH-Connection-Guide.md)
ssh bench-remote "ssh -Q kex localhost"    # supported kex algorithms
ssh bench-remote "ssh -Q cipher localhost" # supported ciphers
```

**Common errors** (from rack-management error mapping):

| Error | Code | Fix |
|-------|------|-----|
| `Connection refused` | `CONN_REFUSED` | sshd not running: `systemctl start sshd` |
| `All auth methods failed` | `AUTH_FAILED` | Wrong key/pass, or `PasswordAuthentication no` in sshd_config |
| `no matching kex algorithm` | `ALGORITHM_MISMATCH` | Old OpenSSH; add `KexAlgorithms +diffie-hellman-group14-sha1` on server |
| `Host key mismatch` | - | System reinstalled; `ssh-keygen -R $REMOTE_HOST` |
| Hangs forever | `TIMEOUT` | Use `timeout 15 ssh ...` or set `ConnectTimeout=10` |

---

## Complete Bootstrap Script

Copy this to quickly set up two-system SSH for any benchmark:

```bash
#!/usr/bin/env bash
# Usage: bash ssh-setup.sh <remote_ip> [remote_user]
set -euo pipefail

REMOTE_IP="${1:?Usage: $0 <remote_ip> [user]}"
REMOTE_USER="${2:-root}"
KEY_FILE="$HOME/.ssh/bench_key"
CONFIG="$HOME/.ssh/config"

echo "=== Setting up benchmark SSH to $REMOTE_USER@$REMOTE_IP ==="

# Generate key if needed
if [[ ! -f "$KEY_FILE" ]]; then
    ssh-keygen -t ed25519 -f "$KEY_FILE" -N "" -C "bench-$(hostname)-$(date +%Y%m%d)"
    echo "Generated $KEY_FILE"
fi

# Add config block (idempotent)
if ! grep -q "Host bench-remote" "$CONFIG" 2>/dev/null; then
    mkdir -p ~/.ssh && chmod 700 ~/.ssh
    cat >> "$CONFIG" <<EOF

Host bench-remote
    HostName $REMOTE_IP
    User $REMOTE_USER
    IdentityFile $KEY_FILE
    StrictHostKeyChecking accept-new
    ConnectTimeout 10
    ServerAliveInterval 30
    ServerAliveCountMax 3
EOF
    chmod 600 "$CONFIG"
    echo "Added SSH config block"
fi

# Install public key on remote (will prompt for password once)
ssh-copy-id -i "${KEY_FILE}.pub" "${REMOTE_USER}@${REMOTE_IP}"

# Verify
ssh bench-remote "hostname && uname -r && ip addr show | grep 'inet ' | awk '{print \$2}'"
echo "=== SSH setup complete ==="
```

---

## Key Takeaways from rack-management Source Code

| Node.js Pattern | Bash Equivalent |
|----------------|----------------|
| `executeSSHCommand(host, user, pass, cmd)` | `ssh user@host "cmd"` (with key auth) |
| `conn.on('ready') → conn.exec(cmd)` | `ssh host "cmd"` (OpenSSH handles internally) |
| `stream.on('data') / stream.stderr.on('data')` | `OUT=$(ssh host "cmd" 2>/tmp/err)` |
| `stream.on('close', code)` | `ssh host "cmd"; echo $?` |
| `setTimeout(..., 30000)` (30s timeout) | `timeout 30 ssh host "cmd"` |
| `readyTimeout: 10000` (10s connect) | `ConnectTimeout=10` in ssh config |
| `tryKeyboard: true` (PAM/MFA) | `ssh -o KbdInteractiveAuthentication=yes` |
| TOFU `hostVerifier: callback(true)` | `StrictHostKeyChecking=accept-new` |
| `Promise.all(systems.map(exec))` | `ssh h1 "cmd" & ssh h2 "cmd" & wait` |
| `runNext()` recursive chain | Sequential `for cmd in ${CMDS[@]}; do ssh...` |
| `knownHosts[hostname] = fingerprint` | `~/.ssh/known_hosts` (automatic) |
| `algorithms: { kex: ['curve25519-sha256'...] }` | Default OpenSSH ≥7.6 (no config needed) |
