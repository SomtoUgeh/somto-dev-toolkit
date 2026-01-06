---
name: go
description: Iterative task loop (generic or PRD-aware)
argument-hint: "<prompt|prd.json> [--completion-promise TEXT] [--max-iterations N]"
---

# Go Loop

Execute tasks iteratively with automatic progression.

## Input

<input> $ARGUMENTS </input>

## Instructions

This command supports two modes:

### Generic Mode
For any iterative task. Loops until you output the completion promise.

```
/go "Build a CSV parser with validation" --completion-promise "PARSER COMPLETE"
```

### PRD Mode
For PRD-based development. Auto-detects `.json` files or `--prd` flag.

```
/go plans/auth/prd.json
/go --prd plans/feature/prd.json
```

---

**Detect mode from input:**

1. If input ends in `.json` or contains `--prd` → **PRD mode**
2. Otherwise → **Generic mode** (requires `--completion-promise`)

**Run setup:**

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/setup-work-loop.sh <args>
```

**Then read the generated state file at `.claude/go-loop.local.md` and begin work.**

For generic mode: Work on the task and output `<promise>TEXT</promise>` when complete.

For PRD mode: Implement stories one at a time, update prd.json, commit after each.
