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
fi
