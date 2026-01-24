---
name: cancel-prd
description: "Cancel active PRD loop"
allowed-tools: ["Bash(ls .claude/prd-loop-*.local.md:*)", "Bash(rm .claude/prd-loop-*.local.md)", "Read(.claude/prd-loop-*.local.md)"]
hide-from-slash-command-tool: "true"
disable-model-invocation: true
---

# Cancel PRD Loop

To cancel the PRD loop:

1. Find any prd-loop state files:
   ```bash
   ls .claude/prd-loop-*.local.md 2>/dev/null || echo "NONE"
   ```

2. **If NONE**: Say "No active PRD loop found in this project."

3. **If file(s) found**:
   - Read the FIRST state file to get: `feature_name`, `current_phase`, `started_at`
   - Remove ALL prd-loop state files: `rm .claude/prd-loop-*.local.md`
   - Show summary:
     ```
     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     📊 PRD Loop Summary (Cancelled)
     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
        Feature: FEATURE_NAME
        Phase:   CURRENT_PHASE
        Duration: Xm Ys (calculate from started_at to now)
     ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
     ```
