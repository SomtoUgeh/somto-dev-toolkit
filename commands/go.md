---
name: go
description: Iterative task loop (generic or PRD-aware)
argument-hint: "<prompt|prd.json> [--completion-promise TEXT] [--max-iterations N]"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-go-loop.sh:*)"]
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

## Your Task

Read the generated state file at `.claude/go-loop.local.md` and begin work.

- **Generic mode**: Work on the task and output `<promise>TEXT</promise>` when complete.
- **PRD mode**: Implement stories one at a time, update prd.json, commit after each.

## Completion

When the task is genuinely complete, output:

```
<promise>COMPLETION_PROMISE</promise>
```

IMPORTANT: If a completion promise is set, you may ONLY output it when the statement is completely and unequivocally TRUE. Do not output false promises to escape the loop, even if you think you're stuck or should exit for other reasons. The loop is designed to continue until genuine completion.
