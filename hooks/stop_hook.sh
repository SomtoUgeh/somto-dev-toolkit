#!/bin/bash

# =============================================================================
# UNIFIED STOP HOOK - Architecture Overview
# =============================================================================
#
# PURPOSE: Intercepts session exit to enforce iterative workflows (loops).
#          When a loop is active, blocks exit and feeds prompts back to Claude.
#
# SUPPORTED LOOPS:
#   - go:  Generic task loop OR PRD-based story implementation
#   - ut:  Unit test coverage improvement loop
#   - e2e: Playwright E2E test development loop
#   - prd: PRD generation workflow (6 phases with structured output markers)
#
# CONTROL FLOW:
#   1. GUARDS: Check for recursion, validate session_id, find active loop
#   2. PARSE:  Read state file frontmatter (YAML between first two ---)
#   3. LIMITS: Check iteration/once mode, enforce max_iterations
#   4. OUTPUT: Parse Claude's last output for structured markers
#   5. ROUTE:  Branch to loop-specific logic:
#      - PRD: Phase transitions via <phase_complete>, <gate_decision>, etc.
#      - Go/PRD mode: Story completion via <story_complete>, <reviews_complete>
#      - UT/E2E: Iteration via <iteration_complete>, <reviews_complete>
#   6. BLOCK:  Output JSON to block exit and inject next prompt
#
# STATE FILES: .claude/{go,ut,e2e,prd}-loop-{session_id}.local.md
#   Format: YAML frontmatter (---...---) + markdown body (prompt)
#   Key fields: iteration, max_iterations, completion_promise, current_phase, etc.
#
# STRUCTURED OUTPUT MARKERS (parsed from Claude's response):
#   - <phase_complete phase="N" .../>  - PRD phase transitions
#   - <gate_decision>PROCEED|BLOCK</gate_decision> - PRD review gate
#   - <max_iterations>N</max_iterations> - PRD complexity estimate
#   - <story_complete story_id="N"/> - Go/PRD story completion
#   - <iteration_complete test_file="..."/> - UT/E2E iteration
#   - <reviews_complete/> - Confirms code reviews ran
#   - <promise>TEXT</promise> - Loop completion signal
#
# SECURITY HARDENING:
#   - Session ID validation (alphanumeric only, no path traversal)
#   - sed escaping for user-derived values (escape_sed_replacement)
#   - Frontmatter parsing scoped to first two --- only
#   - Phase marker validation (must match current phase)
#   - Story ID word boundaries (prevents #1 matching #10)
#   - Recovery prompts for malformed state (vs silent abort)
#
# =============================================================================

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
  return 0
}

