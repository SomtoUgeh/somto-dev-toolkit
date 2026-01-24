#!/bin/bash

# SessionStart Hook
# Captures session_id and writes it to .claude/.current_session
# This allows setup scripts (which run as commands, not hooks) to access session_id

set -euo pipefail

HOOK_INPUT=$(cat)
SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // empty')

if [[ -n "$SESSION_ID" ]]; then
  mkdir -p .claude
  echo "$SESSION_ID" > .claude/.current_session

  # Optional: Clean up orphan state files older than 24 hours
  # This prevents accumulation from crashed sessions
  find .claude -name "*-loop-*.local.md" -mtime +1 -delete 2>/dev/null || true

  # Check for active loops needing task sync
  for STATE_FILE in .claude/*-loop-*.local.md; do
    [[ -f "$STATE_FILE" ]] || continue

    if grep -q "^task_list_synced: false" "$STATE_FILE" 2>/dev/null; then
      LOOP_TYPE=$(sed -n 's/^loop_type: "\(.*\)"/\1/p' "$STATE_FILE" | head -1)
      echo "TASK_SYNC_HINT: Active $LOOP_TYPE loop found without task sync."
      echo "Consider syncing work items to Tasks for visibility (Ctrl+T)."
      break  # Only show hint once
    fi
  done
fi
