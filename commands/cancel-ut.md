---
name: cancel-ut
description: "Cancel active unit test loop"
allowed-tools: ["Bash(cat .claude/.current_session:*)", "Bash(test -f .claude/ut-loop-*.local.md:*)", "Bash(rm .claude/ut-loop-*.local.md)", "Read(.claude/ut-loop-*.local.md)", "Bash(echo *>>*)"]
hide-from-slash-command-tool: "true"
---

# Cancel Unit Test Loop

To cancel the unit test loop:

1. Get the current session ID using Bash: `cat .claude/.current_session 2>/dev/null || echo "default"`

2. Check if `.claude/ut-loop-{SESSION_ID}.local.md` exists using Bash: `test -f .claude/ut-loop-{SESSION_ID}.local.md && echo "EXISTS" || echo "NOT_FOUND"`

3. **If NOT_FOUND**: Say "No active unit test loop found for this session."

4. **If EXISTS**:
   - Read `.claude/ut-loop-{SESSION_ID}.local.md` to get: `iteration` and `progress_path`
   - Log CANCELLED to progress file:
     ```bash
     echo '{"ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","status":"CANCELLED","iteration":N,"notes":"User cancelled unit test loop"}' >> PROGRESS_PATH
     ```
   - Remove the file using Bash: `rm .claude/ut-loop-{SESSION_ID}.local.md`
   - Report: "Cancelled unit test loop (was at iteration N)" where N is the iteration value
