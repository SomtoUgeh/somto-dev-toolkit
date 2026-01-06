#!/bin/bash

# Work Loop Stop Hook
# Unified hook for both generic and PRD modes
# Prevents session exit when a go loop is active
# Feeds the same prompt back (generic) or advances to next story (PRD)

set -euo pipefail

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Check if go loop is active
STATE_FILE=".claude/go-loop.local.md"

if [[ ! -f "$STATE_FILE" ]]; then
  # No active loop - allow exit
  exit 0
fi

# Parse markdown frontmatter (YAML between ---) and extract values
FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$STATE_FILE")
MODE=$(echo "$FRONTMATTER" | grep '^mode:' | sed 's/mode: *//' | tr -d '"')
ITERATION=$(echo "$FRONTMATTER" | grep '^iteration:' | sed 's/iteration: *//')
MAX_ITERATIONS=$(echo "$FRONTMATTER" | grep '^max_iterations:' | sed 's/max_iterations: *//')

# Validate mode
if [[ -z "$MODE" ]]; then
  echo "Go loop: State file corrupted (no mode)" >&2
  echo "Stopping loop. Run /work again to start fresh." >&2
  rm "$STATE_FILE"
  exit 0
fi

# Validate numeric fields
if [[ ! "$ITERATION" =~ ^[0-9]+$ ]]; then
  echo "Go loop: State file corrupted (invalid iteration: '$ITERATION')" >&2
  rm "$STATE_FILE"
  exit 0
fi

if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  echo "Go loop: State file corrupted (invalid max_iterations: '$MAX_ITERATIONS')" >&2
  rm "$STATE_FILE"
  exit 0
fi

# Check if max iterations reached
if [[ $MAX_ITERATIONS -gt 0 ]] && [[ $ITERATION -ge $MAX_ITERATIONS ]]; then
  echo "Go loop: Max iterations ($MAX_ITERATIONS) reached."
  echo "State preserved at $STATE_FILE for manual review."
  # Don't delete state file - preserve for debugging
  exit 0
fi

# Get transcript path from hook input
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path')

