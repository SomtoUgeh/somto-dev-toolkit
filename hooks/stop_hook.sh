#!/bin/bash

# Unified Stop Hook
# Handles all loop types: go, ut, e2e
# Prevents session exit when any loop is active

set -euo pipefail

# Fallback safety limit - prevents runaway loops even if max_iterations not set
FALLBACK_MAX_ITERATIONS=100

# Update iteration in state file safely (same directory to avoid cross-filesystem issues)
update_iteration() {
  local state_file="$1"
  local new_iteration="$2"
  local temp_file="${state_file}.tmp.$$"

  sed "s/^iteration: .*/iteration: $new_iteration/" "$state_file" > "$temp_file"
  mv "$temp_file" "$state_file"
}

# Write state file atomically (write to temp, then move)
# Uses printf to handle multiline content safely
write_state_file() {
  local state_file="$1"
  local content="$2"
  local temp_file="${state_file}.tmp.$$"

  printf '%s\n' "$content" > "$temp_file"
  mv "$temp_file" "$state_file"
}

# Send desktop notification on loop completion (cross-platform, non-blocking)
notify() {
  local title="$1"
  local message="$2"
  case "$(uname -s)" in
    Darwin)
      osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
      ;;
    Linux)
      notify-send "$title" "$message" 2>/dev/null || true
      ;;
    MINGW*|MSYS*|CYGWIN*)
      # Run in background to avoid blocking
      powershell.exe -Command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show('$message', '$title')" </dev/null >/dev/null 2>&1 &
      ;;
  esac
}

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
# Extract session_id to scope state files per-session (prevents cross-instance interference)
SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // "default"')

GO_STATE=".claude/go-loop-${SESSION_ID}.local.md"
UT_STATE=".claude/ut-loop-${SESSION_ID}.local.md"
E2E_STATE=".claude/e2e-loop-${SESSION_ID}.local.md"

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
ONCE_MODE=$(get_field "$FRONTMATTER" "once")
PROGRESS_PATH=$(get_field "$FRONTMATTER" "progress_path")

# Handle mode for go loop
MODE=""
if [[ "$ACTIVE_LOOP" == "go" ]]; then
  MODE=$(get_field "$FRONTMATTER" "mode")
fi

# Helper to log progress (only if progress_path exists)
log_progress() {
  local json="$1"
  if [[ -n "$PROGRESS_PATH" ]] && [[ -f "$PROGRESS_PATH" ]]; then
    echo "$json" >> "$PROGRESS_PATH"
  fi
}

# =============================================================================
# GUARD 3: Check for --once mode (HITL single iteration)
# =============================================================================
if [[ "$ONCE_MODE" == "true" ]]; then
  echo "✅ Loop ($ACTIVE_LOOP): Single iteration complete (HITL mode)"
  echo "   Run /$ACTIVE_LOOP again to continue, or remove --once for full loop."
  notify "Loop ($ACTIVE_LOOP)" "Iteration complete - ready for review"
  # Log HITL_PAUSE for all loop types
  if [[ "$ACTIVE_LOOP" == "go" ]] && [[ "$MODE" == "prd" ]]; then
    CURRENT_STORY_ID=$(get_field "$FRONTMATTER" "current_story_id")
    log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"story_id\":$CURRENT_STORY_ID,\"status\":\"HITL_PAUSE\",\"notes\":\"Single iteration complete (--once mode)\"}"
  else
    log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"HITL_PAUSE\",\"iteration\":$ITERATION,\"notes\":\"Single iteration complete (--once mode)\"}"
  fi
  rm "$STATE_FILE"
  exit 0
fi

# =============================================================================
# GUARD 4: Validate numeric fields
# =============================================================================
if [[ ! "$ITERATION" =~ ^[0-9]+$ ]]; then
  echo "⚠️  Loop ($ACTIVE_LOOP): State file corrupted" >&2
  echo "   File: $STATE_FILE" >&2
  echo "   Problem: 'iteration' field is not a valid number (got: '$ITERATION')" >&2
  echo "" >&2
  echo "   This usually means the state file was manually edited or corrupted." >&2
  echo "   Loop is stopping. Run /$ACTIVE_LOOP again to start fresh." >&2
  rm "$STATE_FILE"
  exit 0
fi

