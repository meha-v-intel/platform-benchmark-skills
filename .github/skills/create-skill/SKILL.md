---
name: create-skill
description: "**META SKILL** — Create, design, and write SKILL.md documentation files for GitHub Copilot or Claude Code agent customization. Use when: writing a new skill, designing skill frontmatter, deciding skill structure, learning how to write skills, turning a domain workflow into a skill, creating benchmark skills, creating task automation skills, creating reference skills, packaging domain knowledge as a skill, teaching an agent a repeatable workflow."
argument-hint: "[benchmark|task|reference|all] [<skill-name>]"
allowed-tools: Bash
---

# How to Create a SKILL.md for GitHub Copilot / Claude Code

This skill teaches how to write high-quality `SKILL.md` files — based on the
Agent Skills open standard (agentskills.io) and lessons from building 10+ real
benchmark skills for Intel DMR storage segment validation.

Argument: `$ARGUMENTS` — optionally specify a skill type (`benchmark`, `task`, `reference`)
and/or a specific skill name to create.

---

## 1. What Is a Skill?

A skill is a `SKILL.md` file that packages domain knowledge, workflows, or
procedural steps so an agent can invoke them consistently.

**Three skill types:**

| Type | Purpose | `disable-model-invocation` | Example |
|---|---|---|---|
| **Reference** | Background knowledge, conventions, style guides | `false` (auto-load) | `api-conventions`, `storage-mlc` |
| **Task** | Step-by-step workflow with side effects | `true` (manual only) | `deploy`, `write-skill-doc` |
| **Benchmark** | Executable commands + baselines + thresholds | `false` (auto-load by domain) | `storage-encryption`, `storage-minio` |

**Where skills live:**

| Path | Scope |
|---|---|
| `.github/skills/<name>/SKILL.md` | Project / repo (team-shared via git) |
| `~/.claude/skills/<name>/SKILL.md` | Personal (all projects, Claude Code) |
| `.claude/skills/<name>/SKILL.md` | Project-level (Claude Code) |

---

## 2. The Anatomy of SKILL.md

Every skill has two parts: **YAML frontmatter** and **markdown body**.

```
---
name: my-skill
description: "What it does and when to use it. Use when: ..."
argument-hint: "[option1|option2|all]"
allowed-tools: Bash
---

# Skill Title

Body content — instructions, commands, tables, examples.
```

### 2.1 Frontmatter Fields

| Field | Required | Guidance |
|---|---|---|
| `name` | Recommended | Lowercase, hyphens, max 64 chars. Becomes the `/slash-command`. Omit to use the directory name. |
| `description` | **Critical** | The agent's discovery surface. If your trigger phrases aren't here, the agent won't find it. Descriptions >250 chars are truncated in listings — front-load the primary use case. |
| `argument-hint` | Recommended | Shows during `/skill-name` autocomplete. Format: `[option1|option2]` or `<required-arg>`. |
| `allowed-tools` | Situational | Space-separated tools the agent may use without approval. Use `Bash` for executable skills, `Read Grep` for read-only exploration. |
| `disable-model-invocation` | Situational | `true` = only you can invoke (use for deploys, commits, anything with side effects). |
| `user-invocable` | Rare | `false` = background knowledge users shouldn't trigger directly. |
| `context` | Advanced | `fork` = run in isolated subagent (no conversation history). |
| `agent` | Advanced | Which subagent type: `Explore`, `Plan`, `general-purpose`, or a custom agent name. |

### 2.2 Writing the Description

The `description` field is the single most important thing to get right.

**Pattern that works:**
```yaml
description: "Run X benchmark for Y validation. Use when: measuring X throughput,
  benchmarking Y capacity, validating Z hardware, sizing W workloads."
```

**Rules:**
- Quote the value if it contains colons (otherwise YAML breaks silently)
- Front-load the primary keyword — agent scans left-to-right
- Include synonyms and related contexts: "when measuring... when benchmarking... when validating..."
- Keep it under 250 chars for the summary view; put detail in the body

**Anti-pattern:**
```yaml
description: Benchmark skill   # Too vague — never auto-loaded
```

---

## 3. String Substitutions

Use these in the body to inject dynamic content:

| Syntax | What it injects |
|---|---|
| `$ARGUMENTS` | All arguments passed after `/skill-name` |
| `$ARGUMENTS[0]`, `$0` | First argument (0-indexed) |
| `$ARGUMENTS[1]`, `$1` | Second argument |
| `` !`command` `` | Output of a shell command — runs at skill load time, before the agent sees anything |
| `${CLAUDE_SESSION_ID}` | Current session ID (for log files, unique directories) |
| `${CLAUDE_SKILL_DIR}` | Absolute path to the skill's directory (reference bundled scripts) |

