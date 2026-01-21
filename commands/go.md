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

## MANDATORY Pre-Commit Reviews

**REQUIRED**: You MUST run these agents before EVERY commit. No exceptions. Do not skip.

1. **ALWAYS run code-simplifier first**: `pr-review-toolkit:code-simplifier` (max_turns: 15)
   - Simplifies and cleans your changes
   - Address ALL suggestions before proceeding

2. **ALWAYS run the appropriate Kieran reviewer** (all max_turns: 20):
   - **TypeScript/JavaScript**: `compound-engineering:review:kieran-typescript-reviewer`
   - **Python**: `compound-engineering:review:kieran-python-reviewer`
   - **Rails/Ruby**: `compound-engineering:review:kieran-rails-reviewer`
   - **Database/migrations/data models**: `compound-engineering:review:data-integrity-guardian`

3. **Address ALL review findings** before committing

4. **[PRD MODE ONLY] Output reviews marker** after addressing all findings:
   ```
   <reviews_complete/>
   ```

5. **[PRD MODE ONLY] Commit**, then output story completion marker:
   ```
   <story_complete story_id="N"/>
   ```
   Where N is the current story ID.

⚠️ In PRD mode, the stop hook ENFORCES the full sequence:
1. `passes: true` in prd.json
2. `<reviews_complete/>`
3. Commit with story reference
4. `<story_complete story_id="N"/>`

You cannot advance to the next story without ALL markers.

## Completion

When the task is genuinely complete, output:

```
<promise>COMPLETION_PROMISE</promise>
```

IMPORTANT: If a completion promise is set, you may ONLY output it when the statement is completely and unequivocally TRUE. Do not output false promises to escape the loop, even if you think you're stuck or should exit for other reasons. The loop is designed to continue until genuine completion.