# Usage: extract_regex_last "string" "pattern"
# Returns LAST match's capture group (or full match if no capture group)
# Handles patterns with or without capture groups, glob metacharacters, and backslashes (Windows paths)
extract_regex_last() {
  local string="$1"
  local pattern="$2"
  local last_match=""
  local full_match=""

  # Iterate through all matches, keeping the last one
  local remaining="$string"
  while [[ $remaining =~ $pattern ]]; do
    full_match="${BASH_REMATCH[0]}"
    # Use capture group if present, otherwise use full match
    if [[ ${#BASH_REMATCH[@]} -gt 1 ]] && [[ -n "${BASH_REMATCH[1]+x}" ]]; then
      last_match="${BASH_REMATCH[1]}"
    else
      last_match="$full_match"
    fi

    # Find match position and use substring to advance (safer than pattern-based removal)
    # Uses ENVIRON instead of -v to handle newlines and backslashes (Windows paths)
    local match_pos
    export _AWK_STR="$remaining"
    export _AWK_NEEDLE="$full_match"
    match_pos=$(awk 'BEGIN {
      str = ENVIRON["_AWK_STR"]
      needle = ENVIRON["_AWK_NEEDLE"]
      pos = index(str, needle)
      if (pos > 0) print pos + length(needle) - 1
      else print 0
    }')
    unset _AWK_STR _AWK_NEEDLE

    if [[ "$match_pos" -gt 0 ]] && [[ "$match_pos" -lt "${#remaining}" ]]; then
      remaining="${remaining:$match_pos}"
    else
      # No more content after match, exit loop
      break
    fi
  done

  [[ -n "$last_match" ]] && printf '%s' "$last_match"
  return 0
}

# Extract last <promise> tag from output (whitespace normalized)
extract_promise_last() {
  local text="$1"
  local normalized
  normalized=$(printf '%s' "$text" | tr '\r\n' ' ')
  normalized=$(printf '%s' "$normalized" | sed 's/[[:space:]]\+/ /g')
  local promise
  promise=$(extract_regex_last "$normalized" '<promise>([^<]*)</promise>')
  # Trim leading/trailing whitespace
  promise="${promise#"${promise%%[![:space:]]*}"}"
  promise="${promise%"${promise##*[![:space:]]}"}"
  printf '%s' "$promise"
  return 0
}

# Escape special characters for sed replacement string
# Escapes: / & \ | newlines (prevents injection when variable contains these)
# Usage: ESCAPED=$(escape_sed_replacement "$UNSAFE_VALUE")
escape_sed_replacement() {
  local str="$1"
  # Escape backslashes first, then other special chars
  str="${str//\\/\\\\}"
  str="${str//\//\\/}"
  str="${str//&/\\&}"
  str="${str//|/\\|}"
  # Replace newlines with \n (literal)
  str="${str//$'\n'/\\n}"
  printf '%s' "$str"
}

# Portable sed in-place edit (works on macOS, Linux, Windows Git Bash)
# Usage: sed_inplace "s/old/new/" "file"
# WARNING: If replacement contains user input, use escape_sed_replacement first!
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

# Show loop completion summary (works for go, ut, e2e)
# Usage: show_loop_summary "$STATE_FILE" "$ITERATION"
show_loop_summary() {
  local state_file="$1"
  local iteration="$2"

  # Extract started_at from state file
  local started_at=""
  if [[ -f "$state_file" ]]; then
    started_at=$(sed -n 's/^started_at: "\(.*\)"/\1/p' "$state_file" | head -1)
  fi

  # Calculate duration
  local duration_str="unknown"
  if [[ -n "$started_at" ]]; then
    local start_epoch end_epoch
    case "$(uname -s)" in
      Darwin)
        start_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started_at" "+%s" 2>/dev/null || echo "")
        ;;
      *)
        start_epoch=$(date -d "$started_at" "+%s" 2>/dev/null || echo "")
        ;;
    esac
    if [[ -n "$start_epoch" ]]; then
      end_epoch=$(date "+%s")
      local elapsed=$((end_epoch - start_epoch))
      local mins=$((elapsed / 60))
      local secs=$((elapsed % 60))
      if [[ $mins -gt 0 ]]; then
        duration_str="${mins}m ${secs}s"
      else
        duration_str="${secs}s"
      fi
    fi
  fi

  # Get git stats (files changed, insertions, deletions)
  local git_stats=""
  if git rev-parse --git-dir >/dev/null 2>&1; then
    local base_branch="main"
    git rev-parse --verify "$base_branch" >/dev/null 2>&1 || base_branch="master"
    git_stats=$(git diff "$base_branch" --stat 2>/dev/null | tail -1 || echo "")
  fi

  # Get commit count since loop started
  local commit_count=0
  if [[ -n "$started_at" ]] && git rev-parse --git-dir >/dev/null 2>&1; then
    commit_count=$(git log --since="$started_at" --oneline 2>/dev/null | wc -l | tr -d ' ')
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "📊 Loop Summary"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "   Iterations: $iteration"
  echo "   Duration:   $duration_str"
  [[ "$commit_count" -gt 0 ]] && echo "   Commits:    $commit_count"
  [[ -n "$git_stats" ]] && echo "   Changes:    $git_stats"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Validate JSON input (prevents silent failures with set -e)
if [[ -z "$HOOK_INPUT" ]]; then
  echo "Error: No hook input received from stdin" >&2
  exit 0  # Exit cleanly - no input means nothing to process
fi

if ! echo "$HOOK_INPUT" | jq empty 2>/dev/null; then
  echo "Error: Hook input is not valid JSON" >&2
  echo "Input received: ${HOOK_INPUT:0:200}..." >&2
  exit 0  # Exit cleanly - can't process invalid input
fi

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

# Sanitize SESSION_ID to prevent path traversal (only allow alphanumeric, hyphen, underscore)
if [[ ! "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "Error: Invalid session_id format '$SESSION_ID' (must be alphanumeric/hyphen/underscore only)" >&2
  # Check if ANY loop state files exist - list them so user can clean up stale files
  STATE_FILES=$(ls .claude/*-loop-*.local.md 2>/dev/null || true)
  if [[ -n "$STATE_FILES" ]]; then
    echo "       Loop state files found (may be stale):" >&2
    echo "$STATE_FILES" | while read -r f; do
      if [[ -n "$f" ]]; then
        MTIME=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$f" 2>/dev/null || stat -c "%y" "$f" 2>/dev/null | cut -d. -f1 || echo "unknown")
        echo "         - $f (modified: $MTIME)" >&2
      fi
    done
    echo "" >&2
    echo "       If these are stale, remove them: rm .claude/*-loop-*.local.md" >&2
    # Allow exit since we can't validate which session owns these files
    echo "       Allowing exit (can't validate session ownership)." >&2
    exit 0
  fi
  echo "       No active loops. Allowing exit." >&2
  exit 0
fi

GO_STATE=".claude/go-loop-${SESSION_ID}.local.md"
UT_STATE=".claude/ut-loop-${SESSION_ID}.local.md"
E2E_STATE=".claude/e2e-loop-${SESSION_ID}.local.md"
PRD_STATE=".claude/prd-loop-${SESSION_ID}.local.md"

# =============================================================================
# Session Indexing for qmd (background, non-blocking)
# =============================================================================
# This trap runs on exit to index the current session for /fork-detect
# Only indexes if no active loop (session truly ending) and qmd is available
index_session_for_qmd() {
  # Skip if a loop is active (will block, not truly exiting)
  [[ -f "$GO_STATE" || -f "$UT_STATE" || -f "$E2E_STATE" || -f "$PRD_STATE" ]] && return 0

  # Skip if qmd not installed
  command -v qmd &>/dev/null || return 0

  # Get project path from hook input
  local project_path
  project_path=$(echo "$HOOK_INPUT" | jq -r '.cwd // ""')
  [[ -z "$project_path" ]] && return 0

  # Derive session file path
  local project_dir_name="-$(echo "$project_path" | tr '/' '-')"
  local session_file="$HOME/.claude/projects/$project_dir_name/${SESSION_ID}.jsonl"
  [[ -f "$session_file" ]] || return 0

  # Background process - won't block session exit
  (
    sleep 2  # Wait for session file to finalize
    CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$0")")}"
    "$CLAUDE_PLUGIN_ROOT/scripts/sync-sessions-to-qmd.sh" \
      --single "$session_file" "$SESSION_ID" "$project_path" 2>/dev/null
  ) &
  disown
}
trap index_session_for_qmd EXIT

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
# Parses YAML frontmatter between first two --- delimiters only
# Safe against --- appearing later in the file body (e.g., in code blocks)
# Returns 1 on malformed input (caller should handle with recovery prompt)
parse_frontmatter() {
  local file="$1"
  # Get line numbers of first two --- delimiters
  # Use || true to prevent pipeline exit under set -e when no --- found
  local delimiters
  delimiters=$(grep -n '^---$' "$file" 2>/dev/null | head -2 | cut -d: -f1 || true)

  # Handle empty result (no --- delimiters found)
  if [[ -z "$delimiters" ]]; then
    echo "Error: No frontmatter delimiters found in $file" >&2
    return 1
  fi

  local first_delim second_delim
  first_delim=$(echo "$delimiters" | head -1)
  second_delim=$(echo "$delimiters" | tail -1)

  # Validate: first delimiter should be line 1, second should exist and be different
  if [[ "$first_delim" != "1" ]] || [[ -z "$second_delim" ]] || [[ "$first_delim" == "$second_delim" ]]; then
    echo "Error: Invalid frontmatter format in $file" >&2
    return 1
  fi

  # Extract lines between delimiters (exclusive)
  sed -n "2,$((second_delim - 1))p" "$file"
}

get_field() {
  local frontmatter="$1"
  local field="$2"
  # Use head -1 to handle duplicate keys (return first occurrence only)
  echo "$frontmatter" | grep "^${field}:" | head -1 | sed "s/${field}: *//" | tr -d '"' || true
}

# Validate PRD phase values (shared)
is_valid_prd_phase() {
  local phase="$1"
  case "$phase" in
    1|2|2.5|3|3.2|3.5|4|5|5.5|6) return 0 ;;
    *) return 1 ;;
  esac
}

# Validate state file fields based on loop type
# Returns 0 if valid, 1 if invalid (with error message to stderr)
# Backfills missing loop_type for backward compatibility with pre-0.10.33 state files
validate_state_file() {
  local frontmatter="$1"
  local expected_loop="$2"
  local state_file="$3"

  # Get loop_type from frontmatter
  local loop_type
  loop_type=$(get_field "$frontmatter" "loop_type")

  # Backfill missing loop_type (backward compat with pre-0.10.33 state files)
  if [[ -z "$loop_type" ]]; then
    echo "Note: State file missing 'loop_type' - backfilling from detected loop '$expected_loop'" >&2
    # Add loop_type to frontmatter (after first ---)
    sed_inplace "2i\\
loop_type: \"$expected_loop\"" "$state_file"
    loop_type="$expected_loop"
  fi

  # Validate loop_type matches detected active loop
  if [[ "$loop_type" != "$expected_loop" ]]; then
    echo "Error: State file loop_type '$loop_type' doesn't match detected loop '$expected_loop'" >&2
    return 1
  fi

  # Loop-specific validation
  case "$loop_type" in
    prd)
      local phase
      phase=$(get_field "$frontmatter" "current_phase")
      if [[ -z "$phase" ]]; then
        echo "Error: PRD state file missing 'current_phase' field" >&2
        return 1
      fi
      # Valid phases: 1, 2, 2.5, 3, 3.2, 3.5, 4, 5, 5.5, 6
      if ! is_valid_prd_phase "$phase"; then
        echo "Error: Invalid PRD phase '$phase' (valid: 1, 2, 2.5, 3, 3.2, 3.5, 4, 5, 5.5, 6)" >&2
        return 1
      fi
      ;;
    go|ut|e2e)
      local iteration
      iteration=$(get_field "$frontmatter" "iteration")
      if [[ -z "$iteration" ]]; then
        echo "Error: State file missing 'iteration' field" >&2
        return 1
      fi
      ;;
  esac

  return 0
}

# Parse frontmatter with error handling - malformed state files get recovery prompt
if ! FRONTMATTER=$(parse_frontmatter "$STATE_FILE"); then
  echo "⚠️  Loop ($ACTIVE_LOOP): Malformed state file - invalid frontmatter" >&2
  echo "   State file: $STATE_FILE" >&2
  echo "" >&2
  echo "   Options:" >&2
  echo "     - Check the state file for missing/extra --- delimiters" >&2
  echo "     - Delete the state file to end the loop: rm \"$STATE_FILE\"" >&2
  echo "     - Manually fix the frontmatter format" >&2
  # Block with recovery prompt instead of aborting
  jq -n --arg msg "Loop ($ACTIVE_LOOP): State file has invalid frontmatter. Delete $STATE_FILE to reset, or fix manually." \
    '{"decision": "block", "reason": "State file corrupted - check frontmatter format", "systemMessage": $msg}'
  exit 0
fi

# Validate state file fields
if ! validate_state_file "$FRONTMATTER" "$ACTIVE_LOOP" "$STATE_FILE"; then
  echo "⚠️  Loop ($ACTIVE_LOOP): State file validation failed" >&2
  echo "   State file: $STATE_FILE" >&2
  echo "" >&2
  echo "   Loop is stopping. Run /$ACTIVE_LOOP again to start fresh." >&2
  rm "$STATE_FILE"
  exit 0
fi

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
if [[ -f "$TRANSCRIPT_PATH" ]] && grep -Eq '"role"[[:space:]]*:[[:space:]]*"assistant"' "$TRANSCRIPT_PATH" 2>/dev/null; then
  LAST_LINE=$(grep -E '"role"[[:space:]]*:[[:space:]]*"assistant"' "$TRANSCRIPT_PATH" | tail -1)
  if [[ -n "$LAST_LINE" ]]; then
    # Capture jq output and errors without tripping set -e
    JQ_RESULT=""
    JQ_EXIT=0
    set +e
    JQ_RESULT=$(printf '%s' "$LAST_LINE" | jq -r '
      .message.content |
      map(select(.type == "text")) |
      map(.text) |
      join("\n")
    ' 2>&1)
    JQ_EXIT=$?
    set -e
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
  MARKER_NEXT=""
  INVALID_NEXT_REASON=""

  if [[ -n "$LAST_OUTPUT" ]]; then
    # Use extract_regex_last to get the LAST occurrence (markers may appear in examples/docs)
    # <phase_complete phase="N" feature_name="NAME"/>
    PHASE_COMPLETE=$(extract_regex_last "$LAST_OUTPUT" '<phase_complete phase="([^"]+)"')
    PHASE_FEATURE=$(extract_regex_last "$LAST_OUTPUT" '<phase_complete[^>]*feature_name="([^"]+)"')
    MARKER_NEXT=$(extract_regex_last "$LAST_OUTPUT" '<phase_complete[^>]*next="([^"]+)"')

    # <max_iterations>N</max_iterations>
    MAX_ITER_TAG=$(extract_regex_last "$LAST_OUTPUT" '<max_iterations>([0-9]+)</max_iterations>')

    # <gate_decision>PROCEED|BLOCK</gate_decision>
    GATE_DECISION=$(extract_regex_last "$LAST_OUTPUT" '<gate_decision>([^<]+)</gate_decision>')
  fi

  # Validate next phase value from marker (if provided)
  if [[ -n "$PHASE_COMPLETE" ]] && [[ "$PHASE_COMPLETE" == "$CURRENT_PHASE" ]] && [[ -n "$MARKER_NEXT" ]]; then
    if ! is_valid_prd_phase "$MARKER_NEXT"; then
      INVALID_NEXT_REASON="Invalid next phase '$MARKER_NEXT' (valid: 1, 2, 2.5, 3, 3.2, 3.5, 4, 5, 5.5, 6)."
    else
      case "$CURRENT_PHASE" in
        "1")
          [[ "$MARKER_NEXT" == "2" ]] || INVALID_NEXT_REASON="Invalid next phase '$MARKER_NEXT' for phase 1 (expected 2)."
          ;;
        "2")
          if [[ "$MARKER_NEXT" != "2.5" ]] && [[ "$MARKER_NEXT" != "3" ]]; then
            INVALID_NEXT_REASON="Invalid next phase '$MARKER_NEXT' for phase 2 (expected 2.5 or 3)."
          fi
          ;;
        "2.5")
          [[ "$MARKER_NEXT" == "2" ]] || INVALID_NEXT_REASON="Invalid next phase '$MARKER_NEXT' for phase 2.5 (expected 2)."
          ;;
      esac
    fi
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