**Dynamic context injection example** — inject live system info at load time:
```markdown
## System Context (captured at skill load)
- CPU cores: !`nproc`
- Kernel: !`uname -r`
- Free disk: !`df -h / | tail -1 | awk '{print $4}'`
```

---

## 4. Skill Structure by Type

### 4.1 Reference Skill

Packages domain knowledge the agent needs to make good decisions. Auto-loaded
when the topic comes up.

```markdown
---
name: storage-conventions
description: "Storage benchmarking conventions and result interpretation. Use when:
  analyzing IOPS results, interpreting latency numbers, sizing storage capacity."
---

# Storage Benchmarking Conventions

## IOPS Interpretation

| Value | Meaning |
|---|---|
| < 100K | Typical spinning disk or network-limited |
| 100K–500K | SSD (SATA/NVMe Gen3) |
| > 500K | NVMe Gen4/Gen5 — confirm raw block device |

## Latency Thresholds
...
```

### 4.2 Task Skill (manual-only)

A workflow you invoke deliberately. `disable-model-invocation: true` prevents
the agent from running it automatically.

```markdown
---
name: commit-benchmark
description: Record benchmark results and commit to git. Use when: saving benchmark
  output, recording test results, creating a benchmark commit.
disable-model-invocation: true
argument-hint: "<test-name> [<branch>]"
allowed-tools: Bash
---

# Commit Benchmark Results

1. Collect results from `$ARGUMENTS[0]`:
   ```bash
   cat /tmp/${ARGUMENTS[0]}_results.txt
   ```
2. Verify no errors in output
3. Commit:
   ```bash
   git add results/ && git commit -m "bench($ARGUMENTS[0]): add results"
   ```
```

### 4.3 Benchmark / Executable Skill

The most complex type. Covers a spec or domain benchmark with:
- Prerequisite verification
- Configurable variables
- Grouped command sets matching spec subtest structure
- Live-measured baselines
- Pass/fail thresholds derived from baselines
- EMON/PMU side-collection section
- Troubleshooting

**Template: Benchmark Skill Structure**

```markdown
---
name: <domain>-<tool>
description: "Run <tool> benchmark for <spec> validation. Use when: measuring
  <metric1>, benchmarking <metric2>, validating <hardware>, sizing <workload>."
argument-hint: "[group-a|group-b|all]"
allowed-tools: Bash
---

# <Tool> — <Spec Name> — Test <ID>

One-paragraph description of what this benchmark measures and why it matters
for the storage/compute/network domain.

**Scope:** N subtests covering <dimensions>.
**Spec subtests:** <reference to the subtest table>

---

## Platform Notes (<system name>, this system)

```
Device/CPU : <spec>
OS         : <CentOS/RHEL version>
Tool ver   : <version installed>
Location   : <binary path>
```

---

## Variables

| Variable | Description | Example |
|---|---|---|
| `$OUTPUT_DIR` | Results directory | `/tmp/<tool>_results` |
| `$NPROC` | CPU core count | `32` |
| `$TOOL_PATH` | Binary location | `/usr/bin/<tool>` |

```bash
TOOL=${TOOL_PATH:-/usr/bin/<tool>}
OUT=${OUTPUT_DIR:-/tmp/<tool>_results}
mkdir -p $OUT
```

---

## Prerequisites

```bash
# Verify tool is installed
<tool> --version

# If not installed:
dnf install -y <package>   # or: go install ..., cargo build, cmake/make

# Verify hardware capability (if needed)
grep -m1 "flags" /proc/cpuinfo | grep -o "aes\|avx512\|sha_ni" | tr '\n' ' '
```

---

## EMON Collection (optional, simultaneous)

See the EMON section — start before Group A, stop after all groups.
Key events for this workload: <event1>, <event2>, <event3>.

---

## Group A — <Name> (<N> subtests)

**What it measures:** ...
**Why it matters:** ...

### A-1: <subtest name>

```bash
<command> 2>&1 | tee $OUT/<subtest>.txt
```

**DMR baseline:** `<value> <unit>` | **Pass threshold:** ≥ `<value>`

...

---

## Pass/Fail Thresholds

| Subtest | Baseline (DMR) | Threshold | Unit |
|---|---|---|---|
| A-1 | <value> | <70% of baseline> | <unit> |

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| <error> | <cause> | <fix> |

---

## Cleanup

```bash
# Stop any background processes started above
<cleanup commands>
```
```

---

## 5. Lessons Learned From Building 10 Benchmark Skills

These patterns emerged from building the Intel DMR storage segment validation
skill suite (`storage-mlc`, `storage-c2c`, `storage-encryption`, `storage-compression`,
`storage-erasure-coding`, `storage-hashing`, `storage-iperf3`, `storage-fio`,
`storage-fio-solo-dmr`, `storage-minio`) — 10 skills, ~5,400 lines total.

