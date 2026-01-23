---
name: cancel-e2e
description: "Cancel active E2E test loop"
allowed-tools: ["Bash(ls .claude/e2e-loop-*.local.md:*)", "Bash(rm .claude/e2e-loop-*.local.md)", "Read(.claude/e2e-loop-*.local.md)", "Bash(jq *)"]
hide-from-slash-command-tool: "true"
---

# Cancel E2E Loop

To cancel the E2E test loop:

1. Find any e2e-loop state files:
   ```bash
   ls .claude/e2e-loop-*.local.md 2>/dev/null || echo "NONE"
   ```

2. **If NONE**: Say "No active E2E loop found in this project."

3. **If file(s) found**:
   - Read the FIRST state file to get: `started_at`, `state_json`
   - Log CANCELLED to state JSON (if state_json path available):
     ```bash
     jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
       '.log += [{"ts": $ts, "event": "cancelled", "notes": "User cancelled E2E test loop"}]' \
       "$STATE_JSON" > /tmp/cancel_state.tmp && mv /tmp/cancel_state.tmp "$STATE_JSON"
     ```
   - Remove ALL e2e-loop state files: `rm .claude/e2e-loop-*.local.md`
   - Show summary:
     ```
     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     📊 Loop Summary (Cancelled)
     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        Iterations: N
        Duration:   Xm Ys (calculate from started_at to now)
     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     ```
