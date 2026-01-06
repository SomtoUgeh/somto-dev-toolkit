---
name: cancel-work
description: Cancel active work loop
---

# Cancel Work Loop

Cancel an active work loop (generic or PRD mode).

## Instructions

Check if a work loop is active:

```bash
if [[ -f ".claude/work-loop.local.md" ]]; then
  # Extract info from state file
  FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' ".claude/work-loop.local.md")
  MODE=$(echo "$FRONTMATTER" | grep '^mode:' | sed 's/mode: *//' | tr -d '"')
  ITERATION=$(echo "$FRONTMATTER" | grep '^iteration:' | sed 's/iteration: *//')

  # Remove state file
  rm ".claude/work-loop.local.md"

  echo "Work loop cancelled at iteration $ITERATION (mode: $MODE)"
else
  echo "No active work loop to cancel"
fi
```

The state file is preserved in git history if you need to recover it.
