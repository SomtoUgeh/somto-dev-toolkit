---
name: go
description: Iterative task loop (generic or PRD-aware)
argument-hint: "<prompt|prd.json> [--afk] [--completion-promise TEXT] [--max-iterations N]"
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-go-loop.sh:*)
hide-from-slash-command-tool: "true"
---

# Go Loop

Execute the setup script to initialize the go loop:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-go-loop.sh" $ARGUMENTS
```

You are now in an iterative task loop.

Please work on the task. When you try to exit, the go loop will feed the same PROMPT back to you for the next iteration. You'll see your previous work in files and git history, allowing you to iterate and improve.

## Modes

### Generic Mode
For any iterative task. Loops until you output the completion promise.

```
/go "Build a CSV parser with validation" --completion-promise "PARSER COMPLETE"
```

### PRD Mode
For PRD-based development. Auto-detects `.json` files or `--prd` flag.
State is stored in prd.json itself (single source of truth - no separate progress.txt).

```
/go plans/auth/prd.json
```

### HITL Mode (--once)
Single iteration, then stop for review. Use for learning, debugging prompts, or risky tasks.

```
/go plans/auth/prd.json --once    # One story, then stop
/go "Fix the bug" --completion-promise "FIXED" --once  # One iteration, then stop
```

Workflow: Run `--once` repeatedly until you trust the behavior, then switch to full loop.

### AFK Mode (--afk)
External bash loop for truly hands-off execution. Ralph Wiggum style.

```
/go plans/auth/prd.json --afk                    # External loop, default 50 iterations
/go plans/auth/prd.json --afk --max 30           # Limit to 30 iterations
/go plans/auth/prd.json --afk --stream           # Real-time output visibility (recommended)
/go plans/auth/prd.json --afk --sandbox          # Docker sandbox (requires Desktop 4.50+)
/go plans/auth/prd.json --afk --stream --sandbox # Sandbox + streaming
```

**Key differences from HITL:**
- Each iteration is a **fresh Claude session** (prevents context rot)
- State persists in **prd.json only** (single source of truth)
- No hook-based continuation - external bash for loop
- Optional streaming output via jq for visibility while AFK
- Optional Docker sandbox for safety

**When to use:**
- Bulk implementation work (many stories)
- Low-risk, well-defined tasks
- Overnight/unattended runs
- When you trust your PRD and want hands-off execution

**Progression:** Start with `--once` to learn → Graduate to default (hook-based) → Go `--afk` when confident

## Quality Expectations

Treat ALL code as production code. No shortcuts, no "good enough for now". Every line you write will be maintained, extended, and debugged by others. Fight entropy.

## Your Task

Read the generated state file (path shown in setup output) and begin work.

- **Generic mode**: Work on the task and output `<promise>TEXT</promise>` when complete.
- **PRD mode**: Implement stories one at a time, update prd.json, commit after each.

---

## Branch Setup (Handled by Setup Script)

When starting on main/master, the setup script prompts:
1. "Create a feature branch?" [1/2]
2. If yes, prompts for branch name with suggested default
3. Creates branch before loop starts

This happens in bash before Claude starts working.

---

## Structured Output Control Flow

The stop hook uses **markers as signals, with fallback detection** for resilience. If you complete the work but forget a marker, the hook can detect from prd.json and git state.

### Marker Summary by Mode

| Mode | Marker | Status | Fallback |
|------|--------|--------|----------|
| Generic | `<promise>TEXT</promise>` | Required | None (explicit exit) |
| PRD | `<reviews_complete/>` | Required | **None** (quality gate) |
| PRD | `<story_complete story_id="N"/>` | Optional | prd.json passes + commit → auto-advances |

### PRD Mode Control Flow

The hook validates these conditions before advancing to next story:

```
1. prd.json shows passes: true for current story
2. <reviews_complete/> marker in output (REQUIRED - no fallback)
3. Git commit exists with story reference (e.g., "story #N")
4. <story_complete story_id="N"/> marker (optional - auto-detected from above)
```

**State Management**: prd.json IS the source of truth. Current story is derived as the first story with `passes: false` (sorted by priority). Progress log is embedded in prd.json's `log` array.

**Fallback detection**: If story passes in prd.json AND commit exists but marker missing, hook auto-advances.

### Exact Marker Formats

```xml
<!-- Generic mode: task completion -->
<promise>COMPLETION_PROMISE_TEXT</promise>

