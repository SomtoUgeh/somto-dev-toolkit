---
name: cancel-go
description: "Cancel active go loop"
allowed-tools: ["Bash(test -f .claude/go-loop.local.md:*)", "Bash(rm .claude/go-loop.local.md)", "Read(.claude/go-loop.local.md)", "Bash(echo *>>*)"]
hide-from-slash-command-tool: "true"
---

# Cancel Go Loop

To cancel the go loop:

1. Check if `.claude/go-loop.local.md` exists using Bash: `test -f .claude/go-loop.local.md && echo "EXISTS" || echo "NOT_FOUND"`

2. **If NOT_FOUND**: Say "No active go loop found."

3. **If EXISTS**:
   - Read `.claude/go-loop.local.md` to get: `iteration`, `mode`, `progress_path`, and (if PRD) `current_story_id`
   - Log CANCELLED to progress file:
     - **If PRD mode**:
       ```bash
       echo '{"ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","story_id":STORY_ID,"status":"CANCELLED","notes":"User cancelled at iteration N"}' >> PROGRESS_PATH
       ```
     - **If generic mode** (progress_path exists):
       ```bash
       echo '{"ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","status":"CANCELLED","iteration":N,"notes":"User cancelled go loop"}' >> PROGRESS_PATH
       ```
   - Remove the file using Bash: `rm .claude/go-loop.local.md`
   - Report: "Cancelled go loop (was at iteration N)" where N is the iteration value
