---
name: cancel-prd
description: "Cancel active PRD loop"
allowed-tools: ["Bash(cat .claude/.current_session:*)", "Bash(test -f .claude/prd-loop-*.local.md:*)", "Bash(rm .claude/prd-loop-*.local.md)", "Read(.claude/prd-loop-*.local.md)"]
hide-from-slash-command-tool: "true"
---

# Cancel PRD Loop

To cancel the PRD loop:

1. Get the current session ID using Bash: `cat .claude/.current_session 2>/dev/null || echo "default"`

2. Check if `.claude/prd-loop-{SESSION_ID}.local.md` exists using Bash: `test -f .claude/prd-loop-{SESSION_ID}.local.md && echo "EXISTS" || echo "NOT_FOUND"`

3. **If NOT_FOUND**: Say "No active PRD loop found for this session."

4. **If EXISTS**:
   - Read `.claude/prd-loop-{SESSION_ID}.local.md` to get: `feature_name`, `current_phase`
   - Remove the file using Bash: `rm .claude/prd-loop-{SESSION_ID}.local.md`
   - Report: "Cancelled PRD loop for '$FEATURE_NAME' (was at phase $CURRENT_PHASE)"