# Default max_iterations to 0 if not set or invalid
if [[ ! "$MAX_ITERATIONS" =~ ^[0-9]+$ ]]; then
  MAX_ITERATIONS=0
fi

# =============================================================================
# GUARD 5: Check iteration limits
# =============================================================================
# Apply fallback limit if no max_iterations set
EFFECTIVE_MAX=$MAX_ITERATIONS
if [[ $EFFECTIVE_MAX -eq 0 ]]; then
  EFFECTIVE_MAX=$FALLBACK_MAX_ITERATIONS
fi

if [[ $ITERATION -ge $EFFECTIVE_MAX ]]; then
  if [[ $MAX_ITERATIONS -eq 0 ]]; then
    echo "🛑 Loop ($ACTIVE_LOOP): Fallback safety limit ($FALLBACK_MAX_ITERATIONS) reached."
    notify "Loop ($ACTIVE_LOOP)" "Safety limit reached after $ITERATION iterations"
  else
    echo "🛑 Loop ($ACTIVE_LOOP): Max iterations ($MAX_ITERATIONS) reached."
    notify "Loop ($ACTIVE_LOOP)" "Max iterations ($MAX_ITERATIONS) reached"
  fi
  # Log max iterations reached for all loop types
  if [[ "$ACTIVE_LOOP" == "go" ]] && [[ "$MODE" == "prd" ]]; then
    CURRENT_STORY_ID=$(get_field "$FRONTMATTER" "current_story_id")
    log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"story_id\":$CURRENT_STORY_ID,\"status\":\"MAX_ITERATIONS\",\"notes\":\"Loop stopped after $ITERATION iterations\"}"
  else
    log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"MAX_ITERATIONS\",\"iteration\":$ITERATION,\"notes\":\"Loop stopped after $ITERATION iterations\"}"
  fi
  rm "$STATE_FILE"
  exit 0
fi

# =============================================================================
# Get transcript and check for completion
# =============================================================================
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path')

