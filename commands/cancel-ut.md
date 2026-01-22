---
name: cancel-ut
description: "Cancel active unit test loop"
allowed-tools: ["Bash(ls .claude/ut-loop-*.local.md:*)", "Bash(rm .claude/ut-loop-*.local.md)", "Read(.claude/ut-loop-*.local.md)", "Bash(echo *>>*)"]
hide-from-slash-command-tool: "true"
---

# Cancel Unit Test Loop

To cancel the unit test loop:

1. Find any ut-loop state files:
   ```bash
   ls .claude/ut-loop-*.local.md 2>/dev/null || echo "NONE"
   ```

2. **If NONE**: Say "No active unit test loop found in this project."

3. **If file(s) found**:
   - Read the FIRST state file to get: `iteration`, `progress_path`, `started_at`
   - Log CANCELLED to progress file:
     ```bash
     echo '{"ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","status":"CANCELLED","iteration":N,"notes":"User cancelled unit test loop"}' >> PROGRESS_PATH
     ```
   - Remove ALL ut-loop state files: `rm .claude/ut-loop-*.local.md`
   - Show summary:
     ```
     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     📊 Loop Summary (Cancelled)
     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        Iterations: N
        Duration:   Xm Ys (calculate from started_at to now)
     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     ```
