---
name: cancel-go
description: "Cancel active go loop"
allowed-tools: ["Bash(cat .claude/.current_session:*)", "Bash(test -f .claude/go-loop-*.local.md:*)", "Bash(rm .claude/go-loop-*.local.md)", "Read(.claude/go-loop-*.local.md)", "Bash(echo *>>*)"]
hide-from-slash-command-tool: "true"
---

# Cancel Go Loop

To cancel the go loop:

1. Get the current session ID using Bash: `cat .claude/.current_session 2>/dev/null || echo "default"`

2. Check if `.claude/go-loop-{SESSION_ID}.local.md` exists using Bash: `test -f .claude/go-loop-{SESSION_ID}.local.md && echo "EXISTS" || echo "NOT_FOUND"`

3. **If NOT_FOUND**: Say "No active go loop found for this session."

4. **If EXISTS**:
   - Read `.claude/go-loop-{SESSION_ID}.local.md` to get: `iteration`, `mode`, `progress_path`, `started_at`, and (if PRD) `current_story_id`
   - Log CANCELLED to progress file:
     - **If PRD mode**:
       ```bash
       echo '{"ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","story_id":STORY_ID,"status":"CANCELLED","notes":"User cancelled at iteration N"}' >> PROGRESS_PATH
       ```
     - **If generic mode** (progress_path exists):
       ```bash
       echo '{"ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","status":"CANCELLED","iteration":N,"notes":"User cancelled go loop"}' >> PROGRESS_PATH
       ```
   - Remove the file using Bash: `rm .claude/go-loop-{SESSION_ID}.local.md`
   - Show summary and report cancellation:
     ```
     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     📊 Loop Summary (Cancelled)
     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        Iterations: N
        Duration:   Xm Ys (calculate from started_at to now)
     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     ```
