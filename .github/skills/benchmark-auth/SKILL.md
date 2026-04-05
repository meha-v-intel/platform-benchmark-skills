---
name: benchmark-auth
description: "SSH authentication setup for remote benchmark execution. Use when: connecting to a remote server, setting up SSH access, using an identity file, doing key exchange, entering a password, configuring a jump host, verifying SSH connectivity to a lab machine, establishing passwordless SSH."
argument-hint: "[--host <host>] [--user <user>] [--alias <alias>] [--identity-file <path>] [--jump-host <host>]"
allowed-tools: Bash
---

# Benchmark SSH Authentication

Establishes SSH connectivity to the remote benchmark target.
Tries authentication modes in order — stops at first success.

## Variables Exported by This Skill

| Variable | Description | Example |
|---|---|---|
| `$LAB_HOST` | SSH alias used for all subsequent commands | `lab-target` |
| `$SSH_CMD` | SSH command prefix (plain `ssh` or `sshpass -e ssh`) | `ssh` |
| `$SCP_CMD` | SCP command prefix (plain `scp` or `sshpass -e scp`) | `scp` |

## Step 1 — Parse Arguments

Extract from `$ARGUMENTS`:
- `--host`          → `TARGET_HOST` (required)
- `--user`          → `TARGET_USER` (default: `$USER`)
- `--alias`         → `TARGET_ALIAS` (default: `lab-target`)
- `--identity-file` → `IDENTITY_FILE`
- `--jump-host`     → `JUMP_HOST`

If `--host` is missing, ask the user: *"What is the IP or hostname of the remote benchmark machine?"*

## Step 2 — Mode A: Existing ~/.ssh/config Entry

```bash
if grep -qE "Host\s+(${TARGET_ALIAS}|${TARGET_HOST})" ~/.ssh/config 2>/dev/null; then
    echo "Found existing SSH config entry for ${TARGET_ALIAS} — testing..."
    ssh -o BatchMode=yes -o ConnectTimeout=10 ${TARGET_ALIAS} "echo SSH_OK && uname -r && nproc"
    if [ $? -eq 0 ]; then
        export LAB_HOST=${TARGET_ALIAS}
        export SSH_CMD="ssh"
        export SCP_CMD="scp"
        echo "MODE=A (existing config)"
    fi
fi
```

## Step 3 — Mode B: Identity File

```bash
if [ -n "${IDENTITY_FILE}" ] && [ -f "${IDENTITY_FILE}" ]; then
    echo "Testing identity file ${IDENTITY_FILE}..."
    PROXY_OPT=""
    [ -n "${JUMP_HOST}" ] && PROXY_OPT="-o ProxyJump=${JUMP_HOST}"
    ssh -o BatchMode=yes -o ConnectTimeout=10 \
        -i "${IDENTITY_FILE}" ${PROXY_OPT} \
        ${TARGET_USER}@${TARGET_HOST} "echo SSH_OK"
    if [ $? -eq 0 ]; then
        # Write a config entry so subsequent commands use the alias
        cat >> ~/.ssh/config << EOF

Host ${TARGET_ALIAS}
  HostName ${TARGET_HOST}
  User ${TARGET_USER}
  IdentityFile ${IDENTITY_FILE}
  $([ -n "${JUMP_HOST}" ] && echo "  ProxyJump ${JUMP_HOST}")
  ServerAliveInterval 60
  ServerAliveCountMax 10
EOF
        export LAB_HOST=${TARGET_ALIAS}
        export SSH_CMD="ssh"
        export SCP_CMD="scp"
        echo "MODE=B (identity file)"
    fi
fi
```

## Step 4 — Mode C: Key Exchange (One-Time Passwordless Setup)

Offer this if Modes A and B did not succeed and no password was provided:

```bash
echo "No existing key found. Setting up passwordless SSH (you will enter your password ONCE)."

# Generate key if missing
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""

# Accept host fingerprints non-interactively
ssh-keyscan -H ${TARGET_HOST} >> ~/.ssh/known_hosts 2>/dev/null
[ -n "${JUMP_HOST}" ] && ssh-keyscan -H ${JUMP_HOST} >> ~/.ssh/known_hosts 2>/dev/null

# Copy public key — user enters password once here
PROXY_OPT=""
[ -n "${JUMP_HOST}" ] && PROXY_OPT="-o ProxyJump=${JUMP_HOST}"
ssh-copy-id -i ~/.ssh/id_ed25519.pub ${PROXY_OPT} ${TARGET_USER}@${TARGET_HOST}

# Write ~/.ssh/config entry
cat >> ~/.ssh/config << EOF

Host ${TARGET_ALIAS}
  HostName ${TARGET_HOST}
  User ${TARGET_USER}
  IdentityFile ~/.ssh/id_ed25519
  $([ -n "${JUMP_HOST}" ] && echo "  ProxyJump ${JUMP_HOST}")
  ServerAliveInterval 60
  ServerAliveCountMax 10
EOF
export LAB_HOST=${TARGET_ALIAS}
export SSH_CMD="ssh"
export SCP_CMD="scp"
echo "MODE=C (key exchange complete)"
```

## Step 5 — Mode D: Password Per Session (Fallback)

Use only if user explicitly provides a password and key setup is not possible.
**Password is stored in an environment variable only — never written to disk.**

```bash
# Install sshpass if needed
which sshpass 2>/dev/null || dnf install -y sshpass 2>/dev/null

# Prompt for password if not already in env
if [ -z "${SSHPASS}" ]; then
    echo -n "Enter SSH password for ${TARGET_USER}@${TARGET_HOST}: "
    read -s SSHPASS
    echo
    export SSHPASS
fi

# Accept host fingerprint
ssh-keyscan -H ${TARGET_HOST} >> ~/.ssh/known_hosts 2>/dev/null

# Test
sshpass -e ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    ${TARGET_USER}@${TARGET_HOST} "echo SSH_OK"
if [ $? -eq 0 ]; then
    export LAB_HOST="${TARGET_USER}@${TARGET_HOST}"
    export SSH_CMD="sshpass -e ssh"
    export SCP_CMD="sshpass -e scp"
    echo "MODE=D (password per session — key exchange recommended for future runs)"
fi
```

## Step 6 — Verification

```bash
${SSH_CMD} ${LAB_HOST} "echo SSH_OK && uname -r && nproc && whoami && hostname"
```

Report:
```
AUTH RESULT
===========
Mode     : <A/B/C/D> — <existing config / identity file / key exchange / password>
Target   : <user>@<host>
Alias    : <LAB_HOST value>
Status   : SUCCESS / FAILED
Kernel   : <uname -r>
vCPUs    : <nproc>
User     : <whoami>
```

- **SUCCESS** → export `LAB_HOST`, `SSH_CMD`, `SCP_CMD`; proceed to `benchmark-system-config`.
- **FAILED** → report full error output, do not proceed. Suggest: check firewall, VPN, credentials.