if [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  echo "⚠️  Loop ($ACTIVE_LOOP): Transcript not found - continuing anyway" >&2
  echo "   Expected: $TRANSCRIPT_PATH" >&2
  # Don't terminate - continue the loop (Claude might have only used tools)
fi

# Extract last assistant message (if transcript exists)
LAST_OUTPUT=""
if [[ -f "$TRANSCRIPT_PATH" ]] && grep -q '"role":"assistant"' "$TRANSCRIPT_PATH" 2>/dev/null; then
  LAST_LINE=$(grep '"role":"assistant"' "$TRANSCRIPT_PATH" | tail -1)
  if [[ -n "$LAST_LINE" ]]; then
    # Capture jq output and errors separately
    JQ_RESULT=$(echo "$LAST_LINE" | jq -r '
      .message.content |
      map(select(.type == "text")) |
      map(.text) |
      join("\n")
    ' 2>&1)
    JQ_EXIT=$?
    if [[ $JQ_EXIT -ne 0 ]]; then
      echo "⚠️  Loop ($ACTIVE_LOOP): Failed to parse assistant message JSON - continuing anyway" >&2
      echo "   Error: $JQ_RESULT" >&2
      # Don't terminate - continue the loop
    else
      LAST_OUTPUT="$JQ_RESULT"
    fi
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
    echo "✅ Loop ($ACTIVE_LOOP): Detected <promise>$COMPLETION_PROMISE</promise>"
    echo "   Task complete!"
    notify "Loop ($ACTIVE_LOOP)" "Task complete! $COMPLETION_PROMISE"
    # Log COMPLETED for all loop types
    if [[ "$ACTIVE_LOOP" == "go" ]] && [[ "$MODE" == "prd" ]]; then
      CURRENT_STORY_ID=$(get_field "$FRONTMATTER" "current_story_id")
      log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"story_id\":$CURRENT_STORY_ID,\"status\":\"COMPLETED\",\"notes\":\"Promise fulfilled: $COMPLETION_PROMISE\"}"
    else
      log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"COMPLETED\",\"iteration\":$ITERATION,\"notes\":\"Promise fulfilled: $COMPLETION_PROMISE\"}"
    fi
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
          echo "✅ Loop (go/prd): All stories complete!"
          echo "   Feature '$FEATURE_NAME' is done."
          notify "Loop (go/prd)" "All stories complete! $FEATURE_NAME done"
          if [[ -f "$PROGRESS_PATH" ]]; then
            echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"COMPLETED\",\"notes\":\"All $TOTAL_STORIES stories complete for $FEATURE_NAME\"}" >> "$PROGRESS_PATH"
          fi
          rm "$STATE_FILE"
          exit 0
        fi

        # Advance to next story - rebuild state file
        NEXT_ITERATION=$((ITERATION + 1))
        NEXT_STORY=$(jq ".stories[] | select(.id == $NEXT_STORY_ID)" "$PRD_PATH")
        NEXT_TITLE=$(echo "$NEXT_STORY" | jq -r '.title')
        NEXT_SKILL=$(echo "$NEXT_STORY" | jq -r '.skill // empty')
        INCOMPLETE_COUNT=$(jq '[.stories[] | select(.passes == false)] | length' "$PRD_PATH")

        # Build skill fields for next story
        SKILL_FRONTMATTER=""
        SKILL_SECTION=""
        if [[ -n "$NEXT_SKILL" ]]; then
          SKILL_FRONTMATTER="skill: \"$NEXT_SKILL\""
          SKILL_SECTION="## Required Skill

This story requires the \`$NEXT_SKILL\` skill. **BEFORE implementing**, invoke:

\`\`\`
/Skill $NEXT_SKILL
\`\`\`

Follow the skill's guidance for implementation approach, patterns, and quality standards.
"
        fi

        if [[ -f "$PROGRESS_PATH" ]]; then
          if [[ -n "$NEXT_SKILL" ]]; then
            echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"story_id\":$NEXT_STORY_ID,\"status\":\"STARTED\",\"skill\":\"$NEXT_SKILL\",\"notes\":\"Beginning story #$NEXT_STORY_ID (requires $NEXT_SKILL skill)\"}" >> "$PROGRESS_PATH"
          else
            echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"story_id\":$NEXT_STORY_ID,\"status\":\"STARTED\",\"notes\":\"Beginning story #$NEXT_STORY_ID\"}" >> "$PROGRESS_PATH"
          fi
        fi

        # Build frontmatter (skill line only if present)
        FRONTMATTER_CONTENT="---
mode: \"prd\"
active: true
prd_path: \"$PRD_PATH\"
spec_path: \"$SPEC_PATH\"
progress_path: \"$PROGRESS_PATH\"
feature_name: \"$FEATURE_NAME\"
current_story_id: $NEXT_STORY_ID
total_stories: $TOTAL_STORIES"
        if [[ -n "$SKILL_FRONTMATTER" ]]; then
          FRONTMATTER_CONTENT="$FRONTMATTER_CONTENT
$SKILL_FRONTMATTER"
        fi
        FRONTMATTER_CONTENT="$FRONTMATTER_CONTENT
iteration: $NEXT_ITERATION
max_iterations: $MAX_ITERATIONS
started_at: \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
---"

        # Build content body
        BODY_CONTENT="
# go Loop: $FEATURE_NAME

**Progress:** Story $NEXT_STORY_ID of $TOTAL_STORIES ($INCOMPLETE_COUNT remaining)
**PRD:** \`$PRD_PATH\`
**Spec:** \`$SPEC_PATH\`

## Current Story

\`\`\`json
$NEXT_STORY
\`\`\`

## Task Priority

When multiple stories are available, prioritize in this order:
1. **Architectural decisions** - foundations cascade through everything built on top
2. **Integration points** - reveals incompatibilities early, before dependent work
3. **Unknown unknowns** - fail fast on risky spikes rather than fail late
4. **Standard features** - straightforward implementation work
5. **Polish and cleanup** - can be parallelized or deferred

The hook auto-advances by \`priority\` field, but if you notice a dependency or risk the PRD missed, flag it.

## Code Style

- **MINIMAL COMMENTS** - code should be self-documenting
- Only comment the non-obvious \"why\", never the \"what\"
- Tests should live next to the code they test (colocation)

${SKILL_SECTION}## Your Task

1. Read the full spec at \`$SPEC_PATH\`
2. Implement story #$NEXT_STORY_ID: \"$NEXT_TITLE\"
3. Follow the verification steps listed in the story
4. Write/update tests next to the code they test
5. Run: format, lint, tests, types (all must pass)
6. Update \`$PRD_PATH\`: set \`passes = true\` for story $NEXT_STORY_ID
7. Commit with appropriate type: \`<type>($FEATURE_NAME): story #$NEXT_STORY_ID - $NEXT_TITLE\`

CRITICAL: Only mark the story as passing when it genuinely passes all verification steps."

        # Write state file atomically
        write_state_file "$STATE_FILE" "$FRONTMATTER_CONTENT$BODY_CONTENT"

        PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")
        SYSTEM_MSG="✅ Loop (go/prd): Story #$CURRENT_STORY_ID complete! Now on story #$NEXT_STORY_ID of $TOTAL_STORIES"

        jq -n \
          --arg prompt "$PROMPT_TEXT" \
          --arg msg "$SYSTEM_MSG" \
          '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
        exit 0
      else
        # Story passes but no commit - remind to commit
        NEXT_ITERATION=$((ITERATION + 1))
        update_iteration "$STATE_FILE" "$NEXT_ITERATION"

        PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")
        SYSTEM_MSG="⚠️  Loop (go/prd): Story #$CURRENT_STORY_ID passes but NO COMMIT found. Commit: feat($FEATURE_NAME): story #$CURRENT_STORY_ID"

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

update_iteration "$STATE_FILE" "$NEXT_ITERATION"

# Extract prompt (everything after the closing ---)
PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")

if [[ -z "$PROMPT_TEXT" ]]; then
  echo "⚠️  Loop ($ACTIVE_LOOP): State file corrupted or incomplete" >&2
  echo "   File: $STATE_FILE" >&2
  echo "   Problem: No prompt text found after frontmatter" >&2
  echo "" >&2
  echo "   This usually means:" >&2
  echo "     - State file was manually edited" >&2
  echo "     - File was corrupted during writing" >&2
  echo "" >&2
  echo "   Loop is stopping. Run /$ACTIVE_LOOP again to start fresh." >&2
  rm "$STATE_FILE"
  exit 0
fi

# Build system message based on loop type and log ITERATION
case "$ACTIVE_LOOP" in
  go)
    if [[ "$MODE" == "prd" ]]; then
      CURRENT_STORY_ID=$(get_field "$FRONTMATTER" "current_story_id")
      SYSTEM_MSG="🔄 Loop (go/prd) iteration $NEXT_ITERATION | Story #$CURRENT_STORY_ID not yet passing"
      log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"story_id\":$CURRENT_STORY_ID,\"status\":\"ITERATION\",\"notes\":\"Iteration $NEXT_ITERATION - story not yet passing\"}"
    else
      SYSTEM_MSG="🔄 Loop (go) iteration $NEXT_ITERATION | Output <promise>$COMPLETION_PROMISE</promise> when done"
      log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"ITERATION\",\"iteration\":$NEXT_ITERATION,\"notes\":\"Continuing generic loop\"}"
    fi
    ;;
  ut)
    TARGET_COVERAGE=$(get_field "$FRONTMATTER" "target_coverage")
    if [[ -n "$TARGET_COVERAGE" ]] && [[ "$TARGET_COVERAGE" != "0" ]]; then
      SYSTEM_MSG="🔄 Loop (ut) iteration $NEXT_ITERATION | Target: ${TARGET_COVERAGE}% | Output <promise>$COMPLETION_PROMISE</promise> when done"
      log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"ITERATION\",\"iteration\":$NEXT_ITERATION,\"target_coverage\":$TARGET_COVERAGE,\"notes\":\"Continuing unit test loop\"}"
    else
      SYSTEM_MSG="🔄 Loop (ut) iteration $NEXT_ITERATION | Output <promise>$COMPLETION_PROMISE</promise> when done"
      log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"ITERATION\",\"iteration\":$NEXT_ITERATION,\"notes\":\"Continuing unit test loop\"}"
    fi
    ;;
  e2e)
    SYSTEM_MSG="🔄 Loop (e2e) iteration $NEXT_ITERATION | Output <promise>$COMPLETION_PROMISE</promise> when all flows covered"
    log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"ITERATION\",\"iteration\":$NEXT_ITERATION,\"notes\":\"Continuing E2E test loop\"}"
    ;;
esac

# Output JSON to block stop and continue loop
jq -n \
  --arg prompt "$PROMPT_TEXT" \
  --arg msg "$SYSTEM_MSG" \
  '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'

exit 0
