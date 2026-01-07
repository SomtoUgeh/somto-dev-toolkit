#!/bin/bash

# Unified Stop Hook
# Handles all loop types: go, ut, e2e
# Prevents session exit when any loop is active

set -euo pipefail

# Fallback safety limit - prevents runaway loops even if max_iterations not set
FALLBACK_MAX_ITERATIONS=100

# Read hook input from stdin
HOOK_INPUT=$(cat)

# =============================================================================
# GUARD 1: Check stop_hook_active (CRITICAL - prevents infinite loops)
# =============================================================================
STOP_HOOK_ACTIVE=$(echo "$HOOK_INPUT" | jq -r '.stop_hook_active // false')

if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
  # Already in a stop hook loop - allow exit to prevent infinite recursion
  exit 0
fi

# =============================================================================
# GUARD 2: Check which loop is active (if any)
# =============================================================================
GO_STATE=".claude/go-loop.local.md"
UT_STATE=".claude/ut-loop.local.md"
E2E_STATE=".claude/e2e-loop.local.md"

ACTIVE_LOOP=""
STATE_FILE=""

if [[ -f "$GO_STATE" ]]; then
  ACTIVE_LOOP="go"
  STATE_FILE="$GO_STATE"
elif [[ -f "$UT_STATE" ]]; then
  ACTIVE_LOOP="ut"
  STATE_FILE="$UT_STATE"
elif [[ -f "$E2E_STATE" ]]; then
  ACTIVE_LOOP="e2e"
  STATE_FILE="$E2E_STATE"
fi

if [[ -z "$ACTIVE_LOOP" ]]; then
  # No active loop - allow exit
  exit 0
fi

# =============================================================================
# Parse state file frontmatter
# =============================================================================
parse_frontmatter() {
  local file="$1"
  sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$file"
}

get_field() {
  local frontmatter="$1"
  local field="$2"
  echo "$frontmatter" | grep "^${field}:" | sed "s/${field}: *//" | tr -d '"' || true
}

FRONTMATTER=$(parse_frontmatter "$STATE_FILE")
ITERATION=$(get_field "$FRONTMATTER" "iteration")
MAX_ITERATIONS=$(get_field "$FRONTMATTER" "max_iterations")
COMPLETION_PROMISE=$(get_field "$FRONTMATTER" "completion_promise")

# Handle mode for go loop
MODE=""
if [[ "$ACTIVE_LOOP" == "go" ]]; then
  MODE=$(get_field "$FRONTMATTER" "mode")
fi

# =============================================================================
# GUARD 3: Validate numeric fields
# =============================================================================
if [[ ! "$ITERATION" =~ ^[0-9]+$ ]]; then
  echo "Loop ($ACTIVE_LOOP): State corrupted (invalid iteration: '$ITERATION')" >&2
  rm "$STATE_FILE"
  exit 0
fi

# Default max_iterations to 0 if not set or invalid
if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  MAX_ITERATIONS=0
fi

# =============================================================================
# GUARD 4: Check iteration limits
# =============================================================================
# Apply fallback limit if no max_iterations set
EFFECTIVE_MAX=$MAX_ITERATIONS
if [[ $EFFECTIVE_MAX -eq 0 ]]; then
  EFFECTIVE_MAX=$FALLBACK_MAX_ITERATIONS
fi

if [[ $ITERATION -ge $EFFECTIVE_MAX ]]; then
  if [[ $MAX_ITERATIONS -eq 0 ]]; then
    echo "Loop ($ACTIVE_LOOP): Fallback safety limit ($FALLBACK_MAX_ITERATIONS) reached."
  else
    echo "Loop ($ACTIVE_LOOP): Max iterations ($MAX_ITERATIONS) reached."
  fi
  rm "$STATE_FILE"
  exit 0
fi

# =============================================================================
# Get transcript and check for completion
# =============================================================================
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path')

