---
name: cancel-go
description: Cancel active go loop
---

# Cancel Go Loop

Cancel an active go loop (generic or PRD mode).

## Instructions

Check if a work loop is active:

```bash
if [[ -f ".claude/go-loop.local.md" ]]; then
  # Extract info from state file
  FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' ".claude/go-loop.local.md")
  MODE=$(echo "$FRONTMATTER" | grep '^mode:' | sed 's/mode: *//' | tr -d '"')
  ITERATION=$(echo "$FRONTMATTER" | grep '^iteration:' | sed 's/iteration: *//')

  # Remove state file
  rm ".claude/go-loop.local.md"

  echo "Go loop cancelled at iteration $ITERATION (mode: $MODE)"
else
  echo "No active go loop to cancel"
fi
```

The state file is preserved in git history if you need to recover it.