### Core Research Agents

1. **Codebase Research**
   - subagent_type: \"somto-dev-toolkit:prd-codebase-researcher\"
   - max_turns: 30
   - prompt: \"Research codebase for $FEATURE_NAME. Find existing patterns, files to modify, models, services, test patterns.\"

2. **Git History**
   - subagent_type: \"compound-engineering:research:git-history-analyzer\"
   - max_turns: 30
   - prompt: \"Analyze git history for code related to $FEATURE_NAME. Find prior attempts, key contributors, why patterns evolved.\"

3. **External Research (Exa)**
   - subagent_type: \"somto-dev-toolkit:prd-external-researcher\"
   - max_turns: 15
   - prompt: \"Research $FEATURE_NAME using Exa. Find best practices, code examples, pitfalls to avoid.\"

### Optional: Live Site Research (if UI/UX feature or competitor analysis needed)

4. **Agent-Browser Research** - Use if feature involves:
   - UI/UX patterns that need visual examples
   - Competitor implementations to study
   - Live API documentation to extract

   Use agent-browser CLI via Bash (ref: compound-engineering:agent-browser skill):
   \`\`\`bash
   agent-browser open \"https://competitor.com/feature\"
   agent-browser snapshot -i --json    # Get interactive elements with refs (@e1, @e2)
   agent-browser click @e1             # Interact using refs
   agent-browser screenshot --full competitor.png
   \`\`\`

   Key pattern: open → snapshot → interact → re-snapshot after DOM changes.

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
      "3.2")
        prompt="# PRD Loop: Phase 3.2 - Skill Discovery & Enrichment

**Feature:** $FEATURE_NAME
**Spec:** \`$SPEC_PATH\`

## Your Task

Discover relevant skills and enrich the spec with implementation patterns.

### Step 1: Discover Skills

Search for matching skills using Glob:
- \`~/.claude/skills/**/*.md\`
- \`.claude/skills/**/*.md\`
- Check installed plugins for skill definitions

### Step 2: Match Skills to Spec

Read the spec and identify technologies/patterns mentioned. Match against skills:

**UI/React/Animation (MANDATORY for frontend features):**
- **emil-design-engineering** - Polished, accessible UI (touch, a11y, forms, polish)
- **web-animation-design** - Easing, timing, springs, motion performance
- **vercel-react-best-practices** - React/Next.js performance optimization

**Backend/Infrastructure:**
- **dhh-rails-style** - Rails conventions
- **agent-native-architecture** - AI agent features
- **dspy-ruby** - LLM application patterns

**General:**
- **frontend-design** - General UI/component patterns
- Any project-specific skills

**Detection heuristics for UI skills:**
If spec mentions: React, Next.js, component, button, form, input, modal, animation, transition, hover, CSS, Tailwind, TypeScript UI → load all 3 UI skills

### Step 3: Spawn Skill Agents IN PARALLEL

For each matched skill, spawn a sub-agent:
\`\`\`
Task tool:
- subagent_type: \"Explore\"
- max_turns: 15
- prompt: \"Read skill at [PATH]. Extract implementation patterns relevant to [FEATURE]. Return: patterns, anti-patterns, code examples, constraints.\"
\`\`\`

### Step 4: Enrich Spec

Add a new section to the spec:
\`\`\`markdown
## Implementation Patterns (from Skills)

### [Skill Name]
- **Pattern**: ...
- **Anti-pattern**: ...
- **Example**: ...
\`\`\`

After enriching spec, output:
\`\`\`
<phase_complete phase=\"3.2\"/>
\`\`\`"
        ;;
      "3.5")
        prompt="# PRD Loop: Phase 3.5 - Spec Review (Multi-Dimensional)

**Feature:** $FEATURE_NAME
**Spec:** \`$SPEC_PATH\`

## Your Task

Spawn ALL reviewers IN PARALLEL (single message, multiple Task tool calls).
Read the spec first, then pass content to each reviewer.

### Core Reviewers (always run)

1. **Flow Analysis** - User journeys, edge cases, missing flows
   - subagent_type: \"compound-engineering:workflow:spec-flow-analyzer\"
   - max_turns: 20

2. **Architecture Review** - System design, component boundaries
   - subagent_type: \"compound-engineering:review:architecture-strategist\"
   - max_turns: 20

3. **Security Review** - Auth, data exposure, OWASP concerns
   - subagent_type: \"compound-engineering:review:security-sentinel\"
   - max_turns: 20

4. **Performance Review** - Scalability, bottlenecks, caching needs
   - subagent_type: \"compound-engineering:review:performance-oracle\"
   - max_turns: 20

5. **Simplicity Review** - Is spec overcomplicated? YAGNI violations?
   - subagent_type: \"compound-engineering:review:code-simplicity-reviewer\"
   - max_turns: 15

6. **Pattern Review** - Does it follow existing codebase patterns?
   - subagent_type: \"compound-engineering:review:pattern-recognition-specialist\"
   - max_turns: 20

### Domain-Specific Reviewers (if applicable)

7. **Data Integrity** - If spec involves data models/migrations
   - subagent_type: \"compound-engineering:review:data-integrity-guardian\"
   - max_turns: 20

8. **Agent-Native** - If spec involves AI/agent features
   - subagent_type: \"compound-engineering:review:agent-native-reviewer\"
   - max_turns: 15

**After reviews complete:**
- Add critical items to spec's \"Review Findings\" section
- Update User Stories if reviewers found missing flows
- Prioritize findings by severity (Critical > High > Medium)

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

**Skill assignment (for ui/frontend stories):**
- \`emil-design-engineering\` - Forms, inputs, buttons, touch, a11y, polish
- \`web-animation-design\` - Animations, transitions, easing, springs
- \`vercel-react-best-practices\` - React performance, hooks, rendering
- Assign ALL relevant skills to each UI story (multiple skills encouraged)

**Write to:** \`plans/$FEATURE_NAME/prd.json\`

\`\`\`json
{
  \"title\": \"$FEATURE_NAME\",
  \"stories\": [
    {
      \"id\": 1,
      \"title\": \"Story title\",
      \"category\": \"functional|ui|integration|edge-case|performance\",
      \"skills\": [\"emil-design-engineering\", \"web-animation-design\"],  // array for ui category
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

## MANDATORY: Spawn Complexity Estimator Agent

You MUST spawn this agent NOW using the Task tool. Do NOT skip this step. Do NOT make up a value.

\`\`\`
Task tool call:
- subagent_type: \"somto-dev-toolkit:prd-complexity-estimator\"
- max_turns: 20
- prompt: \"Estimate complexity for this PRD. <prd_json>{read PRD}</prd_json> <spec_content>{read spec}</spec_content>\"
\`\`\`

WAIT for the agent to return. Use the agent's recommended value.

**After agent returns**, output EXACTLY:
\`\`\`
<max_iterations>N</max_iterations>
\`\`\`

Where N is the value from the agent (NOT a guess, NOT a default)."
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
  # IMPORTANT: For phase_complete, must also validate phase attribute matches current phase
  # to prevent wrong-phase markers from resetting retry count and causing infinite loops
  VALID_MARKER_FOUND=false
  case "$CURRENT_PHASE" in
    "5.5")
      [[ -n "$MAX_ITER_TAG" ]] && VALID_MARKER_FOUND=true
      ;;
    "3.5")
      [[ -n "$GATE_DECISION" ]] && VALID_MARKER_FOUND=true
      ;;
    *)
      # Only valid if phase attribute matches current phase
      [[ -n "$PHASE_COMPLETE" ]] && [[ "$PHASE_COMPLETE" == "$CURRENT_PHASE" ]] && [[ -z "$INVALID_NEXT_REASON" ]] && VALID_MARKER_FOUND=true
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
    if [[ -n "$INVALID_NEXT_REASON" ]]; then
      ERROR_SUMMARY="$INVALID_NEXT_REASON"
    elif [[ -n "$LAST_OUTPUT" ]]; then
      ERROR_SUMMARY=$(echo "$LAST_OUTPUT" | head -c 200 | tr '\n' ' ' | sed 's/"/\\"/g')
    else
      ERROR_SUMMARY="No text output from Claude (only tool calls)"
    fi
    # Escape for sed replacement to handle /, &, \ in error messages
    ESCAPED_ERROR=$(escape_sed_replacement "$ERROR_SUMMARY")
    sed_inplace "s/^last_error: .*/last_error: \"$ESCAPED_ERROR\"/" "$STATE_FILE"

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
      if [[ -n "$INVALID_NEXT_REASON" ]]; then
        SYSTEM_MSG="🔄 Loop (prd): Phase $CURRENT_PHASE retry $RETRY_COUNT/$MAX_RETRIES - invalid next phase"
      else
        SYSTEM_MSG="🔄 Loop (prd): Phase $CURRENT_PHASE retry $RETRY_COUNT/$MAX_RETRIES - expected marker not found"
      fi
      PROMPT_TEXT=$(generate_prd_phase_prompt "$CURRENT_PHASE")
      if [[ -n "$INVALID_NEXT_REASON" ]]; then
        PROMPT_TEXT="$PROMPT_TEXT

---
**Note:** $INVALID_NEXT_REASON"
      else
        PROMPT_TEXT="$PROMPT_TEXT

---
**Note:** Previous attempt didn't include the expected marker. Please ensure your response ends with:
\`$EXPECTED_MARKER\`"
      fi

      jq -n --arg prompt "$PROMPT_TEXT" --arg msg "$SYSTEM_MSG" '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
      exit 0
    fi
  fi

  # Update feature name ONLY from phase 1 marker (input classification)
  # Restricting to phase 1 prevents stray examples from mutating state in later phases
  if [[ -n "$PHASE_FEATURE" ]] && [[ "$CURRENT_PHASE" == "1" ]] && [[ "$PHASE_COMPLETE" == "1" ]]; then
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
  # IMPORTANT: Validate that phase attribute matches current phase to prevent
  # accidental advancement from example markers in documentation/output
  if [[ -n "$PHASE_COMPLETE" ]] && [[ "$PHASE_COMPLETE" == "$CURRENT_PHASE" ]]; then
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
        NEXT_PHASE="3.2"
        # Extract spec_path from marker
        MARKER_SPEC=$(extract_regex_last "$LAST_OUTPUT" '<phase_complete[^>]*spec_path="([^"]+)"')
        if [[ -n "$MARKER_SPEC" ]]; then
          SPEC_PATH="$MARKER_SPEC"
          ESCAPED_PATH=$(escape_sed_replacement "$SPEC_PATH")
          sed_inplace "s|^spec_path: .*|spec_path: \"$ESCAPED_PATH\"|" "$STATE_FILE"
        fi
        ;;
      "3.2") NEXT_PHASE="3.5" ;;  # Skill enrichment → Review gate
      "3.5") NEXT_PHASE="4" ;;  # Only reached if gate_decision not detected
      "4")
        NEXT_PHASE="5"
        # Extract prd_path from marker
        MARKER_PRD=$(extract_regex_last "$LAST_OUTPUT" '<phase_complete[^>]*prd_path="([^"]+)"')
        if [[ -n "$MARKER_PRD" ]]; then
          PRD_PATH="$MARKER_PRD"
          ESCAPED_PATH=$(escape_sed_replacement "$PRD_PATH")
          sed_inplace "s|^prd_path: .*|prd_path: \"$ESCAPED_PATH\"|" "$STATE_FILE"
        fi
        ;;
      "5")
        NEXT_PHASE="5.5"
        # Extract progress_path from marker
        MARKER_PROGRESS=$(extract_regex_last "$LAST_OUTPUT" '<phase_complete[^>]*progress_path="([^"]+)"')
        if [[ -n "$MARKER_PROGRESS" ]]; then
          ESCAPED_PATH=$(escape_sed_replacement "$MARKER_PROGRESS")
          sed_inplace "s|^progress_path: .*|progress_path: \"$ESCAPED_PATH\"|" "$STATE_FILE"
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

  # Update feature_name if changed (escape for sed to handle special chars)
  ESCAPED_FEATURE=$(escape_sed_replacement "$FEATURE_NAME")
  sed_inplace "s/^feature_name: .*/feature_name: \"$ESCAPED_FEATURE\"/" "$STATE_FILE"

  # Generate new phase prompt
  PROMPT_TEXT=$(generate_prd_phase_prompt "$NEXT_PHASE")

  # Update state file body with new prompt
  # Remove old body (everything after second ---) and append new
  # Use || true to handle edge case where file is corrupted between validation and here
  FRONTMATTER_END=$(grep -n '^---$' "$STATE_FILE" 2>/dev/null | head -2 | tail -1 | cut -d: -f1 || true)
  if [[ -z "$FRONTMATTER_END" ]] || [[ ! "$FRONTMATTER_END" =~ ^[0-9]+$ ]]; then
    echo "⚠️  Loop (prd): State file corrupted (no closing ---)" >&2
    rm "$STATE_FILE"
    exit 0
  fi
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
  # Extract text from <promise> tags (last match wins)
  PROMISE_TEXT=$(extract_promise_last "$LAST_OUTPUT")

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
    [[ "$ACTIVE_LOOP" =~ ^(go|ut|e2e)$ ]] && show_loop_summary "$STATE_FILE" "$ITERATION"
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

  if [[ -z "$PRD_PATH" ]] || [[ ! -f "$PRD_PATH" ]]; then
    PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")
    SYSTEM_MSG="⚠️  Loop (go/prd): PRD file not found at '$PRD_PATH'. Restore it or rerun /prd."
    jq -n --arg prompt "$PROMPT_TEXT" --arg msg "$SYSTEM_MSG" '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
    exit 0
  fi

  if ! jq empty "$PRD_PATH" 2>/dev/null; then
    PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")
    SYSTEM_MSG="⚠️  Loop (go/prd): PRD file is invalid JSON at '$PRD_PATH'. Fix the file or rerun /prd."
    jq -n --arg prompt "$PROMPT_TEXT" --arg msg "$SYSTEM_MSG" '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
    exit 0
  fi

  # Parse structured output markers
  REVIEWS_COMPLETE_MARKER=$(extract_regex_last "$LAST_OUTPUT" '<reviews_complete/>')
  STORY_COMPLETE_MARKER=$(extract_regex_last "$LAST_OUTPUT" '<story_complete[^>]*story_id="([^"]+)"')
  CURRENT_PASSES=$(jq ".stories[] | select(.id == $CURRENT_STORY_ID) | .passes" "$PRD_PATH" 2>/dev/null || echo "false")
  STORY_TITLE=$(jq -r ".stories[] | select(.id == $CURRENT_STORY_ID) | .title" "$PRD_PATH")

    # Step 1: Check for story_complete marker (MANDATORY structured output)
    if [[ -z "$STORY_COMPLETE_MARKER" ]]; then
      # No marker yet - check what's missing
      PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")

      if [[ "$CURRENT_PASSES" != "true" ]]; then
        SYSTEM_MSG="🔄 Loop (go/prd): Story #$CURRENT_STORY_ID not yet passing. Update prd.json when tests pass."
      elif [[ -z "$REVIEWS_COMPLETE_MARKER" ]]; then
        SYSTEM_MSG="⚠️  Loop (go/prd): Story #$CURRENT_STORY_ID passes but REVIEWS NOT run.

**REQUIRED steps:**
1. Run code-simplifier: \`pr-review-toolkit:code-simplifier\` (max_turns: 15)
2. Run Kieran reviewer for your code type (max_turns: 20)
3. Address ALL findings
4. Output: \`<reviews_complete/>\`
5. Commit with story reference
6. Output: \`<story_complete story_id=\"$CURRENT_STORY_ID\"/>\`"
      else
        # Reviews done, passes true, but no story_complete marker
        SYSTEM_MSG="⚠️  Loop (go/prd): Reviews done ✓ Story passes ✓ Now commit and output:
\`<story_complete story_id=\"$CURRENT_STORY_ID\"/>\`"
      fi

      jq -n \
        --arg prompt "$PROMPT_TEXT" \
        --arg msg "$SYSTEM_MSG" \
        '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
      exit 0
    fi

    # Step 2: Verify story_complete marker matches current story
    if [[ "$STORY_COMPLETE_MARKER" != "$CURRENT_STORY_ID" ]]; then
      PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")
      SYSTEM_MSG="⚠️  Loop (go/prd): story_id mismatch. Expected $CURRENT_STORY_ID, got $STORY_COMPLETE_MARKER"
      jq -n --arg prompt "$PROMPT_TEXT" --arg msg "$SYSTEM_MSG" '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
      exit 0
    fi

    # Step 3: Verify prd.json shows passes: true
    if [[ "$CURRENT_PASSES" != "true" ]]; then
      PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")
      SYSTEM_MSG="⚠️  Loop (go/prd): <story_complete/> found but prd.json shows passes: false. Update prd.json first."
      jq -n --arg prompt "$PROMPT_TEXT" --arg msg "$SYSTEM_MSG" '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
      exit 0
    fi

    # Step 4: Verify reviews were run
    if [[ -z "$REVIEWS_COMPLETE_MARKER" ]]; then
      PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")
      SYSTEM_MSG="⚠️  Loop (go/prd): <story_complete/> found but <reviews_complete/> missing. Run reviews first."
      jq -n --arg prompt "$PROMPT_TEXT" --arg msg "$SYSTEM_MSG" '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
      exit 0
    fi

    # Step 5: Verify commit exists
    # Use word boundary ([^0-9]|$) to prevent #1 matching #10, #11, etc.
    if git log --oneline -10 2>/dev/null | grep -qiE "(story.*#?${CURRENT_STORY_ID}([^0-9]|$)|#${CURRENT_STORY_ID}([^0-9]|$)|story ${CURRENT_STORY_ID}([^0-9]|$))"; then
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
          show_loop_summary "$STATE_FILE" "$ITERATION"
          rm "$STATE_FILE"
          exit 0
        fi

        # Advance to next story - rebuild state file
        NEXT_ITERATION=$((ITERATION + 1))
        NEXT_STORY=$(jq ".stories[] | select(.id == $NEXT_STORY_ID)" "$PRD_PATH")
        NEXT_TITLE=$(echo "$NEXT_STORY" | jq -r '.title')
        INCOMPLETE_COUNT=$(jq '[.stories[] | select(.passes == false)] | length' "$PRD_PATH")

        # Handle skills array (new) or skill string (backward compat)
        NEXT_SKILLS_JSON=$(echo "$NEXT_STORY" | jq -r '.skills // empty')
        NEXT_SKILL_LEGACY=$(echo "$NEXT_STORY" | jq -r '.skill // empty')

        SKILL_FRONTMATTER=""
        SKILL_SECTION=""
        SKILLS_LOG=""

        if [[ -n "$NEXT_SKILLS_JSON" ]] && [[ "$NEXT_SKILLS_JSON" != "null" ]]; then
          # New format: skills array
          SKILLS_LIST=$(echo "$NEXT_SKILLS_JSON" | jq -r '.[]' 2>/dev/null || echo "")
          if [[ -n "$SKILLS_LIST" ]]; then
            SKILL_FRONTMATTER="skills: $NEXT_SKILLS_JSON"
            SKILLS_LOG=$(echo "$SKILLS_LIST" | tr '\n' ',' | sed 's/,$//')
            SKILL_SECTION="## Required Skills

This story requires the following skills. **BEFORE implementing**, load each:

"
            while IFS= read -r skill; do
              [[ -n "$skill" ]] && SKILL_SECTION="${SKILL_SECTION}\`\`\`
/Skill $skill
\`\`\`

"
            done <<< "$SKILLS_LIST"
            SKILL_SECTION="${SKILL_SECTION}Follow each skill's guidance for implementation patterns and quality standards.
"
          fi
        elif [[ -n "$NEXT_SKILL_LEGACY" ]]; then
          # Legacy format: single skill string
          SKILL_FRONTMATTER="skill: \"$NEXT_SKILL_LEGACY\""
          SKILLS_LOG="$NEXT_SKILL_LEGACY"
          SKILL_SECTION="## Required Skill

This story requires the \`$NEXT_SKILL_LEGACY\` skill. **BEFORE implementing**, invoke:

\`\`\`
/Skill $NEXT_SKILL_LEGACY
\`\`\`

Follow the skill's guidance for implementation approach, patterns, and quality standards.
"
        fi

        if [[ -f "$PROGRESS_PATH" ]]; then
          if [[ -n "$SKILLS_LOG" ]]; then
            echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"story_id\":$NEXT_STORY_ID,\"status\":\"STARTED\",\"skills\":\"$SKILLS_LOG\",\"notes\":\"Beginning story #$NEXT_STORY_ID (requires skills)\"}" >> "$PROGRESS_PATH"
          else
            echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"story_id\":$NEXT_STORY_ID,\"status\":\"STARTED\",\"notes\":\"Beginning story #$NEXT_STORY_ID\"}" >> "$PROGRESS_PATH"
          fi
        fi

        # Build frontmatter (skills line only if present)
        FRONTMATTER_CONTENT="---
loop_type: \"go\"
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

# =============================================================================
# Verify iteration completion for ut/e2e loops (structured output control flow)
# =============================================================================
if [[ "$ACTIVE_LOOP" == "ut" ]] || [[ "$ACTIVE_LOOP" == "e2e" ]]; then
  # Parse markers
  REVIEWS_COMPLETE_MARKER=$(extract_regex_last "$LAST_OUTPUT" '<reviews_complete/>')
  ITER_COMPLETE_MARKER=$(extract_regex_last "$LAST_OUTPUT" '<iteration_complete[^>]*test_file="([^"]+)"')

  # Step 1: Check for reviews_complete marker (MANDATORY)
  if [[ -z "$REVIEWS_COMPLETE_MARKER" ]]; then
    PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")
    SYSTEM_MSG="⚠️  Loop ($ACTIVE_LOOP): Reviews NOT run. You MUST run reviewers before completing iteration.

**REQUIRED steps:**
1. Run code-simplifier: \`pr-review-toolkit:code-simplifier\` (max_turns: 15)
2. Run Kieran reviewer for your code type (max_turns: 20)
3. Address ALL findings
4. Output: \`<reviews_complete/>\`
5. Then commit and output: \`<iteration_complete test_file=\"...\"/>\`"

    jq -n \
      --arg prompt "$PROMPT_TEXT" \
      --arg msg "$SYSTEM_MSG" \
      '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
    exit 0
  fi

  # Step 2: Check for iteration_complete marker
  if [[ -z "$ITER_COMPLETE_MARKER" ]]; then
    PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")
    SYSTEM_MSG="⚠️  Loop ($ACTIVE_LOOP): Reviews done ✓ but iteration incomplete. Commit your test, then output: <iteration_complete test_file=\"path/to/test.ts\"/>"

    jq -n \
      --arg prompt "$PROMPT_TEXT" \
      --arg msg "$SYSTEM_MSG" \
      '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
    exit 0
  fi

  # Step 3: Verify commit exists
  if git log --oneline -5 2>/dev/null | grep -qiE "^[a-f0-9]+ test"; then
    # All checks passed - log and continue to advance
    log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"ITERATION_VERIFIED\",\"iteration\":$ITERATION,\"test_file\":\"$ITER_COMPLETE_MARKER\",\"notes\":\"Iteration $ITERATION complete - reviews, marker, and commit verified\"}"
    echo "✓ Loop ($ACTIVE_LOOP): Iteration $ITERATION complete - reviews ✓ commit ✓ $ITER_COMPLETE_MARKER"
  else
    # Markers but no commit - remind to commit
    PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")
    SYSTEM_MSG="⚠️  Loop ($ACTIVE_LOOP): Reviews done ✓ but NO COMMIT found. Commit your test: git add && git commit -m \"test(...): ...\""

    jq -n \
      --arg prompt "$PROMPT_TEXT" \
      --arg msg "$SYSTEM_MSG" \
      '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
    exit 0
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