<!-- PRD mode: after running reviewers and addressing findings -->
<reviews_complete/>

<!-- PRD mode: after committing (N = current story ID) -->
<story_complete story_id="1"/>
```

### Validation Rules

1. **story_id must match current story** - `<story_complete story_id="2"/>` when on story 1 is rejected
2. **Last marker wins** - If examples appear in docs, only LAST occurrence counts
3. **Commit must reference story** - Pattern: `story #N` or `#N` with word boundary (prevents #1 matching #10)
4. **Promise must match exactly** - `<promise>DONE</promise>` only matches if promise is "DONE"

---

## MANDATORY Pre-Commit Reviews (PARALLEL)

**REQUIRED**: You MUST run these agents before EVERY commit. No exceptions. Do not skip.

### Launch ALL Reviewers IN PARALLEL (Single Message)

In ONE message, spawn multiple Task tool calls:

```
Task 1: subagent_type="pr-review-toolkit:code-simplifier" (max_turns: 15)
Task 2: subagent_type="<appropriate-kieran-reviewer>" (max_turns: 20)
```

**Kieran reviewer by language:**
- **TypeScript/JavaScript**: `compound-engineering:review:kieran-typescript-reviewer`
- **Python**: `compound-engineering:review:kieran-python-reviewer`
- **Ruby/Rails**: `compound-engineering:review:kieran-rails-reviewer`

**Add if applicable:**
- **Database/migrations**: `compound-engineering:review:data-integrity-guardian`
- **Frontend races**: `compound-engineering:review:julik-frontend-races-reviewer`

All agents run in parallel → results return together → faster reviews.

### After Reviews Complete

1. **Address ALL findings** from all reviewers
2. **Output reviews marker**:
   ```xml
   <reviews_complete/>
   ```
3. **Commit** with story reference
4. **Output completion marker**:
   ```xml
   <story_complete story_id="N"/>
   ```

### PRD Mode: Complete Sequence Example

```
# 1. Implement the story
# 2. Run tests, lint, typecheck
# 3. Run reviewers IN PARALLEL (single message, multiple Task calls)
Task(subagent_type="pr-review-toolkit:code-simplifier", max_turns: 15)
Task(subagent_type="compound-engineering:review:kieran-typescript-reviewer", max_turns: 20)

# 4. Address ALL findings from both reviewers
# 5. Output reviews marker (REQUIRED)
<reviews_complete/>

# 6. Update prd.json: set passes: true for story 1
# 7. Commit with story reference
git commit -m "feat(auth): story #1 - implement login form"

# 8. Output story completion (optional - hook auto-detects from prd.json + commit)
<story_complete story_id="1"/>
```

**Hook handles automatically:** Updates story's `completed_at` and `commit` fields, appends to prd.json's `log` array.

---

## Completion

When the task is genuinely complete, output:

```xml
<promise>COMPLETION_PROMISE</promise>
```

IMPORTANT: If a completion promise is set, you may ONLY output it when the statement is completely and unequivocally TRUE. Do not output false promises to escape the loop, even if you think you're stuck or should exit for other reasons. The loop is designed to continue until genuine completion.

---

## Loop Behavior

The loop continues prompting until work is complete. No hard failures on missing markers.

**Missing prd.json**: Prompts to restore file or rerun /prd.

**Invalid prd.json**: Prompts to fix JSON syntax.

**Story not passing**: Reminds to update prd.json with `passes: true`.

**Reviews not run**: Prompts with reviewer instructions (required quality gate).

**Commit not found**: Reminds with commit format.

**story_id mismatch**: Reminds of current story ID.
