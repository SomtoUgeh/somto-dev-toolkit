---
name: go
description: Iterative task loop (generic or PRD-aware)
argument-hint: "<prompt|prd.json> [--completion-promise TEXT] [--max-iterations N]"
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

## Quality Expectations

Treat ALL code as production code. No shortcuts, no "good enough for now". Every line you write will be maintained, extended, and debugged by others. Fight entropy.

## Your Task

Read the generated state file (path shown in setup output) and begin work.

- **Generic mode**: Work on the task and output `<promise>TEXT</promise>` when complete.
- **PRD mode**: Implement stories one at a time, update prd.json, commit after each.

---

## Structured Output Control Flow

The stop hook parses your output for specific XML markers. **You MUST output the exact marker format** to advance. Missing or invalid markers block progression with guidance.

### Marker Summary by Mode

| Mode | Marker | When | Required |
|------|--------|------|----------|
| Generic | `<promise>TEXT</promise>` | Task complete | Yes (to exit) |
| PRD | `<reviews_complete/>` | After running reviewers | Yes |
| PRD | `<story_complete story_id="N"/>` | After commit | Yes |

### PRD Mode Control Flow (ENFORCED)

The hook validates this EXACT sequence before advancing to next story:

```
1. prd.json shows passes: true for current story
2. <reviews_complete/> marker in output
3. Git commit exists with story reference (e.g., "story #N")
4. <story_complete story_id="N"/> marker in output
```

**If ANY step missing**, hook blocks with specific guidance.

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

## MANDATORY Pre-Commit Reviews

**REQUIRED**: You MUST run these agents before EVERY commit. No exceptions. Do not skip.

1. **ALWAYS run code-simplifier first**: `pr-review-toolkit:code-simplifier` (max_turns: 15)
   - Simplifies and cleans your changes
   - Address ALL suggestions before proceeding

2. **ALWAYS run the appropriate Kieran reviewer** (all max_turns: 20):
   - **TypeScript/JavaScript**: `compound-engineering:review:kieran-typescript-reviewer`
   - **Python**: `compound-engineering:review:kieran-python-reviewer`
   - **Ruby/Rails**: `compound-engineering:review:kieran-rails-reviewer`
   - **Database/migrations/data models**: `compound-engineering:review:data-integrity-guardian`

3. **Address ALL review findings** before committing

4. **Output reviews marker** after addressing all findings:
   ```xml
   <reviews_complete/>
   ```

5. **Commit** with story reference, then output completion marker:
   ```xml
   <story_complete story_id="N"/>
   ```

### PRD Mode: Complete Sequence Example

```
# 1. Implement the story
# 2. Update prd.json: set passes: true for story 1
# 3. Run reviewers
Task(subagent_type="pr-review-toolkit:code-simplifier", max_turns: 15)
Task(subagent_type="compound-engineering:review:kieran-typescript-reviewer", max_turns: 20)
# 4. Address findings
# 5. Output reviews marker
<reviews_complete/>
# 6. Commit
git commit -m "feat(auth): story #1 - implement login form"
# 7. Output story completion
<story_complete story_id="1"/>
```

---

## Completion

When the task is genuinely complete, output:

```xml
<promise>COMPLETION_PROMISE</promise>
```

IMPORTANT: If a completion promise is set, you may ONLY output it when the statement is completely and unequivocally TRUE. Do not output false promises to escape the loop, even if you think you're stuck or should exit for other reasons. The loop is designed to continue until genuine completion.

---

## Error States

**Missing prd.json**: Hook blocks with message to restore file or rerun /prd.

**Invalid prd.json**: Hook blocks with message to fix JSON syntax.

**Story not passing**: Hook reminds to update prd.json with `passes: true`.

**Reviews not run**: Hook blocks with specific reviewer instructions.

**Commit not found**: Hook blocks with commit format reminder.

**story_id mismatch**: Hook rejects and reminds of current story ID.
