---
name: cancel-go
description: "Cancel active go loop"
allowed-tools: ["Bash(ls .claude/go-loop-*.local.md:*)", "Bash(rm .claude/go-loop-*.local.md)", "Read(.claude/go-loop-*.local.md)", "Bash(jq *)"]
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
   - Read the FIRST state file to get: `mode`, `started_at`, `prd_path` (if PRD mode)
   - Log CANCELLED to embedded log:
     - **If PRD mode** (prd_path exists):
       ```bash
       jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         '.log += [{"ts": $ts, "event": "cancelled", "notes": "User cancelled go loop"}]' \
         "$PRD_PATH" > /tmp/cancel_prd.tmp && mv /tmp/cancel_prd.tmp "$PRD_PATH"
       ```
     - **If generic mode**: No state JSON to update (state is in local.md only)
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
