#!/usr/bin/env bash
# Fork suggestion on first prompt - queries qmd, suggests fork with command
#
# Triggered: UserPromptSubmit
# Output: additionalContext with fork command if relevant match found
#
# Exit codes:
# - 0: Always (never block prompt)

set -euo pipefail

# Configuration
MIN_PROMPT_LENGTH=20
QMD_COLLECTION="claude-sessions"

# Read hook input
HOOK_INPUT=$(cat)
PROMPT=$(echo "$HOOK_INPUT" | jq -r '.prompt // ""')

# Skip short prompts
[[ ${#PROMPT} -lt $MIN_PROMPT_LENGTH ]] && exit 0

# Skip if qmd not available
command -v qmd &>/dev/null || exit 0

# Check if claude-sessions collection exists
if ! qmd status 2>/dev/null | grep -q "$QMD_COLLECTION"; then
    exit 0
fi

# Query qmd for similar sessions (keyword search - instant)
RESULTS=$(qmd search "$PROMPT" --json -n 1 -c "$QMD_COLLECTION" 2>/dev/null) || exit 0

# Check if we got results (qmd returns "No results found." text when empty)
[[ -z "$RESULTS" || "$RESULTS" == "[]" || "$RESULTS" == "null" || "$RESULTS" == "No results found." ]] && exit 0

# Verify it's valid JSON before parsing
echo "$RESULTS" | jq empty 2>/dev/null || exit 0

# Parse result (qmd uses 'file' not 'path' for file location)
TITLE=$(echo "$RESULTS" | jq -r '.[0].title // .[0].file // ""')
SESSION_PATH=$(echo "$RESULTS" | jq -r '.[0].file // ""')

# Skip if no meaningful result
[[ -z "$TITLE" || "$TITLE" == "null" ]] && exit 0

# Extract session ID from path (filename without extension)
SESSION_ID=""
if [[ -n "$SESSION_PATH" ]]; then
    SESSION_ID=$(basename "$SESSION_PATH" .md)
fi

# Only suggest if we have valid session ID (UUID format)
[[ -z "$SESSION_ID" ]] && exit 0

# Build suggestion with fork command
CONTEXT="🔍 SIMILAR PAST SESSION FOUND:

\"$TITLE\"

To fork and continue from this session, run in a NEW terminal:

  claude --resume $SESSION_ID --fork-session

(Cannot fork mid-session - must start fresh with the fork flag)"

# Output for additionalContext injection
jq -n --arg ctx "$CONTEXT" '{"additionalContext": $ctx}'

exit 0
