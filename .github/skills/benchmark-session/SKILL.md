---
name: benchmark-session
description: "Benchmark session manager — reuse or create benchmark run sets. Use when: checking for existing benchmark runs, reusing a previous benchmark configuration, saving a benchmark session, finding a matching prior run, deduplicating benchmark requests, comparing to historical results, managing benchmark history."
argument-hint: "[check|save|list] [--intent <text>] [--platform <id>] [--session-id <id>] [--benchmarks <list>]"
allowed-tools: Bash
---

# Benchmark Session Manager

Manages benchmark session records in `./sessions/`.
Each session record stores the intent, platform, benchmark set, and summary results.
On every new request, existing sessions are checked first — reuse is always preferred.

## Session Storage Layout

```
./sessions/
  <hash>.json          ← one file per unique (intent + platform) combination
./results/
  <session-id>/        ← raw results, emon data, sysconfig for each run
    bench/
    emon/
    sysconfig.json
```

## Session Record Schema

```json
{
  "session_id":    "20260405T120000-a3f9c1",
  "created_at":   "2026-04-05T12:00:00Z",
  "intent":       "validate platform for 3-tier banking workload",
  "intent_hash":  "a3f9c1d2e4...",
  "platform_id":  "a3f9c1d2e4f5",
  "platform_desc":"Intel DMR 2S×32C, CentOS Stream 10",
  "benchmarks":   ["preflight", "cpu", "memory"],
  "results_path": "./results/20260405T120000-a3f9c1/",
  "summary": {
    "preflight": "PASS",
    "cpu":       "PASS — max_freq: 2799 MHz, c2c: 142 cycles",
    "memory":    "PASS — latency: 121 ns, bw: 1510 GBps"
  },
  "verdict": "PASS"
}
```

---

## Step 1 — Ensure Sessions Directory

```bash
mkdir -p ./sessions
```

---

## `check` — Find Matching Session

Argument: `check --intent "<text>" --platform "<platform_id>"`

```python
import json, hashlib, os, glob, difflib, sys

def hash_intent(intent: str) -> str:
    # Normalize: lowercase, collapse whitespace, strip punctuation
    import re
    normalized = re.sub(r'[^\w\s]', '', intent.lower())
    normalized = re.sub(r'\s+', ' ', normalized).strip()
    return hashlib.sha256(normalized.encode()).hexdigest()[:16]

intent      = os.environ.get('USER_INTENT', '')
platform_id = os.environ.get('PLATFORM_ID', '')
intent_hash = hash_intent(intent)

sessions = []
for path in glob.glob('./sessions/*.json'):
    try:
        s = json.load(open(path))
        sessions.append(s)
    except Exception:
        pass

# Exact match: same intent hash + platform
exact = [s for s in sessions
         if s.get('intent_hash') == intent_hash
         and s.get('platform_id') == platform_id]

# Fuzzy match: same platform, similar intent (≥70% similarity)
fuzzy = [s for s in sessions
         if s.get('platform_id') == platform_id
         and s not in exact
         and difflib.SequenceMatcher(
               None, intent.lower(), s.get('intent','').lower()
           ).ratio() >= 0.70]

if exact:
    s = exact[0]
    print(f"MATCH=exact")
    print(f"SESSION_ID={s['session_id']}")
    print(f"\nFound EXACT match from {s['created_at'][:10]}:")
    print(f"  Intent    : {s['intent']}")
    print(f"  Platform  : {s['platform_desc']}")
    print(f"  Benchmarks: {', '.join(s['benchmarks'])}")
    print(f"  Verdict   : {s['verdict']}")
    print(f"  Results   : {s['results_path']}")
    print(f"\nSummary:")
    for k, v in s.get('summary', {}).items():
        print(f"  {k:<12}: {v}")
elif fuzzy:
    s = fuzzy[0]
    ratio = difflib.SequenceMatcher(None, intent.lower(), s['intent'].lower()).ratio()
    print(f"MATCH=fuzzy  ({ratio:.0%} similar)")
    print(f"SESSION_ID={s['session_id']}")
    print(f"\nFound SIMILAR session from {s['created_at'][:10]}:")
    print(f"  Stored intent : {s['intent']}")
    print(f"  Your intent   : {intent}")
    print(f"  Platform      : {s['platform_desc']}")
    print(f"  Benchmarks    : {', '.join(s['benchmarks'])}")
    print(f"  Verdict       : {s['verdict']}")
else:
    print(f"MATCH=none")
    print(f"No existing session found for this intent on platform {platform_id}.")
```