if [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  echo "Loop ($ACTIVE_LOOP): Transcript not found - continuing anyway" >&2
  # Don't terminate - continue the loop
fi

# Extract last assistant message (if transcript exists)
LAST_OUTPUT=""
if [[ -f "$TRANSCRIPT_PATH" ]] && grep -q '"role":"assistant"' "$TRANSCRIPT_PATH" 2>/dev/null; then
  LAST_LINE=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -1)
  if [[ -n "$LAST_LINE" ]]; then
    LAST_OUTPUT=$(echo "$LAST_LINE" | jq -r '
      .message.content |
      map(select(.type == "text")) |
      map(.text) |
      join("\n")
    ' 2>/dev/null || echo "")
  fi
fi

# NOTE: We do NOT terminate if LAST_OUTPUT is empty!
# Claude might have only used tools without text output - that's fine.

# =============================================================================
# Check for completion promise
# =============================================================================
if [[ -n "$COMPLETION_PROMISE" ]] && [[ "$COMPLETION_PROMISE" != "null" ]] && [[ -n "$LAST_OUTPUT" ]]; then
  # Extract text from <promise> tags
  PROMISE_TEXT=$(echo "$LAST_OUTPUT" | perl -0777 -pe 's/.*?<promise>(.*?)<\/promise>.*/$1/s; s/^\s+|\s+$//g; s/\s+/ /g' 2>/dev/null || echo "")

  if [[ -n "$PROMISE_TEXT" ]] && [[ "$PROMISE_TEXT" = "$COMPLETION_PROMISE" ]]; then
    echo "Loop ($ACTIVE_LOOP): Detected <promise>$COMPLETION_PROMISE</promise>"
    echo "Task complete!"
    rm "$STATE_FILE"
    exit 0
  fi
fi

# =============================================================================
# Handle PRD mode for go loop (story advancement)
# =============================================================================
if [[ "$ACTIVE_LOOP" == "go" ]] && [[ "$MODE" == "prd" ]]; then
  PRD_PATH=$(get_field "$FRONTMATTER" "prd_path")
  PROGRESS_PATH=$(get_field "$FRONTMATTER" "progress_path")
  SPEC_PATH=$(get_field "$FRONTMATTER" "spec_path")
  FEATURE_NAME=$(get_field "$FRONTMATTER" "feature_name")
  CURRENT_STORY_ID=$(get_field "$FRONTMATTER" "current_story_id")
  TOTAL_STORIES=$(get_field "$FRONTMATTER" "total_stories")

  if [[ -f "$PRD_PATH" ]] && jq empty "$PRD_PATH" 2>/dev/null; then
    CURRENT_PASSES=$(jq ".stories[] | select(.id == $CURRENT_STORY_ID) | .passes" "$PRD_PATH" 2>/dev/null || echo "false")

    if [[ "$CURRENT_PASSES" == "true" ]]; then
      # Story passes - check for commit
      STORY_TITLE=$(jq -r ".stories[] | select(.id == $CURRENT_STORY_ID) | .title" "$PRD_PATH")

      if git log --oneline -10 2>/dev/null | grep -qiE "(story.*#?${CURRENT_STORY_ID}|#${CURRENT_STORY_ID}|story ${CURRENT_STORY_ID})"; then
        # Commit found - log and advance
        if [[ -f "$PROGRESS_PATH" ]]; then
          echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"story_id\":$CURRENT_STORY_ID,\"status\":\"PASSED\",\"notes\":\"Story #$CURRENT_STORY_ID complete\"}" >> "$PROGRESS_PATH"
        fi

        # Find next incomplete story
        NEXT_STORY_ID=$(jq -r '[.stories[] | select(.passes == false)] | sort_by(.priority) | first | .id // empty' "$PRD_PATH")

        if [[ -z "$NEXT_STORY_ID" ]]; then
          echo "Loop (go/prd): All stories complete! Feature '$FEATURE_NAME' is done."
          rm "$STATE_FILE"
          exit 0
        fi

        # Advance to next story - rebuild state file
        NEXT_ITERATION=$((ITERATION + 1))
        NEXT_STORY=$(jq ".stories[] | select(.id == $NEXT_STORY_ID)" "$PRD_PATH")
        NEXT_TITLE=$(echo "$NEXT_STORY" | jq -r '.title')
        INCOMPLETE_COUNT=$(jq '[.stories[] | select(.passes == false)] | length' "$PRD_PATH")

        if [[ -f "$PROGRESS_PATH" ]]; then
          echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"story_id\":$NEXT_STORY_ID,\"status\":\"STARTED\",\"notes\":\"Beginning story #$NEXT_STORY_ID\"}" >> "$PROGRESS_PATH"
        fi

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

## Your Task

1. Read the full spec at \`$SPEC_PATH\`
2. Implement story #$NEXT_STORY_ID: "$NEXT_TITLE"
3. Follow the verification steps listed in the story
4. Write/update tests next to the code they test
5. Run: format, lint, tests, types (all must pass)
6. Update \`$PRD_PATH\`: set \`passes = true\` for story $NEXT_STORY_ID
7. Commit with appropriate type: \`<type>($FEATURE_NAME): story #$NEXT_STORY_ID - $NEXT_TITLE\`

CRITICAL: Only mark the story as passing when it genuinely passes all verification steps.
EOF

        PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")
        SYSTEM_MSG="Loop (go/prd): Story #$CURRENT_STORY_ID complete! Now on story #$NEXT_STORY_ID of $TOTAL_STORIES"

        jq -n \
          --arg prompt "$PROMPT_TEXT" \
          --arg msg "$SYSTEM_MSG" \
          '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
        exit 0
      else
        # Story passes but no commit - remind to commit
        NEXT_ITERATION=$((ITERATION + 1))
        TEMP_FILE="${STATE_FILE}.tmp.$$"
        sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$STATE_FILE" > "$TEMP_FILE"
        mv "$TEMP_FILE" "$STATE_FILE"

        PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")
        SYSTEM_MSG="Loop (go/prd): Story #$CURRENT_STORY_ID passes but NO COMMIT. Commit: feat($FEATURE_NAME): story #$CURRENT_STORY_ID"

        jq -n \
          --arg prompt "$PROMPT_TEXT" \
          --arg msg "$SYSTEM_MSG" \
          '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
        exit 0
      fi
    fi
  fi
fi

# =============================================================================
# Continue loop (generic case for all loop types)
# =============================================================================
NEXT_ITERATION=$((ITERATION + 1))

# Update iteration in state file
TEMP_FILE="${STATE_FILE}.tmp.$$"
sed "s/^iteration: .*/iteration: $NEXT_ITERATION/" "$STATE_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$STATE_FILE"

# Extract prompt (everything after the closing ---)
PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")

if [[ -z "$PROMPT_TEXT" ]]; then
  echo "Loop ($ACTIVE_LOOP): State corrupted (no prompt found)" >&2
  rm "$STATE_FILE"
  exit 0
fi

# Build system message based on loop type
case "$ACTIVE_LOOP" in
  go)
    if [[ "$MODE" == "prd" ]]; then
      CURRENT_STORY_ID=$(get_field "$FRONTMATTER" "current_story_id")
      SYSTEM_MSG="Loop (go/prd) iteration $NEXT_ITERATION | Story #$CURRENT_STORY_ID not yet passing"
    else
      SYSTEM_MSG="Loop (go) iteration $NEXT_ITERATION | Output <promise>$COMPLETION_PROMISE</promise> when done"
    fi
    ;;
  ut)
    TARGET_COVERAGE=$(get_field "$FRONTMATTER" "target_coverage")
    if [[ -n "$TARGET_COVERAGE" ]] && [[ "$TARGET_COVERAGE" != "0" ]]; then
      SYSTEM_MSG="Loop (ut) iteration $NEXT_ITERATION | Target: ${TARGET_COVERAGE}% | Output <promise>$COMPLETION_PROMISE</promise> when done"
    else
      SYSTEM_MSG="Loop (ut) iteration $NEXT_ITERATION | Output <promise>$COMPLETION_PROMISE</promise> when done"
    fi
    ;;
  e2e)
    SYSTEM_MSG="Loop (e2e) iteration $NEXT_ITERATION | Output <promise>$COMPLETION_PROMISE</promise> when all flows covered"
    ;;
esac

# Output JSON to block stop and continue loop
jq -n \
  --arg prompt "$PROMPT_TEXT" \
  --arg msg "$SYSTEM_MSG" \
  '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'

exit 0
