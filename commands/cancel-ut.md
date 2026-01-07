---
name: cancel-ut
description: "Cancel active unit test loop"
allowed-tools: ["Bash(test -f .claude/ut-loop.local.md:*)", "Bash(rm .claude/ut-loop.local.md)", "Read(.claude/ut-loop.local.md)"]
hide-from-slash-command-tool: "true"
---

# Cancel Unit Test Loop

To cancel the unit test loop:

1. Check if `.claude/ut-loop.local.md` exists using Bash: `test -f .claude/ut-loop.local.md && echo "EXISTS" || echo "NOT_FOUND"`

2. **If NOT_FOUND**: Say "No active unit test loop found."

3. **If EXISTS**:
   - Read `.claude/ut-loop.local.md` to get the current iteration from the `iteration:` field
   - Remove the file using Bash: `rm .claude/ut-loop.local.md`
   - Report: "Cancelled unit test loop (was at iteration N)" where N is the iteration value
