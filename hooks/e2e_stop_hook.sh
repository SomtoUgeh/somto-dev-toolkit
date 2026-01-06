#!/bin/bash

# E2E Test Loop Stop Hook
# Prevents session exit when an E2E loop is active
# Feeds the same prompt back to continue the loop

set -euo pipefail

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Check if E2E loop is active
STATE_FILE=".claude/e2e-loop.local.md"

if [[ ! -f "$STATE_FILE" ]]; then
  # No active loop - allow exit
  exit 0
fi

# Parse markdown frontmatter (YAML between ---) and extract values
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE")
ITERATION=$(echo "$FRONTMATTER" | grep '^iteration:' | sed 's/iteration: *//')
MAX_ITERATIONS=$(echo "$FRONTMATTER" | grep '^max_iterations:' | sed 's/max_iterations: *//')
TEST_COMMAND=$(echo "$FRONTMATTER" | grep '^test_command:' | sed 's/test_command: *//' | tr -d '"')
COMPLETION_PROMISE=$(echo "$FRONTMATTER" | grep '^completion_promise:' | sed 's/completion_promise: *//' | tr -d '"')

# Validate numeric fields
if [[ ! "$ITERATION" =~ ^[0-9]+$ ]]; then
  echo "E2E loop: State file corrupted (invalid iteration: '$ITERATION')" >&2
  echo "Stopping loop. Run /e2e again to start fresh." >&2
  rm "$STATE_FILE"
  exit 0
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  echo "E2E loop: State file corrupted (invalid max_iterations: '$MAX_ITERATIONS')" >&2
  echo "Stopping loop. Run /e2e again to start fresh." >&2
  rm "$STATE_FILE"
  exit 0
fi

# Check if max iterations reached
if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
  echo "E2E loop: Max iterations ($MAX_ITERATIONS) reached."
  rm "$STATE_FILE"
  exit 0
fi

# Get transcript path from hook input
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path')

if [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  echo "E2E loop: Transcript file not found" >&2
  echo "Stopping loop." >&2
  rm "$STATE_FILE"
  exit 0
fi

# Check if there are any assistant messages
if ! grep -q '"role":"assistant"' "$TRANSCRIPT_PATH"; then
  echo "E2E loop: No assistant messages found in transcript" >&2
  echo "Stopping loop." >&2
  rm "$STATE_FILE"
  exit 0
fi

# Extract last assistant message
LAST_LINE=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -1)
if [[ -z "$LAST_LINE" ]]; then
  echo "E2E loop: Failed to extract last assistant message" >&2
  echo "Stopping loop." >&2
  rm "$STATE_FILE"
  exit 0
fi

# Parse JSON to get text content
LAST_OUTPUT=$(echo "$LAST_LINE" | jq -r '
  .message.content |
  map(select(.type == "text")) |
  map(.text) |
  join("\n")
' 2>&1)

if [[ $? -ne 0 ]]; then
  echo "E2E loop: Failed to parse assistant message" >&2
  echo "Stopping loop." >&2
  rm "$STATE_FILE"
  exit 0
fi

if [[ -z "$LAST_OUTPUT" ]]; then
  echo "E2E loop: Assistant message contained no text" >&2
  echo "Stopping loop." >&2
  rm "$STATE_FILE"
  exit 0
fi

# Check for completion promise
PROMISE_TEXT=$(echo "$LAST_OUTPUT" | perl -0777 -pe 's/.*?<promise>(.*?)<\/promise>.*/$1/s; s/^\s+|\s+$//g; s/\s+/ /g' 2>/dev/null || echo "")

if [[ -n "$PROMISE_TEXT" ]] && [[ -n "$COMPLETION_PROMISE" ]] && [[ "$PROMISE_TEXT" = "$COMPLETION_PROMISE" ]]; then
  echo "E2E loop: Detected <promise>$COMPLETION_PROMISE</promise>"
  echo "E2E coverage complete!"
  rm "$STATE_FILE"
  exit 0
fi

# Not complete - continue loop
NEXT_ITERATION=$((ITERATION + 1))

# Extract prompt (everything after the closing ---)
PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")

if [[ -z "$PROMPT_TEXT" ]]; then
  echo "E2E loop: State file corrupted (no prompt found)" >&2
  echo "Stopping loop. Run /e2e again to start fresh." >&2
  rm "$STATE_FILE"
  exit 0
fi

# Update iteration in state file
TEMP_FILE="${STATE_FILE}.tmp.$$"
sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$STATE_FILE"

# Build system message
SYSTEM_MSG="E2E iteration $NEXT_ITERATION | Output <promise>$COMPLETION_PROMISE</promise> when all user flows are covered"

# Output JSON to block the stop and feed prompt back
jq -n \
  --arg prompt "$PROMPT_TEXT" \
  --arg msg "$SYSTEM_MSG" \
  '{
    "decision": "block",
    "reason": $prompt,
    "systemMessage": $msg
  }'

exit 0
