#!/bin/bash

# Unified Stop Hook
# Handles all loop types: go, ut, e2e
# Prevents session exit when any loop is active

set -euo pipefail

# Fallback safety limit - prevents runaway loops even if max_iterations not set
FALLBACK_MAX_ITERATIONS=100

# =============================================================================
# Cross-platform helper functions (macOS/Linux/Windows Git Bash)
# =============================================================================

# Portable regex extraction using BASH_REMATCH (no grep -P needed)
# Usage: extract_regex "string" "pattern_with_capture_group"
# Returns first capture group or empty string
extract_regex() {
  local string="$1"
  local pattern="$2"
  if [[ $string =~ $pattern ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# Portable sed in-place edit (works on macOS, Linux, Windows Git Bash)
# Usage: sed_inplace "s/old/new/" "file"
sed_inplace() {
  local expr="$1"
  local file="$2"
  local temp_file="${file}.tmp.$$"
  sed "$expr" "$file" > "$temp_file" && mv "$temp_file" "$file"
}

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
PRD_STATE=".claude/prd-loop-${SESSION_ID}.local.md"

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
elif [[ -f "$PRD_STATE" ]]; then
  ACTIVE_LOOP="prd"
  STATE_FILE="$PRD_STATE"
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
# GUARD 3: Check for --once mode (HITL single iteration) - skip for prd
# =============================================================================
if [[ "$ACTIVE_LOOP" != "prd" ]] && [[ "$ONCE_MODE" == "true" ]]; then
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
# GUARD 4: Validate numeric fields (skip for prd - uses phases not iterations)
# =============================================================================
if [[ "$ACTIVE_LOOP" != "prd" ]]; then
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
fi

# =============================================================================
# GUARD 5: Check iteration limits (skip for prd - uses phases not iterations)
# =============================================================================
if [[ "$ACTIVE_LOOP" != "prd" ]]; then
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
# Handle PRD loop (phased workflow - separate from iteration-based loops)
# =============================================================================
if [[ "$ACTIVE_LOOP" == "prd" ]]; then
  CURRENT_PHASE=$(get_field "$FRONTMATTER" "current_phase")
  FEATURE_NAME=$(get_field "$FRONTMATTER" "feature_name")
  INPUT_TYPE=$(get_field "$FRONTMATTER" "input_type")
  INPUT_PATH=$(get_field "$FRONTMATTER" "input_path")
  INPUT_RAW=$(get_field "$FRONTMATTER" "input_raw")
  SPEC_PATH=$(get_field "$FRONTMATTER" "spec_path")
  PRD_PATH=$(get_field "$FRONTMATTER" "prd_path")
  INTERVIEW_QUESTIONS=$(get_field "$FRONTMATTER" "interview_questions")
  GATE_STATUS=$(get_field "$FRONTMATTER" "gate_status")
  REVIEW_COUNT=$(get_field "$FRONTMATTER" "review_count")
  RETRY_COUNT=$(get_field "$FRONTMATTER" "retry_count")

  # Default numeric fields
  [[ ! "$INTERVIEW_QUESTIONS" =~ ^[0-9]+$ ]] && INTERVIEW_QUESTIONS=0
  [[ ! "$REVIEW_COUNT" =~ ^[0-9]+$ ]] && REVIEW_COUNT=0
  [[ ! "$RETRY_COUNT" =~ ^[0-9]+$ ]] && RETRY_COUNT=0

  # Max retries before asking user for help
  MAX_RETRIES=3

  # Parse structured output markers from LAST_OUTPUT
  PHASE_COMPLETE=""
  PHASE_FEATURE=""
  MAX_ITER_TAG=""
  GATE_DECISION=""

  if [[ -n "$LAST_OUTPUT" ]]; then
    # <phase_complete phase="N" feature_name="NAME"/>
    PHASE_COMPLETE=$(extract_regex "$LAST_OUTPUT" '<phase_complete phase="([^"]+)"')
    PHASE_FEATURE=$(extract_regex "$LAST_OUTPUT" '<phase_complete[^>]*feature_name="([^"]+)"')

    # <max_iterations>N</max_iterations>
    MAX_ITER_TAG=$(extract_regex "$LAST_OUTPUT" '<max_iterations>([0-9]+)</max_iterations>')

    # <gate_decision>PROCEED|BLOCK</gate_decision>
    GATE_DECISION=$(extract_regex "$LAST_OUTPUT" '<gate_decision>([^<]+)</gate_decision>')
  fi

  # Helper function to generate phase-specific prompt
  generate_prd_phase_prompt() {
    local phase="$1"
    local prompt=""

    case "$phase" in
      "2")
        prompt="# PRD Loop: Phase 2 - Deep Interview

**Feature:** $FEATURE_NAME

## Your Task

Conduct a thorough interview using AskUserQuestion. Interview in waves:

**Wave 1 - Core Understanding** (if not done)
- What problem does this solve? For whom?
- What does success look like?
- What's the MVP vs nice-to-have?

**Wave 2 - Technical Deep Dive**
- What systems/services does this touch?
- What data models are involved?
- What existing code patterns should we follow?

**Wave 3 - UX/UI Details**
- Walk through the user flow step by step
- What happens on errors? Edge cases?

**Wave 4 - Edge Cases & Concerns**
- What could go wrong?
- Security implications?

**Wave 5 - Tradeoffs & Decisions**
- What are you willing to compromise on?
- What's non-negotiable?

**Rules:**
- Ask ONE focused question at a time
- Go deep on answers - ask follow-ups
- Continue until you have enough detail to write implementation code (minimum 8-10 questions)

**After Wave 1 (3-4 questions)**, output:
\`\`\`
<phase_complete phase=\"2\" next=\"2.5\"/>
\`\`\`

This triggers research phase before continuing interview."
        ;;
      "2.5")
        prompt="# PRD Loop: Phase 2.5 - Research

**Feature:** $FEATURE_NAME

## Your Task

PAUSE interviewing. Spawn research agents IN PARALLEL (single message, multiple Task tool calls):

1. **Codebase Research**
   - subagent_type: \"prd-codebase-researcher\"
   - prompt: \"Research codebase for $FEATURE_NAME. Find existing patterns, files to modify, models, services, test patterns.\"

2. **Git History**
   - subagent_type: \"compound-engineering:research:git-history-analyzer\"
   - prompt: \"Analyze git history for code related to $FEATURE_NAME. Find prior attempts, key contributors, why patterns evolved.\"

3. **External Research**
   - subagent_type: \"prd-external-researcher\"
   - prompt: \"Research $FEATURE_NAME using Exa. Find best practices, code examples, pitfalls to avoid.\"

After all agents return, store findings and output:
\`\`\`
<phase_complete phase=\"2.5\" next=\"2\"/>
\`\`\`

Continue interviewing with research context (Waves 2-5).
When interview complete (8-10+ questions total), output:
\`\`\`
<phase_complete phase=\"2\" next=\"3\"/>
\`\`\`"
        ;;
      "3")
        prompt="# PRD Loop: Phase 3 - Write Spec

**Feature:** $FEATURE_NAME

## Your Task

Synthesize interview answers and research into a comprehensive spec.

**Spec Structure:**
\`\`\`markdown
# $FEATURE_NAME Specification

## Overview
## Problem Statement
## Success Criteria
## User Stories (As a X, I want Y, so that Z)
## Detailed Requirements
### Functional Requirements
### Non-Functional Requirements
### UI/UX Specifications
## Technical Design
### Data Models
### API Contracts
### System Interactions
### Implementation Notes
## Edge Cases & Error Handling
## Open Questions
## Out of Scope
## Review Findings (populated in Phase 3.5)
## References
\`\`\`

**Write to:** \`plans/$FEATURE_NAME/spec.md\`

After writing spec, output:
\`\`\`
<phase_complete phase=\"3\" spec_path=\"plans/$FEATURE_NAME/spec.md\"/>
\`\`\`"
        ;;
      "3.5")
        prompt="# PRD Loop: Phase 3.5 - Spec Review

**Feature:** $FEATURE_NAME
**Spec:** \`$SPEC_PATH\`

## Your Task

Spawn 4 reviewers IN PARALLEL (single message, multiple Task tool calls).
Read the spec first, then pass content to each reviewer.

1. **Flow Analysis**
   - subagent_type: \"compound-engineering:workflow:spec-flow-analyzer\"

2. **Architecture Review**
   - subagent_type: \"compound-engineering:review:architecture-strategist\"

3. **Security Review**
   - subagent_type: \"compound-engineering:review:security-sentinel\"

4. **Plan Review**
   - subagent_type: \"compound-engineering:plan_review\"

**After reviews complete:**
- Add critical items to spec's \"Review Findings\" section
- Update User Stories if reviewers found missing flows

**Gate Decision:**
If critical security/architecture issues found, use AskUserQuestion:
\"Reviewers found <issues>. Address now or proceed to PRD generation?\"

Output gate decision:
\`\`\`
<gate_decision>PROCEED</gate_decision>
\`\`\`
or
\`\`\`
<gate_decision>BLOCK</gate_decision>
\`\`\`

If BLOCK, address issues then re-output PROCEED."
        ;;
      "4")
        prompt="# PRD Loop: Phase 4 - Generate PRD JSON

**Feature:** $FEATURE_NAME
**Spec:** \`$SPEC_PATH\`

## Your Task

Parse User Stories from spec and create PRD JSON.

**Story size rules:**
- Each story = ONE iteration of /go (~15-30 min work)
- If >7 verification steps, it's too big - break it down
- If touches >3 files, consider splitting
- If \"and\" in title, probably 2 stories

**Atomic story checklist (ALL must be true):**
- [ ] Single responsibility - does exactly ONE thing
- [ ] Independently testable - can verify without other stories
- [ ] No partial state - either fully done or not started
- [ ] Clean rollback - can revert with single \`git revert\`
- [ ] Clear done criteria - unambiguous when complete

**Anti-patterns (split if you see these):**
- \"Set up X and implement Y\" → 2 stories
- \"Add model, controller, and view\" → 3 stories
- \"Handle success and error cases\" → 2 stories
- Steps that depend on earlier steps succeeding → separate stories

**Write to:** \`plans/$FEATURE_NAME/prd.json\`

\`\`\`json
{
  \"title\": \"$FEATURE_NAME\",
  \"stories\": [
    {
      \"id\": 1,
      \"title\": \"Story title\",
      \"category\": \"functional|ui|integration|edge-case|performance\",
      \"skill\": \"frontend-design\",  // only for ui category
      \"steps\": [\"Step 1\", \"Step 2\", ...],
      \"passes\": false,
      \"priority\": 1
    }
  ],
  \"created_at\": \"ISO8601\",
  \"source_spec\": \"$SPEC_PATH\"
}
\`\`\`

After writing PRD, output:
\`\`\`
<phase_complete phase=\"4\" prd_path=\"plans/$FEATURE_NAME/prd.json\"/>
\`\`\`"
        ;;
      "5")
        prompt="# PRD Loop: Phase 5 - Create Progress File

**Feature:** $FEATURE_NAME
**PRD:** \`$PRD_PATH\`

## Your Task

Write progress file to: \`plans/$FEATURE_NAME/progress.txt\`

\`\`\`
# Progress Log: $FEATURE_NAME
# Each line: JSON object with ts, story_id, status, notes
# Status values: STARTED, PASSED, FAILED, BLOCKED
\`\`\`

After creating progress file, output:
\`\`\`
<phase_complete phase=\"5\" progress_path=\"plans/$FEATURE_NAME/progress.txt\"/>
\`\`\`"
        ;;
      "5.5")
        prompt="# PRD Loop: Phase 5.5 - Complexity Estimation

**Feature:** $FEATURE_NAME
**PRD:** \`$PRD_PATH\`
**Spec:** \`$SPEC_PATH\`

## Your Task

Spawn the complexity estimator agent:

- subagent_type: \"prd-complexity-estimator\"
- prompt: \"Estimate complexity for this PRD. <prd_json>{read PRD}</prd_json> <spec_content>{read spec}</spec_content>\"

The agent will research the codebase and return a recommended max_iterations value.

**REQUIRED:** After the agent returns, output:
\`\`\`
<max_iterations>N</max_iterations>
\`\`\`

Where N is the agent's recommended value."
        ;;
      "6")
        prompt="# PRD Loop: Phase 6 - Generate Go Command

**Feature:** $FEATURE_NAME
**PRD:** \`$PRD_PATH\`
**Max iterations:** $MAX_ITERATIONS

## Your Task

1. Copy go command to clipboard:
\`\`\`bash
cmd='/go $PRD_PATH --max-iterations $MAX_ITERATIONS'
case \"\$(uname -s)\" in
  Darwin) echo \"\$cmd\" | pbcopy ;;
  Linux) echo \"\$cmd\" | xclip -selection clipboard 2>/dev/null || echo \"\$cmd\" | xsel --clipboard 2>/dev/null ;;
  MINGW*|MSYS*|CYGWIN*) echo \"\$cmd\" | clip.exe ;;
esac
\`\`\`

2. Use AskUserQuestion:
\"PRD ready! Files created:
- \`plans/$FEATURE_NAME/spec.md\`
- \`plans/$FEATURE_NAME/prd.json\`
- \`plans/$FEATURE_NAME/progress.txt\`

Go command copied to clipboard. What next?\"

Options:
- **Run /go now** - Full loop
- **Run /go --once** - HITL mode (recommended for first-time PRDs)
- **Done** - Files ready for later

After user responds, output:
\`\`\`
<phase_complete phase=\"6\"/>
\`\`\`"
        ;;
    esac

    echo "$prompt"
  }

  # ===========================================================================
  # Error Recovery: Track retries when no valid marker found
  # ===========================================================================
  # Determine which marker is expected for current phase
  EXPECTED_MARKER=""
  case "$CURRENT_PHASE" in
    "5.5") EXPECTED_MARKER="<max_iterations>N</max_iterations>" ;;
    "3.5") EXPECTED_MARKER="<gate_decision>PROCEED|BLOCK</gate_decision>" ;;
    *)     EXPECTED_MARKER="<phase_complete phase=\"$CURRENT_PHASE\" .../>" ;;
  esac

  # Check if we got a valid marker for the current phase
  VALID_MARKER_FOUND=false
  case "$CURRENT_PHASE" in
    "5.5")
      [[ -n "$MAX_ITER_TAG" ]] && VALID_MARKER_FOUND=true
      ;;
    "3.5")
      [[ -n "$GATE_DECISION" ]] && VALID_MARKER_FOUND=true
      ;;
    *)
      [[ -n "$PHASE_COMPLETE" ]] && VALID_MARKER_FOUND=true
      ;;
  esac

  if [[ "$VALID_MARKER_FOUND" == "true" ]]; then
    # Reset retry count on success
    if [[ $RETRY_COUNT -gt 0 ]]; then
      sed_inplace "s/^retry_count: .*/retry_count: 0/" "$STATE_FILE"
      sed_inplace "s/^last_error: .*/last_error: \"\"/" "$STATE_FILE"
    fi
  else
    # No valid marker found - increment retry count
    RETRY_COUNT=$((RETRY_COUNT + 1))
    sed_inplace "s/^retry_count: .*/retry_count: $RETRY_COUNT/" "$STATE_FILE"

    # Compact error summary (first 100 chars of output or "no output")
    if [[ -n "$LAST_OUTPUT" ]]; then
      ERROR_SUMMARY=$(echo "$LAST_OUTPUT" | head -c 200 | tr '\n' ' ' | sed 's/"/\\"/g')
    else
      ERROR_SUMMARY="No text output from Claude (only tool calls)"
    fi
    sed_inplace "s/^last_error: .*/last_error: \"$ERROR_SUMMARY\"/" "$STATE_FILE"

    if [[ $RETRY_COUNT -ge $MAX_RETRIES ]]; then
      # Max retries reached - stop and ask user for help
      echo "⚠️  Loop (prd): Phase $CURRENT_PHASE failed after $MAX_RETRIES attempts" >&2
      echo "" >&2
      echo "   Expected marker: $EXPECTED_MARKER" >&2
      echo "   Last output: ${ERROR_SUMMARY:0:100}..." >&2
      echo "" >&2
      echo "   The loop is pausing for your help." >&2
      echo "   Options:" >&2
      echo "     - Check Claude's output and guide it to produce the marker" >&2
      echo "     - Run /cancel-prd to stop the loop" >&2
      echo "     - Manually edit the state file to advance phase" >&2
      notify "Loop (prd)" "Phase $CURRENT_PHASE needs help after $MAX_RETRIES retries"

      # Don't delete state file - let user intervene
      # Return a prompt asking for the expected output
      RECOVERY_PROMPT="# PRD Loop: Recovery Needed

**Phase $CURRENT_PHASE failed after $MAX_RETRIES attempts.**

I couldn't find the expected output marker in your response.

**Expected:** \`$EXPECTED_MARKER\`

**What I saw:** ${ERROR_SUMMARY:0:200}

## Please Help

Either:
1. Output the expected marker now
2. Tell me what's blocking you so I can help

$(generate_prd_phase_prompt "$CURRENT_PHASE")"

      jq -n \
        --arg prompt "$RECOVERY_PROMPT" \
        --arg msg "⚠️  Loop (prd): Phase $CURRENT_PHASE needs help - no valid marker found after $MAX_RETRIES attempts" \
        '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
      exit 0
    else
      # Retry - continue with same phase prompt + hint
      SYSTEM_MSG="🔄 Loop (prd): Phase $CURRENT_PHASE retry $RETRY_COUNT/$MAX_RETRIES - expected marker not found"
      PROMPT_TEXT=$(generate_prd_phase_prompt "$CURRENT_PHASE")
      PROMPT_TEXT="$PROMPT_TEXT

---
**Note:** Previous attempt didn't include the expected marker. Please ensure your response ends with:
\`$EXPECTED_MARKER\`"

      jq -n --arg prompt "$PROMPT_TEXT" --arg msg "$SYSTEM_MSG" '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
      exit 0
    fi
  fi

  # Update feature name if provided in phase completion
  if [[ -n "$PHASE_FEATURE" ]]; then
    FEATURE_NAME="$PHASE_FEATURE"
  fi


  # Handle phase transitions
  NEXT_PHASE=""
  SYSTEM_MSG=""

  # Phase 5.5: max_iterations tag detected
  if [[ -n "$MAX_ITER_TAG" ]] && [[ "$CURRENT_PHASE" == "5.5" ]]; then
    NEXT_PHASE="6"
    # Update max_iterations in state (for phase 6 prompt generation)
    sed_inplace "s/^max_iterations: .*/max_iterations: $MAX_ITER_TAG/" "$STATE_FILE"
    MAX_ITERATIONS="$MAX_ITER_TAG"
    SYSTEM_MSG="✅ Loop (prd): Phase 5.5 complete! max_iterations=$MAX_ITER_TAG. Advancing to phase 6."
  fi

  # Phase 3.5: gate decision detected
  if [[ -n "$GATE_DECISION" ]] && [[ "$CURRENT_PHASE" == "3.5" ]]; then
    if [[ "$GATE_DECISION" == "PROCEED" ]]; then
      NEXT_PHASE="4"
      sed_inplace "s/^gate_status: .*/gate_status: proceed/" "$STATE_FILE"
      SYSTEM_MSG="✅ Loop (prd): Review gate passed! Advancing to phase 4."
    elif [[ "$GATE_DECISION" == "BLOCK" ]]; then
      # Stay on phase 3.5, user needs to address issues
      REVIEW_COUNT=$((REVIEW_COUNT + 1))
      sed_inplace "s/^review_count: .*/review_count: $REVIEW_COUNT/" "$STATE_FILE"
      sed_inplace "s/^gate_status: .*/gate_status: blocked/" "$STATE_FILE"
      SYSTEM_MSG="⚠️  Loop (prd): Review gate blocked. Address issues then output <gate_decision>PROCEED</gate_decision>"
      # Continue without advancing
      PROMPT_TEXT=$(generate_prd_phase_prompt "3.5")
      jq -n --arg prompt "$PROMPT_TEXT" --arg msg "$SYSTEM_MSG" '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
      exit 0
    fi
  fi

  # Generic phase completion
  if [[ -n "$PHASE_COMPLETE" ]]; then
    # Extract next phase from marker if present
    MARKER_NEXT=$(extract_regex "$LAST_OUTPUT" '<phase_complete[^>]*next="([^"]+)"')

    # Determine next phase based on current phase
    case "$CURRENT_PHASE" in
      "1") NEXT_PHASE="${MARKER_NEXT:-2}" ;;
      "2")
        if [[ "$MARKER_NEXT" == "2.5" ]]; then
          NEXT_PHASE="2.5"
        elif [[ "$MARKER_NEXT" == "3" ]]; then
          NEXT_PHASE="3"
        else
          NEXT_PHASE="2.5"  # Default to research after wave 1
        fi
        ;;
      "2.5") NEXT_PHASE="${MARKER_NEXT:-2}" ;;  # Back to interview
      "3")
        NEXT_PHASE="3.5"
        # Extract spec_path from marker
        MARKER_SPEC=$(extract_regex "$LAST_OUTPUT" '<phase_complete[^>]*spec_path="([^"]+)"')
        if [[ -n "$MARKER_SPEC" ]]; then
          SPEC_PATH="$MARKER_SPEC"
          sed_inplace "s|^spec_path: .*|spec_path: \"$SPEC_PATH\"|" "$STATE_FILE"
        fi
        ;;
      "3.5") NEXT_PHASE="4" ;;  # Only reached if gate_decision not detected
      "4")
        NEXT_PHASE="5"
        # Extract prd_path from marker
        MARKER_PRD=$(extract_regex "$LAST_OUTPUT" '<phase_complete[^>]*prd_path="([^"]+)"')
        if [[ -n "$MARKER_PRD" ]]; then
          PRD_PATH="$MARKER_PRD"
          sed_inplace "s|^prd_path: .*|prd_path: \"$PRD_PATH\"|" "$STATE_FILE"
        fi
        ;;
      "5")
        NEXT_PHASE="5.5"
        # Extract progress_path from marker
        MARKER_PROGRESS=$(extract_regex "$LAST_OUTPUT" '<phase_complete[^>]*progress_path="([^"]+)"')
        if [[ -n "$MARKER_PROGRESS" ]]; then
          sed_inplace "s|^progress_path: .*|progress_path: \"$MARKER_PROGRESS\"|" "$STATE_FILE"
        fi
        ;;
      "5.5") NEXT_PHASE="6" ;;
      "6")
        # PRD complete!
        echo "✅ Loop (prd): All phases complete! PRD ready."
        notify "Loop (prd)" "PRD complete for $FEATURE_NAME!"
        rm "$STATE_FILE"
        exit 0
        ;;
    esac
    SYSTEM_MSG="✅ Loop (prd): Phase $CURRENT_PHASE complete! Advancing to phase $NEXT_PHASE."
  fi

  # If no phase transition detected, continue current phase
  if [[ -z "$NEXT_PHASE" ]]; then
    SYSTEM_MSG="🔄 Loop (prd): Phase $CURRENT_PHASE continuing..."
    PROMPT_TEXT=$(generate_prd_phase_prompt "$CURRENT_PHASE")
    jq -n --arg prompt "$PROMPT_TEXT" --arg msg "$SYSTEM_MSG" '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
    exit 0
  fi

  # Update state file with new phase
  sed_inplace "s/^current_phase: .*/current_phase: \"$NEXT_PHASE\"/" "$STATE_FILE"

  # Update feature_name if changed
  sed_inplace "s/^feature_name: .*/feature_name: \"$FEATURE_NAME\"/" "$STATE_FILE"

  # Generate new phase prompt
  PROMPT_TEXT=$(generate_prd_phase_prompt "$NEXT_PHASE")

  # Update state file body with new prompt
  # Remove old body (everything after second ---) and append new
  # Note: Using sed '$d' instead of 'head -n -1' for BSD/macOS compatibility
  FRONTMATTER_CONTENT=$(sed -n '1,/^---$/p' "$STATE_FILE" | sed '$d')
  FRONTMATTER_END=$(grep -n '^---$' "$STATE_FILE" | head -2 | tail -1 | cut -d: -f1)
  HEAD_CONTENT=$(head -n "$FRONTMATTER_END" "$STATE_FILE")
  write_state_file "$STATE_FILE" "$HEAD_CONTENT

$PROMPT_TEXT"

  jq -n --arg prompt "$PROMPT_TEXT" --arg msg "$SYSTEM_MSG" '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
  exit 0
fi

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
