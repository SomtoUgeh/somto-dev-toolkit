---
description: "Cancel active test coverage loop"
allowed-tools: ["Bash(test -f .claude/test-coverage-loop.local.md:*)", "Bash(rm .claude/test-coverage-loop.local.md)", "Read(.claude/test-coverage-loop.local.md)"]
hide-from-slash-command-tool: "true"
---

# Cancel Test Coverage Loop

To cancel the test coverage loop:

1. Check if `.claude/test-coverage-loop.local.md` exists using Bash: `test -f .claude/test-coverage-loop.local.md && echo "EXISTS" || echo "NOT_FOUND"`

2. **If NOT_FOUND**: Say "No active test coverage loop found."

3. **If EXISTS**:
   - Read `.claude/test-coverage-loop.local.md` to get the current iteration from the `iteration:` field
   - Remove the file using Bash: `rm .claude/test-coverage-loop.local.md`
   - Report: "Cancelled test coverage loop (was at iteration N)"
