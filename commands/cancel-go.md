---
name: cancel-go
description: "Cancel active go loop"
allowed-tools: ["Bash(ls .claude/go-loop-*.local.md:*)", "Bash(rm .claude/go-loop-*.local.md)", "Read(.claude/go-loop-*.local.md)", "Bash(echo *>>*)"]
hide-from-slash-command-tool: "true"
---

# Cancel Go Loop

To cancel the go loop:

1. Find any go-loop state files:
   ```bash
   ls .claude/go-loop-*.local.md 2>/dev/null || echo "NONE"
   ```

2. **If NONE**: Say "No active go loop found in this project."

3. **If file(s) found**:
   - Read the FIRST state file to get: `iteration`, `mode`, `progress_path`, `started_at`, and (if PRD) `current_story_id`
   - Log CANCELLED to progress file:
     - **If PRD mode**:
       ```bash
       echo '{"ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","story_id":STORY_ID,"status":"CANCELLED","notes":"User cancelled at iteration N"}' >> PROGRESS_PATH
       ```
     - **If generic mode** (progress_path exists):
       ```bash
       echo '{"ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","status":"CANCELLED","iteration":N,"notes":"User cancelled go loop"}' >> PROGRESS_PATH
       ```
   - Remove ALL go-loop state files: `rm .claude/go-loop-*.local.md`
   - Show summary and report cancellation:
     ```
     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     📊 Loop Summary (Cancelled)
     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        Iterations: N
        Duration:   Xm Ys (calculate from started_at to now)
     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     ```