**After running the check, always ask the user:**

- If `MATCH=exact`:
  > *"I found a previous run from [date] matching this request. Results: [summary]. Would you like to: (1) Reuse these results, (2) Re-run the same benchmark set, or (3) Start fresh with a new configuration?"*

- If `MATCH=fuzzy`:
  > *"I found a similar previous run ([X]% match) from [date]. Would you like to: (1) Reuse it, (2) Extend/modify it, or (3) Start fresh?"*

- If `MATCH=none`:
  > *"No previous run found. I'll run: [benchmark list]. Shall I proceed?"*

**Always wait for explicit user confirmation before executing.**

---

## `save` — Save Session Record After Run

Argument: `save --session-id <id> --intent <text> --platform <id> --benchmarks <list>`

```python
import json, hashlib, os, re, datetime, glob

def hash_intent(intent: str) -> str:
    normalized = re.sub(r'[^\w\s]', '', intent.lower())
    normalized = re.sub(r'\s+', ' ', normalized).strip()
    return hashlib.sha256(normalized.encode()).hexdigest()[:16]

session_id  = os.environ['SESSION_ID']
intent      = os.environ['USER_INTENT']
platform_id = os.environ['PLATFORM_ID']
benchmarks  = os.environ.get('BENCHMARK_SET', '').split(',')

# Load sysconfig for platform description
sysconfig_path = f'./results/{session_id}/sysconfig.json'
platform_desc  = 'unknown'
if os.path.exists(sysconfig_path):
    sc = json.load(open(sysconfig_path))
    cpu = sc.get('cpu', {})
    platform_desc = f"{cpu.get('model','?')} {cpu.get('logical_cpus','?')}C"

# Parse summary results from bench logs
summary = {}
bench_dir = f'./results/{session_id}/bench'
verdict_votes = []
for bname in benchmarks:
    log = f'{bench_dir}/{bname}.log'
    if os.path.exists(log):
        text = open(log).read()
        pass_m = re.search(r'(PASS|FAIL)', text)
        status = pass_m.group(1) if pass_m else 'UNKNOWN'
        # Grab first KPI line after status
        kpi_m = re.search(r'(PASS|FAIL)\s+.*?—\s*(.+)', text)
        detail = kpi_m.group(2)[:80] if kpi_m else ''
        summary[bname] = f"{status}" + (f" — {detail}" if detail else '')
        verdict_votes.append(status)

verdict = 'PASS' if all(v == 'PASS' for v in verdict_votes) and verdict_votes else 'FAIL'

record = {
    'session_id':    session_id,
    'created_at':    datetime.datetime.utcnow().isoformat() + 'Z',
    'intent':        intent,
    'intent_hash':   hash_intent(intent),
    'platform_id':   platform_id,
    'platform_desc': platform_desc,
    'benchmarks':    benchmarks,
    'results_path':  f'./results/{session_id}/',
    'summary':       summary,
    'verdict':       verdict,
}

os.makedirs('./sessions', exist_ok=True)
out_path = f"./sessions/{hash_intent(intent)}-{platform_id}.json"
with open(out_path, 'w') as f:
    json.dump(record, f, indent=2)

print(f"Session saved: {out_path}")
print(f"Verdict: {verdict}")
```

---

## `list` — List All Sessions

```bash
python3 - << 'EOF'
import json, glob, os

sessions = []
for path in sorted(glob.glob('./sessions/*.json'), reverse=True):
    try:
        s = json.load(open(path))
        sessions.append(s)
    except Exception:
        pass

if not sessions:
    print("No saved sessions found.")
else:
    print(f"{'Date':<12} {'Platform':<20} {'Benchmarks':<30} {'Verdict':<8} Intent")
    print('-' * 110)
    for s in sessions:
        date  = s.get('created_at','')[:10]
        plat  = s.get('platform_desc','?')[:20]
        bench = ', '.join(s.get('benchmarks',[]))[:30]
        verd  = s.get('verdict','?')
        intnt = s.get('intent','?')[:50]
        print(f"{date:<12} {plat:<20} {bench:<30} {verd:<8} {intnt}")
EOF
```
