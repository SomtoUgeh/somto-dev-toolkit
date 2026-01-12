---
name: cancel-e2e
description: "Cancel active E2E test loop"
allowed-tools: ["Bash(cat .claude/.current_session:*)", "Bash(test -f .claude/e2e-loop-*.local.md:*)", "Bash(rm .claude/e2e-loop-*.local.md)", "Read(.claude/e2e-loop-*.local.md)", "Bash(echo *>>*)"]
hide-from-slash-command-tool: "true"
---

# Cancel E2E Loop

To cancel the E2E test loop:

1. Get the current session ID using Bash: `cat .claude/.current_session 2>/dev/null || echo "default"`

2. Check if `.claude/e2e-loop-{SESSION_ID}.local.md` exists using Bash: `test -f .claude/e2e-loop-{SESSION_ID}.local.md && echo "EXISTS" || echo "NOT_FOUND"`

3. **If NOT_FOUND**: Say "No active E2E loop found for this session."

4. **If EXISTS**:
   - Read `.claude/e2e-loop-{SESSION_ID}.local.md` to get: `iteration` and `progress_path`
   - Log CANCELLED to progress file:
     ```bash
     echo '{"ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","status":"CANCELLED","iteration":N,"notes":"User cancelled E2E test loop"}' >> PROGRESS_PATH
     ```
   - Remove the file using Bash: `rm .claude/e2e-loop-{SESSION_ID}.local.md`
   - Report: "Cancelled E2E loop (was at iteration N)" where N is the iteration value