### 5.1 Structure Parallel to the Spec

Map skill groups directly to spec subtest groups. If the spec has subtests
109.001–109.003, call them Group A-1 through A-3 and document the mapping:

```markdown
| Subtest ID | Description | Skill Group |
|---|---|---|
| 109.001 | 4KiB rand write | A-1 |
| 109.002 | 4KiB rand read | A-2 |
```

This lets users quickly cross-reference skills against the spec sheet.

### 5.2 Always Capture Live Baselines

Before writing thresholds, run the commands on the actual target hardware. Record
the measured values in the skill with the system they came from. Never invent numbers.

```markdown
**DMR baseline (Micron 7450 Gen5×4, file-based, /tmp):**
- 4K randread QD32: 339,623 IOPS
- 128K seq write: 1,662 MB/s
```

Set pass thresholds at 60–80% of the measured baseline — this absorbs OS jitter,
background load, and non-ideal test file sizes without masking real regressions.

### 5.3 Always Verify Prerequisites First

The first section of every benchmark skill must be a runnable verification:

```bash
# Does the binary exist?
fio --version    # or: openssl version, mlc_internal --version

# Is the kernel module / hardware feature present?
grep -c "sha_ni" /proc/cpuinfo
```

If the prerequisite check fails, document the exact install command for this OS family.

### 5.4 Separate Solo-System from Full-System Variants

When a test has a "proper" configuration requiring dedicated hardware and a
"degraded" configuration possible on a solo dev machine:

- Create **two separate skills**: `tool-solo/SKILL.md` and `tool/SKILL.md`
- Document the gap factor clearly (e.g., "file-based results are 30–85% below raw block spec targets")
- Reference each other from the other's skill

Example: `storage-fio-solo-dmr` (OS boot disk, file-based) vs `storage-fio`
(dedicated NVMe, raw block).

### 5.5 EMON Integration Pattern

For CPU/memory/IO benchmark skills on Intel platforms, add an EMON section:

```markdown
## EMON Collection (run simultaneously with Group A)

**Start EMON before first group:**
```bash
EMON_EVENTS="cycles,instructions,cache-misses,LLC-load-misses,cpu-migrations"
perf stat -e $EMON_EVENTS -a --interval-print 1000 \
    -o $OUT/emon_perf.txt -- sleep 999 &
EMON_PID=$!
```

**Stop EMON after last group:**
```bash
kill $EMON_PID  # or: pkill -SIGINT perf
```

**Key interpretation rules:**
- `cpu-migrations > 0` → OS moved the process mid-benchmark → result is invalid
- `CPI > 2.5` → memory bound; look at `LLC-load-misses`
- `IPC < 1.0` for compute workload → check for thermal throttling
```

Add diagnostic notes mapping each PMU event to what it reveals about the workload.

### 5.6 Keep the Skill Under ~600 Lines

Beyond 600 lines the agent's attention degrades and context cost rises. Split large
skills using supporting files:

```
my-skill/
├── SKILL.md          # Overview, prerequisites, Groups A-C  (~400 lines)
├── reference.md      # Full spec subtest table + edge cases
└── examples/
    └── baseline.txt  # Example raw output for pass/fail comparison
```

Reference supporting files explicitly in SKILL.md:
```markdown
For the complete subtest mapping, see [reference.md](reference.md).
```

### 5.7 Argument-Hint Design

Use the argument-hint to communicate valid input clearly:

```yaml
# For group-based benchmark skills:
argument-hint: "[group-a|group-b|all]"

# For multi-parameter skills:
argument-hint: "[sweep|single <bytes>]"

# For skills with a mandatory argument:
argument-hint: "<test-name>"

# For object size + concurrency benchmark:
argument-hint: "[1kib|64kib|1mib|64mib|all] [put|get]"
```

### 5.8 Platform Notes Section

Every benchmark skill should have a Platform Notes section capturing the exact
system under test. This makes results reproducible and distinguishes "this is a
known baseline" from "this is a spec target":

```markdown
## Platform Notes (DMR, this system)

System  : 1S×32C×1T, 30GiB RAM, CentOS Stream 10, kernel 6.18.0-dmr.bkc
NVMe    : Micron 7450 MTFDKBG1T9TFR (Gen5×4, 1.92 TB)
Tool    : fio-3.36 (dnf install fio)
```

---

## 6. Common Pitfalls