if [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  echo "Go loop: Transcript file not found" >&2
  rm "$STATE_FILE"
  exit 0
fi

# Check if there are any assistant messages
if ! grep -q '"role":"assistant"' "$TRANSCRIPT_PATH"; then
  echo "Go loop: No assistant messages found" >&2
  rm "$STATE_FILE"
  exit 0
fi

# ============================================================================
# GENERIC MODE
# ============================================================================
if [[ "$MODE" == "generic" ]]; then
  COMPLETION_PROMISE=$(echo "$FRONTMATTER" | grep '^completion_promise:' | sed 's/completion_promise: *//' | tr -d '"')

  # Extract last assistant message
  LAST_LINE=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -1)
  if [[ -z "$LAST_LINE" ]]; then
    echo "Go loop: Failed to extract last assistant message" >&2
    rm "$STATE_FILE"
    exit 0
  fi

  # Parse JSON to get text content
  LAST_OUTPUT=$(echo "$LAST_LINE" | jq -r '
    .message.content |
    map(select(.type == "text")) |
    map(.text) |
    join("\n")
  ' 2>/dev/null || echo "")

  if [[ -z "$LAST_OUTPUT" ]]; then
    echo "Go loop: Assistant message contained no text" >&2
    rm "$STATE_FILE"
    exit 0
  fi

  # Check for completion promise
  PROMISE_TEXT=$(echo "$LAST_OUTPUT" | perl -0777 -pe 's/.*?<promise>(.*?)<\/promise>.*/$1/s; s/^\s+|\s+$//g; s/\s+/ /g' 2>/dev/null || echo "")

  if [[ -n "$PROMISE_TEXT" ]] && [[ -n "$COMPLETION_PROMISE" ]] && [[ "$PROMISE_TEXT" == "$COMPLETION_PROMISE" ]]; then
    echo "Go loop: Detected <promise>$COMPLETION_PROMISE</promise>"
    echo "Task complete!"
    rm "$STATE_FILE"
    exit 0
  fi

  # Not complete - continue loop
  NEXT_ITERATION=$((ITERATION + 1))

  # Extract prompt (everything after the closing ---)
  PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")

  if [[ -z "$PROMPT_TEXT" ]]; then
    echo "Go loop: State file corrupted (no prompt found)" >&2
    rm "$STATE_FILE"
    exit 0
  fi

  # Update iteration in state file
  TEMP_FILE="${STATE_FILE}.tmp.$$"
  sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$STATE_FILE" > "$TEMP_FILE"
  mv "$TEMP_FILE" "$STATE_FILE"

  # Build system message
  SYSTEM_MSG="Go loop iteration $NEXT_ITERATION | Output <promise>$COMPLETION_PROMISE</promise> when done"

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
fi

# ============================================================================
# PRD MODE
# ============================================================================
if [[ "$MODE" == "prd" ]]; then
  PRD_PATH=$(echo "$FRONTMATTER" | grep '^prd_path:' | sed 's/prd_path: *//' | tr -d '"')
  PROGRESS_PATH=$(echo "$FRONTMATTER" | grep '^progress_path:' | sed 's/progress_path: *//' | tr -d '"')
  SPEC_PATH=$(echo "$FRONTMATTER" | grep '^spec_path:' | sed 's/spec_path: *//' | tr -d '"')
  FEATURE_NAME=$(echo "$FRONTMATTER" | grep '^feature_name:' | sed 's/feature_name: *//' | tr -d '"')
  CURRENT_STORY_ID=$(echo "$FRONTMATTER" | grep '^current_story_id:' | sed 's/current_story_id: *//')
  TOTAL_STORIES=$(echo "$FRONTMATTER" | grep '^total_stories:' | sed 's/total_stories: *//')

  # Validate PRD file exists
  if [[ ! -f "$PRD_PATH" ]]; then
    echo "Go loop: PRD file not found: $PRD_PATH" >&2
    rm "$STATE_FILE"
    exit 0
  fi

  # Validate PRD JSON
  if ! jq empty "$PRD_PATH" 2>/dev/null; then
    echo "Go loop: Invalid JSON in PRD file" >&2
    rm "$STATE_FILE"
    exit 0
  fi

  # Check if current story passes
  CURRENT_PASSES=$(jq ".stories[] | select(.id == $CURRENT_STORY_ID) | .passes" "$PRD_PATH")

  if [[ "$CURRENT_PASSES" != "true" ]]; then
    # Story not complete - repeat same prompt
    NEXT_ITERATION=$((ITERATION + 1))

    # Update iteration
    TEMP_FILE="${STATE_FILE}.tmp.$$"
    sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$STATE_FILE" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$STATE_FILE"

    # Extract prompt
    PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")

    SYSTEM_MSG="Go loop iteration $NEXT_ITERATION | Story #$CURRENT_STORY_ID not yet passing"

    jq -n \
      --arg prompt "$PROMPT_TEXT" \
      --arg msg "$SYSTEM_MSG" \
      '{
        "decision": "block",
        "reason": $prompt,
        "systemMessage": $msg
      }'

    exit 0
  fi

  # Story passes! Now verify commit exists
  STORY_TITLE=$(jq -r ".stories[] | select(.id == $CURRENT_STORY_ID) | .title" "$PRD_PATH")

  # Check for commit referencing this story (flexible matching)
  if ! git log --oneline -10 2>/dev/null | grep -qiE "(story.*#?${CURRENT_STORY_ID}|#${CURRENT_STORY_ID}|story ${CURRENT_STORY_ID})"; then
    # No commit found - block until committed
    NEXT_ITERATION=$((ITERATION + 1))

    TEMP_FILE="${STATE_FILE}.tmp.$$"
    sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$STATE_FILE" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$STATE_FILE"

    PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")

    SYSTEM_MSG="Go loop: Story #$CURRENT_STORY_ID passes but NO COMMIT FOUND. Commit your changes: feat($FEATURE_NAME): story #$CURRENT_STORY_ID - $STORY_TITLE"

    jq -n \
      --arg prompt "$PROMPT_TEXT" \
      --arg msg "$SYSTEM_MSG" \
      '{
        "decision": "block",
        "reason": $prompt,
        "systemMessage": $msg
      }'

    exit 0
  fi

  # Commit found! Log to progress.txt
  if [[ -f "$PROGRESS_PATH" ]]; then
    echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"story_id\":$CURRENT_STORY_ID,\"status\":\"PASSED\",\"notes\":\"Story #$CURRENT_STORY_ID complete\"}" >> "$PROGRESS_PATH"
  fi

  # Find next incomplete story
  NEXT_STORY_ID=$(jq -r '[.stories[] | select(.passes == false)] | sort_by(.priority) | first | .id // empty' "$PRD_PATH")

  if [[ -z "$NEXT_STORY_ID" ]]; then
    # All stories complete!
    echo "Go loop: All stories complete! Feature '$FEATURE_NAME' is done."
    rm "$STATE_FILE"
    exit 0
  fi

  # Advance to next story
  NEXT_ITERATION=$((ITERATION + 1))
  NEXT_STORY=$(jq ".stories[] | select(.id == $NEXT_STORY_ID)" "$PRD_PATH")
  NEXT_TITLE=$(echo "$NEXT_STORY" | jq -r '.title')
  INCOMPLETE_COUNT=$(jq '[.stories[] | select(.passes == false)] | length' "$PRD_PATH")

  # Log start of next story
  if [[ -f "$PROGRESS_PATH" ]]; then
    echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"story_id\":$NEXT_STORY_ID,\"status\":\"STARTED\",\"notes\":\"Beginning story #$NEXT_STORY_ID\"}" >> "$PROGRESS_PATH"
  fi

  # Rebuild state file with new story
  cat > "$STATE_FILE" <<EOF
