---
name: cancel-e2e
description: "Cancel active E2E test loop"
allowed-tools: ["Bash(test -f .claude/e2e-loop.local.md:*)", "Bash(rm .claude/e2e-loop.local.md)", "Read(.claude/e2e-loop.local.md)"]
hide-from-slash-command-tool: "true"
---

# Cancel E2E Loop

To cancel the E2E test loop:

1. Check if `.claude/e2e-loop.local.md` exists using Bash: `test -f .claude/e2e-loop.local.md && echo "EXISTS" || echo "NOT_FOUND"`

2. **If NOT_FOUND**: Say "No active E2E loop found."

3. **If EXISTS**:
   - Read `.claude/e2e-loop.local.md` to get the current iteration from the `iteration:` field
   - Remove the file using Bash: `rm .claude/e2e-loop.local.md`
   - Report: "Cancelled E2E loop (was at iteration N)"