| Pitfall | Symptom | Fix |
|---|---|---|
| Unquoted colons in YAML description | Skill silently fails to load | Quote the entire description: `description: "Use when: ..."` |
| Tabs instead of spaces in frontmatter | YAML parse error | Use spaces only in frontmatter |
| `name` doesn't match directory | Skill loads wrong or not at all | Directory name = skill name |
| Description too short/vague | Agent never auto-loads the skill | Add 3–5 concrete "Use when:" scenarios |
| Spec targets used as pass thresholds | Tests always FAIL on real hardware | Capture live baselines, set threshold at 65–70% |
| Single skill for all configs | Skill gets confusing and too long | Split by system configuration (solo vs cluster) |
| No prerequisite check | Confusing failures mid-benchmark | First section = verify binary + hardware |
| Output not saved to file | Results lost if terminal closes | Always: `command 2>&1 | tee $OUT/result.txt` |
| Missing cleanup section | Processes or test files left behind | Add a Cleanup section at the bottom |

---

## 7. Quick Creation Checklist

Use this checklist when creating a new skill:

```
Frontmatter
  [ ] name: lowercase-hyphens, matches directory name
  [ ] description: quoted, starts with use case, contains 3+ "Use when:" phrases
  [ ] argument-hint: reflects valid inputs
  [ ] allowed-tools: Bash (if skill runs commands)
  [ ] disable-model-invocation: true (if side effects / manual-only)

Body structure (benchmark skill)
  [ ] One-paragraph scope statement
  [ ] Platform Notes section with system spec
  [ ] Variables section with configurable paths
  [ ] Prerequisites section with binary verification + install command
  [ ] Groups A–N each mapping to spec subtest IDs
  [ ] Each command pipes to `tee $OUT/filename.txt`
  [ ] Live DMR/target baselines cited per group
  [ ] Pass/fail threshold table (≥65% of baseline)
  [ ] EMON/PMU section (if Intel platform performance workload)
  [ ] Troubleshooting table (3+ common failure modes)
  [ ] Cleanup section

Quality
  [ ] Total length < 600 lines (split to supporting files if longer)
  [ ] No invented baselines — all values live-measured
  [ ] Spec subtest IDs cross-referenced in group headers
  [ ] Eligibility note for any NOT ELIGIBLE subtests
```

---

## 8. Example: Creating a New Benchmark Skill End-to-End

Suppose you need to create a `storage-speccpu` skill for SPEC CPU 2017 (Test 103).

**Step 1 — Extract spec subtests from the sheet:**
```bash
python3 -c "
import openpyxl; wb = openpyxl.load_workbook('Storage_Segment_Validation_v0.5.xlsx', data_only=True)
ws = wb['1 Node StorageSegment Tests']
for row in ws.iter_rows(values_only=True):
    if row[0] and str(row[0]).startswith('103'):
        print('|'.join(str(c) if c else '' for c in row[:8]))
"
```

**Step 2 — Install and verify the tool:**
```bash
# Install, run a quick smoke test, capture one live baseline
speccpu2017 --version
```

**Step 3 — Write the SKILL.md:**
```bash
mkdir -p /root/.github/skills/storage-speccpu
# Create the file following the benchmark template above
```

**Step 4 — Commit to the skills branch:**
```bash
cd /root
git add .github/skills/storage-speccpu/SKILL.md
git commit -m "feat(storage-speccpu): add SpecCPU 2017 skill for Test 103"
git push origin storage-skills
```

**Step 5 — Update the checklist and analysis doc:**
- Mark Test 103 status as ✅ in `storage-skills-checklist.md`
- Update `storage-workload-analysis.md` summary table

---

## 9. Skill Type Decision Tree

```
Does the skill run shell commands?
├── YES → allowed-tools: Bash
│   ├── Does it have side effects (commit/deploy/send message)?
│   │   ├── YES → disable-model-invocation: true (manual only)
│   │   └── NO  → let agent auto-load by description
│   └── Does it need isolation from conversation history?
│       ├── YES → context: fork (subagent)
│       └── NO  → inline (default)
└── NO → Pure reference/knowledge skill
    ├── Should users invoke it as /command?
    │   ├── YES → user-invocable: true (default)
    │   └── NO  → user-invocable: false (background only)
    └── Should agent auto-load it?
        ├── YES → no disable-model-invocation (default)
        └── NO  → disable-model-invocation: true
```

---

## 10. Skill vs Other Primitives

| Need | Use |
|---|---|
| Always-on coding conventions | `copilot-instructions.md` (workspace) |
| Language/framework rules for specific files | `*.instructions.md` with `applyTo` glob |
| Repeatable benchmark / workflow | `SKILL.md` (this) |
| Single focused task with parameters | `*.prompt.md` |
| Isolated subagent with custom tools | `*.agent.md` |
| Enforce behavior at lifecycle points | Hooks (`*.json` in `.github/hooks/`) |
| External system integration | MCP server |

For more detail on all primitives, invoke `/agent-customization`.
