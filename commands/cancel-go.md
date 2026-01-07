---
name: cancel-go
description: "Cancel active go loop"
allowed-tools: ["Bash(test -f .claude/go-loop.local.md:*)", "Bash(rm .claude/go-loop.local.md)", "Read(.claude/go-loop.local.md)"]
hide-from-slash-command-tool: "true"
---

# Cancel Go Loop

To cancel the go loop:

1. Check if `.claude/go-loop.local.md` exists using Bash: `test -f .claude/go-loop.local.md && echo "EXISTS" || echo "NOT_FOUND"`

2. **If NOT_FOUND**: Say "No active go loop found."

3. **If EXISTS**:
   - Read `.claude/go-loop.local.md` to get the current iteration from the `iteration:` field
   - Remove the file using Bash: `rm .claude/go-loop.local.md`
   - Report: "Cancelled go loop (was at iteration N)" where N is the iteration value