---
mode: "prd"
active: true
prd_path: "$PRD_PATH"
spec_path: "$SPEC_PATH"
progress_path: "$PROGRESS_PATH"
feature_name: "$FEATURE_NAME"
current_story_id: $NEXT_STORY_ID
total_stories: $TOTAL_STORIES
iteration: $NEXT_ITERATION
max_iterations: $MAX_ITERATIONS
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---

# Work Loop: $FEATURE_NAME

**Progress:** Story $NEXT_STORY_ID of $TOTAL_STORIES ($INCOMPLETE_COUNT remaining)
**PRD:** \`$PRD_PATH\`
**Spec:** \`$SPEC_PATH\`

## Current Story

\`\`\`json
$NEXT_STORY
\`\`\`

## Code Style

- **MINIMAL COMMENTS** - code should be self-documenting
- Only comment the non-obvious "why", never the "what"
- Tests should live next to the code they test (colocation)

## Your Task

1. Read the full spec at \`$SPEC_PATH\`
2. Implement story #$NEXT_STORY_ID: "$NEXT_TITLE"
3. Follow the verification steps listed in the story
4. Write/update tests next to the code they test
5. Run: format, lint, tests, types (all must pass)
6. Update \`$PRD_PATH\`: set \`passes = true\` for story $NEXT_STORY_ID
7. Commit with appropriate type: \`<type>($FEATURE_NAME): story #$NEXT_STORY_ID - $NEXT_TITLE\`
   Types: feat (new feature), fix (bug fix), refactor, test, chore, docs

When you're done with this story, the hook will automatically:
- Verify the story passes in prd.json
- Verify you committed
- Log to progress.txt
- Advance to the next story (or complete if all done)

CRITICAL: Only mark the story as passing when it genuinely passes all verification steps.
EOF

  # Extract new prompt
  PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")

  SYSTEM_MSG="Go loop: Story #$CURRENT_STORY_ID complete! Now working on story #$NEXT_STORY_ID of $TOTAL_STORIES"

  jq -n \
    --arg prompt "$PROMPT_TEXT" \
    --arg msg "$SYSTEM_MSG" \
    '{
      "decision": "block",
      "reason": $prompt,
      "systemMessage": $msg
    }'

  exit 0
fi

# Unknown mode
echo "Go loop: Unknown mode '$MODE'" >&2
rm "$STATE_FILE"
exit 0
