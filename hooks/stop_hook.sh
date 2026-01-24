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
#   Key fields: iteration, max_iterations, completion_promise, current_phase, phase_iteration, etc.
#
# PRD LOOP (ralph-loop pattern):
#   - File existence is truth (markers optional) - auto-discovers from plans/<feature>/
#   - Never stops on missing markers - just keeps prompting
#   - Completion signals: phase 6 marker, all files exist, or <promise>PRD COMPLETE</promise>
#
# STRUCTURED OUTPUT MARKERS (parsed from Claude's response):
#   - <phase_complete phase="N" .../>  - PRD phase transitions (optional - file detection is primary)
#   - <gate_decision>PROCEED|BLOCK</gate_decision> - PRD review gate
#   - <max_iterations>N</max_iterations> - PRD complexity estimate
#   - <story_complete story_id="N"/> - Go/PRD story completion
#   - <iteration_complete test_file="..."/> - UT/E2E iteration
#   - <reviews_complete/> - Confirms code reviews ran
#   - <promise>TEXT</promise> - Loop completion signal (PRD accepts "PRD COMPLETE")
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

# Force byte-wise locale to avoid macOS "Illegal byte sequence" in tr/sed on non-UTF8 bytes.
export LC_ALL=C
export LANG=C

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
  # LC_ALL=C prevents "Illegal byte sequence" on macOS with non-ASCII input
  normalized=$(printf '%s' "$text" | LC_ALL=C tr '\r\n' ' ')
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

# Portable sed in-place edit (works on macOS, Linux, Windows/WSL)
# Usage: sed_inplace "s/old/new/" "file"
# WARNING: If replacement contains user input, use escape_sed_replacement first!
# Note: Uses /tmp to avoid triggering file watchers in .claude/ directory (Windows/WSL EINVAL fix)
sed_inplace() {
  local expr="$1"
  local file="$2"
  local temp_file="/tmp/sed_inplace_$$.tmp"
  sed "$expr" "$file" > "$temp_file" || { rm -f "$temp_file"; return 1; }
  # Try mv first, fall back to cp+rm for cross-filesystem
  mv "$temp_file" "$file" 2>/dev/null || { cp "$temp_file" "$file" && rm -f "$temp_file"; }
}

# Update iteration in state file safely
# Note: Uses /tmp to avoid triggering file watchers in .claude/ directory (Windows/WSL EINVAL fix)
update_iteration() {
  local state_file="$1"
  local new_iteration="$2"
  local temp_file="/tmp/update_iter_$$.tmp"

  sed "s/^iteration: .*/iteration: $new_iteration/" "$state_file" > "$temp_file"
  mv "$temp_file" "$state_file" 2>/dev/null || { cp "$temp_file" "$state_file" && rm -f "$temp_file"; }
}

# Write state file atomically (write to temp, then move)
# Uses printf to handle multiline content safely
# Note: Uses /tmp to avoid triggering file watchers in .claude/ directory (Windows/WSL EINVAL fix)
write_state_file() {
  local state_file="$1"
  local content="$2"
  local temp_file="/tmp/write_state_$$.tmp"

  printf '%s\n' "$content" > "$temp_file"
  mv "$temp_file" "$state_file" 2>/dev/null || { cp "$temp_file" "$state_file" && rm -f "$temp_file"; }
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
    commit_count=$(git log --since="$started_at" --oneline 2>/dev/null | wc -l | LC_ALL=C tr -d ' ')
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
  local project_dir_name="-$(echo "$project_path" | LC_ALL=C tr '/' '-')"
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
  echo "$frontmatter" | grep "^${field}:" | head -1 | sed "s/${field}: *//" | LC_ALL=C tr -d '"' || true
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
# Fails fast if loop_type missing (no backward compat - delete state file and restart)
validate_state_file() {
  local frontmatter="$1"
  local expected_loop="$2"
  local state_file="$3"

  # Get loop_type from frontmatter
  local loop_type
  loop_type=$(get_field "$frontmatter" "loop_type")

  # Fail fast on missing loop_type (no backward compat)
  if [[ -z "$loop_type" ]]; then
    echo "Error: State file missing 'loop_type' field. Delete state file and restart loop." >&2
    return 1
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
  # Allow exit - invalid state file means we can't continue
  jq -n '{"decision": "allow"}'
  exit 0
fi

ITERATION=$(get_field "$FRONTMATTER" "iteration")
MAX_ITERATIONS=$(get_field "$FRONTMATTER" "max_iterations")
COMPLETION_PROMISE=$(get_field "$FRONTMATTER" "completion_promise")
ONCE_MODE=$(get_field "$FRONTMATTER" "once")

# Handle mode for go loop
MODE=""
if [[ "$ACTIVE_LOOP" == "go" ]]; then
  MODE=$(get_field "$FRONTMATTER" "mode")
fi

# Helper to log progress - appends to embedded log in state JSON (prd.json or state.json)
# For PRD mode: appends to prd.json's log array
# For UT/E2E: appends to state.json's log array
log_progress() {
  local json="$1"
  local state_json="${2:-}"

  [[ -z "$state_json" ]] || [[ ! -f "$state_json" ]] && return 0

  local temp_file="/tmp/log_progress_$$.tmp"
  if jq -e '.log' "$state_json" >/dev/null 2>&1; then
    jq --argjson entry "$json" '.log += [$entry]' "$state_json" > "$temp_file"
  else
    jq --argjson entry "$json" '. + {log: [$entry]}' "$state_json" > "$temp_file"
  fi
  mv "$temp_file" "$state_json" 2>/dev/null || { cp "$temp_file" "$state_json" && rm -f "$temp_file"; }
}

# =============================================================================
# GUARD 3: Check for --once mode (HITL single iteration) - skip for prd
# =============================================================================
if [[ "$ACTIVE_LOOP" != "prd" ]] && [[ "$ONCE_MODE" == "true" ]]; then
  echo "✅ Loop ($ACTIVE_LOOP): Single iteration complete (HITL mode)"
  echo "   Run /$ACTIVE_LOOP again to continue, or remove --once for full loop."
  notify "Loop ($ACTIVE_LOOP)" "Iteration complete - ready for review"
  log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"hitl_pause\",\"iteration\":$ITERATION,\"notes\":\"Single iteration complete (--once mode)\"}"
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
    log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"max_iterations\",\"iteration\":$ITERATION,\"notes\":\"Loop stopped after $ITERATION iterations\"}"
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
  INTERVIEW_WAVE=$(get_field "$FRONTMATTER" "interview_wave")
  GATE_STATUS=$(get_field "$FRONTMATTER" "gate_status")
  REVIEW_COUNT=$(get_field "$FRONTMATTER" "review_count")
  REVIEWS_COMPLETE=$(get_field "$FRONTMATTER" "reviews_complete")
  PHASE_ITERATION=$(get_field "$FRONTMATTER" "phase_iteration")

  # ===========================================================================
  # COMPLETION PROMISE: Check for explicit completion signal (ralph-loop style)
  # ===========================================================================
  if [[ -n "$LAST_OUTPUT" ]]; then
    PRD_PROMISE=$(extract_promise_last "$LAST_OUTPUT")
    if [[ "$PRD_PROMISE" == "PRD COMPLETE" ]]; then
      echo "✅ Loop (prd): Detected <promise>PRD COMPLETE</promise>"
      echo "   Feature '$FEATURE_NAME' PRD workflow complete!"
      notify "Loop (prd)" "PRD complete for $FEATURE_NAME!"
      rm "$STATE_FILE"
      exit 0
    fi
  fi

  # Default numeric fields
  [[ ! "$INTERVIEW_QUESTIONS" =~ ^[0-9]+$ ]] && INTERVIEW_QUESTIONS=0
  [[ ! "$INTERVIEW_WAVE" =~ ^[0-9]+$ ]] && INTERVIEW_WAVE=1
  [[ ! "$REVIEW_COUNT" =~ ^[0-9]+$ ]] && REVIEW_COUNT=0
  [[ ! "$PHASE_ITERATION" =~ ^[0-9]+$ ]] && PHASE_ITERATION=0
  [[ "$REVIEWS_COMPLETE" != "true" ]] && REVIEWS_COMPLETE="false"

  # Parse structured output markers from LAST_OUTPUT
  PHASE_COMPLETE=""
  PHASE_FEATURE=""
  MAX_ITER_TAG=""
  GATE_DECISION=""
  MARKER_NEXT=""
  INVALID_NEXT_REASON=""
  REVIEWS_COMPLETE_MARKER=""

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

    # <reviews_complete/>
    REVIEWS_COMPLETE_MARKER=$(extract_regex_last "$LAST_OUTPUT" '<reviews_complete/>')

    # <tasks_synced/>
    TASKS_SYNCED_MARKER=$(extract_regex_last "$LAST_OUTPUT" '<tasks_synced/>')
  fi

  # Update task_list_synced when marker detected
  if [[ -n "$TASKS_SYNCED_MARKER" ]]; then
    if grep -q '^task_list_synced:' "$STATE_FILE"; then
      sed_inplace "s/^task_list_synced: .*/task_list_synced: true/" "$STATE_FILE"
    fi
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
        # Calculate current wave based on question count
        local wave_status=""
        local wave_guidance=""
        if [[ $INTERVIEW_WAVE -eq 1 ]]; then
          wave_status="Wave 1 of 5 (Core Understanding)"
          wave_guidance="Focus on: problem definition, success criteria, MVP scope"
        elif [[ $INTERVIEW_WAVE -eq 2 ]]; then
          wave_status="Wave 2 of 5 (Technical Deep Dive)"
          wave_guidance="Focus on: systems, data models, code patterns"
        elif [[ $INTERVIEW_WAVE -eq 3 ]]; then
          wave_status="Wave 3 of 5 (UX/UI Details)"
          wave_guidance="Focus on: user flows, error states, edge cases"
        elif [[ $INTERVIEW_WAVE -eq 4 ]]; then
          wave_status="Wave 4 of 5 (Edge Cases & Concerns)"
          wave_guidance="Focus on: failure modes, security, risks"
        else
          wave_status="Wave 5 of 5 (Tradeoffs & Decisions)"
          wave_guidance="Focus on: compromises, non-negotiables, priorities"
        fi

        prompt="# PRD Loop: Phase 2 - Deep Interview

**Feature:** $FEATURE_NAME
**Progress:** $INTERVIEW_QUESTIONS questions asked | $wave_status

## Current Focus
$wave_guidance

## Interview Waves

**Wave 1 - Core Understanding** (3-4 questions)
- What problem does this solve? For whom?
- What does success look like?
- What's the MVP vs nice-to-have?

**Wave 2 - Technical Deep Dive** (after research)
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

## Transitions

**After Wave 1 (3-4 questions)** - trigger research:
\`\`\`
<phase_complete phase=\"2\" next=\"2.5\"/>
\`\`\`

**After interview complete (8-10+ questions, all waves done)** - proceed to spec:
\`\`\`
<phase_complete phase=\"2\" next=\"3\"/>
\`\`\`

**Markers (optional but recommended):** Output one of these markers at the end of your response. If you forget, the loop auto-advances when work is detected."
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

**After ALL review agents return:**
1. Add critical items to spec's \"Review Findings\" section
2. Update User Stories if reviewers found missing flows
3. Prioritize findings by severity (Critical > High > Medium)
4. If critical issues found, use AskUserQuestion: \"Reviewers found <issues>. Address now or proceed?\"

**Markers (required to advance):** After incorporating findings, output BOTH markers in the SAME response:
\`\`\`
<reviews_complete/>
<gate_decision>PROCEED</gate_decision>
\`\`\`

Or if blocking:
\`\`\`
<reviews_complete/>
<gate_decision>BLOCK</gate_decision>
\`\`\`

**You MUST include these markers in your TEXT response, not just in tool calls.**"
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
        prompt="# PRD Loop: Phase 5 - Verify PRD Structure

**Feature:** $FEATURE_NAME
**PRD:** \`$PRD_PATH\`

## Your Task

Verify prd.json has required structure for the /go loop:

1. Check \`$PRD_PATH\` has a \`log\` array (initialize to \`[]\` if missing)
2. Verify all stories have \`completed_at: null\` and \`commit: null\` fields
3. Verify all stories have \`passes: false\`

The /go loop will append log entries automatically:
\`\`\`json
{\"ts\":\"...\",\"event\":\"story_started\",\"story_id\":1}
{\"ts\":\"...\",\"event\":\"story_complete\",\"story_id\":1,\"commit\":\"abc123\"}
\`\`\`

After verifying structure, output:
\`\`\`
<phase_complete phase=\"5\"/>
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
- \`plans/$FEATURE_NAME/prd.json\` (with embedded progress log)

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
    "3.5")
      if [[ "$REVIEWS_COMPLETE" == "true" ]]; then
        EXPECTED_MARKER="<gate_decision>PROCEED|BLOCK</gate_decision>"
      else
        EXPECTED_MARKER="<reviews_complete/>"
      fi
      ;;
    *)     EXPECTED_MARKER="<phase_complete phase=\"$CURRENT_PHASE\" .../>" ;;
  esac

  # Check if we got a valid marker for the current phase
  # IMPORTANT: For phase_complete, must also validate phase attribute matches current phase
  # to prevent wrong-phase markers from being treated as valid completions
  VALID_MARKER_FOUND=false
  case "$CURRENT_PHASE" in
    "5.5")
      [[ -n "$MAX_ITER_TAG" ]] && VALID_MARKER_FOUND=true
      ;;
    "3.5")
      if [[ -n "$REVIEWS_COMPLETE_MARKER" ]]; then
        VALID_MARKER_FOUND=true
      elif [[ "$REVIEWS_COMPLETE" == "true" ]] && [[ "$GATE_DECISION" == "PROCEED" || "$GATE_DECISION" == "BLOCK" ]]; then
        VALID_MARKER_FOUND=true
      fi
      ;;
    *)
      # Only valid if phase attribute matches current phase
      [[ -n "$PHASE_COMPLETE" ]] && [[ "$PHASE_COMPLETE" == "$CURRENT_PHASE" ]] && [[ -z "$INVALID_NEXT_REASON" ]] && VALID_MARKER_FOUND=true
      ;;
  esac

  if [[ "$VALID_MARKER_FOUND" == "true" ]]; then
    # Reset phase iteration on success
    if [[ $PHASE_ITERATION -gt 0 ]]; then
      sed_inplace "s/^phase_iteration: .*/phase_iteration: 0/" "$STATE_FILE"
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

  # Phase 3.5: reviews_complete AND gate_decision required (can be in same response)
  if [[ "$CURRENT_PHASE" == "3.5" ]]; then
    # Track if reviews marker found in THIS response
    if [[ -n "$REVIEWS_COMPLETE_MARKER" ]]; then
      if grep -q '^reviews_complete:' "$STATE_FILE"; then
        sed_inplace "s/^reviews_complete: .*/reviews_complete: true/" "$STATE_FILE"
      else
        sed_inplace "2i\\
reviews_complete: true" "$STATE_FILE"
      fi
      REVIEWS_COMPLETE="true"
      if [[ $PHASE_ITERATION -gt 0 ]]; then
        sed_inplace "s/^phase_iteration: .*/phase_iteration: 0/" "$STATE_FILE"
      fi
    fi

    # Check for gate decision (requires reviews_complete first or in same response)
    if [[ -n "$GATE_DECISION" ]]; then
      if [[ "$REVIEWS_COMPLETE" != "true" ]]; then
        SYSTEM_MSG="⚠️  Loop (prd): Gate decision requires reviews first. Output <reviews_complete/> before <gate_decision>."
        PROMPT_TEXT=$(generate_prd_phase_prompt "3.5")
        jq -n --arg prompt "$PROMPT_TEXT" --arg msg "$SYSTEM_MSG" '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
        exit 0
      fi

      if [[ "$GATE_DECISION" == "PROCEED" ]]; then
        NEXT_PHASE="4"
        sed_inplace "s/^gate_status: .*/gate_status: proceed/" "$STATE_FILE"
        SYSTEM_MSG="✅ Loop (prd): Review gate passed! Advancing to phase 4."
      elif [[ "$GATE_DECISION" == "BLOCK" ]]; then
        REVIEW_COUNT=$((REVIEW_COUNT + 1))
        sed_inplace "s/^review_count: .*/review_count: $REVIEW_COUNT/" "$STATE_FILE"
        sed_inplace "s/^gate_status: .*/gate_status: blocked/" "$STATE_FILE"
        SYSTEM_MSG="⚠️  Loop (prd): Review gate blocked. Address issues then output <gate_decision>PROCEED</gate_decision>"
        PROMPT_TEXT=$(generate_prd_phase_prompt "3.5")
        jq -n --arg prompt "$PROMPT_TEXT" --arg msg "$SYSTEM_MSG" '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
        exit 0
      fi
    elif [[ -n "$REVIEWS_COMPLETE_MARKER" ]] && [[ -z "$GATE_DECISION" ]]; then
      # reviews_complete but no gate_decision - prompt for gate decision
      SYSTEM_MSG="✅ Loop (prd): Reviews complete. Now output <gate_decision>PROCEED</gate_decision> or <gate_decision>BLOCK</gate_decision>."
      PROMPT_TEXT=$(generate_prd_phase_prompt "3.5")
      jq -n --arg prompt "$PROMPT_TEXT" --arg msg "$SYSTEM_MSG" '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
      exit 0
    fi
  fi

  # Generic phase completion
  # IMPORTANT: Validate that phase attribute matches current phase to prevent
  # accidental advancement from example markers in documentation/output
  if [[ -n "$PHASE_COMPLETE" ]] && [[ "$PHASE_COMPLETE" == "$CURRENT_PHASE" ]] && [[ "$CURRENT_PHASE" != "3.5" ]] && [[ -z "$INVALID_NEXT_REASON" ]]; then
    # Determine next phase based on current phase
    case "$CURRENT_PHASE" in
      "1") NEXT_PHASE="${MARKER_NEXT:-2}" ;;
      "2")
        if [[ "$MARKER_NEXT" == "2.5" ]]; then
          NEXT_PHASE="2.5"
          # Completed wave 1, going to research
        elif [[ "$MARKER_NEXT" == "3" ]]; then
          NEXT_PHASE="3"
          # Interview complete, all waves done
        else
          NEXT_PHASE="2.5"  # Default to research after wave 1
        fi
        ;;
      "2.5")
        NEXT_PHASE="${MARKER_NEXT:-2}"  # Back to interview
        # Advance to next wave after research
        NEW_WAVE=$((INTERVIEW_WAVE + 1))
        [[ $NEW_WAVE -gt 5 ]] && NEW_WAVE=5
        sed_inplace "s/^interview_wave: .*/interview_wave: $NEW_WAVE/" "$STATE_FILE"
        INTERVIEW_WAVE=$NEW_WAVE
        ;;
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
    if [[ -n "$NEXT_PHASE" ]]; then
      SYSTEM_MSG="✅ Loop (prd): Phase $CURRENT_PHASE complete! Advancing to phase $NEXT_PHASE."
    fi
  fi

  # =============================================================================
  # FALLBACK DETECTION: Auto-advance when work is done but marker is missing
  # Ralph-loop style: file existence is truth, markers are optional signals
  # Phase 3.5 is a strict gate: no auto-advance without explicit gate_decision.
  # =============================================================================

  # Auto-discover paths from convention if not set
  EXPECTED_SPEC="plans/$FEATURE_NAME/spec.md"
  EXPECTED_PRD="plans/$FEATURE_NAME/prd.json"

  if [[ -z "$NEXT_PHASE" ]] && [[ -z "$INVALID_NEXT_REASON" ]]; then
    case "$CURRENT_PHASE" in
      "3")
        # Check if spec file exists at convention path
        if [[ -f "$EXPECTED_SPEC" ]]; then
          echo "⚠️  Loop (prd): Phase 3 work detected (spec.md exists). Auto-advancing to 3.2." >&2
          NEXT_PHASE="3.2"
          # Update state with discovered path
          SPEC_PATH="$EXPECTED_SPEC"
          ESCAPED_PATH=$(escape_sed_replacement "$SPEC_PATH")
          sed_inplace "s|^spec_path: .*|spec_path: \"$ESCAPED_PATH\"|" "$STATE_FILE"
          SYSTEM_MSG="⚠️ Loop (prd): Auto-advanced from 3→3.2 (marker missing but spec.md exists)"
        fi
        ;;
      "3.2")
        # Check if spec has Implementation Patterns section
        SPEC_TO_CHECK="${SPEC_PATH:-$EXPECTED_SPEC}"
        if [[ -f "$SPEC_TO_CHECK" ]] && grep -q "## Implementation Patterns" "$SPEC_TO_CHECK" 2>/dev/null; then
          echo "⚠️  Loop (prd): Phase 3.2 work detected (spec has Implementation Patterns). Auto-advancing to 3.5." >&2
          NEXT_PHASE="3.5"
          SYSTEM_MSG="⚠️ Loop (prd): Auto-advanced from 3.2→3.5 (marker missing but work done)"
        fi
        ;;
      "4")
        # Check if PRD JSON file exists at convention path
        PRD_TO_CHECK="${PRD_PATH:-$EXPECTED_PRD}"
        if [[ -f "$PRD_TO_CHECK" ]] && jq empty "$PRD_TO_CHECK" 2>/dev/null; then
          echo "⚠️  Loop (prd): Phase 4 work detected (PRD file exists). Auto-advancing to 5." >&2
          NEXT_PHASE="5"
          PRD_PATH="$PRD_TO_CHECK"
          ESCAPED_PATH=$(escape_sed_replacement "$PRD_PATH")
          sed_inplace "s|^prd_path: .*|prd_path: \"$ESCAPED_PATH\"|" "$STATE_FILE"
          SYSTEM_MSG="⚠️ Loop (prd): Auto-advanced from 4→5 (marker missing but PRD exists)"
        fi
        ;;
      "5")
        # Check if prd.json has log array (structure verified)
        PRD_TO_CHECK="${PRD_PATH:-$EXPECTED_PRD}"
        if [[ -f "$PRD_TO_CHECK" ]] && jq -e '.log' "$PRD_TO_CHECK" >/dev/null 2>&1; then
          echo "⚠️  Loop (prd): Phase 5 work detected (prd.json has log array). Auto-advancing to 5.5." >&2
          NEXT_PHASE="5.5"
          SYSTEM_MSG="⚠️ Loop (prd): Auto-advanced from 5→5.5 (marker missing but prd.json structure verified)"
        fi
        ;;
      "5.5")
        # Check if max_iterations is already set in prd.json (agent may have written it there)
        PRD_TO_CHECK="${PRD_PATH:-$EXPECTED_PRD}"
        if [[ -f "$PRD_TO_CHECK" ]]; then
          PRD_MAX_ITER=$(jq -r '.max_iterations // empty' "$PRD_TO_CHECK" 2>/dev/null)
          # Accept any positive integer (consistent with marker flow)
          if [[ -n "$PRD_MAX_ITER" ]] && [[ "$PRD_MAX_ITER" =~ ^[0-9]+$ ]] && [[ "$PRD_MAX_ITER" -gt 0 ]]; then
            echo "⚠️  Loop (prd): Phase 5.5 work detected (max_iterations in prd.json). Auto-advancing to 6." >&2
            NEXT_PHASE="6"
            sed_inplace "s/^max_iterations: .*/max_iterations: $PRD_MAX_ITER/" "$STATE_FILE"
            MAX_ITERATIONS="$PRD_MAX_ITER"
            SYSTEM_MSG="⚠️ Loop (prd): Auto-advanced from 5.5→6 (max_iterations=$PRD_MAX_ITER found in prd.json)"
          fi
        fi
        ;;
      "6")
        # Phase 6 is just presentation - if spec and prd exist with log, PRD is complete
        prd_check="${PRD_PATH:-$EXPECTED_PRD}"
        spec_check="${SPEC_PATH:-$EXPECTED_SPEC}"
        if [[ -f "$prd_check" ]] && [[ -f "$spec_check" ]] && jq -e '.log' "$prd_check" >/dev/null 2>&1; then
          echo "✅ Loop (prd): Phase 6 - PRD files exist with valid structure. Completing loop." >&2
          notify "Loop (prd)" "PRD complete for $FEATURE_NAME!"
          rm "$STATE_FILE"
          exit 0
        fi
        ;;
    esac
  fi

  if [[ -z "$NEXT_PHASE" ]] && [[ "$VALID_MARKER_FOUND" != "true" ]]; then
    # No valid marker found - increment phase iteration (ralph-loop style: never stop, just keep prompting)
    PHASE_ITERATION=$((PHASE_ITERATION + 1))

    # Update or add phase_iteration field
    if grep -q '^phase_iteration:' "$STATE_FILE"; then
      sed_inplace "s/^phase_iteration: .*/phase_iteration: $PHASE_ITERATION/" "$STATE_FILE"
    else
      sed_inplace "2i\\
phase_iteration: $PHASE_ITERATION" "$STATE_FILE"
    fi

    # Build system message - just inform, don't stop
    if [[ -n "$INVALID_NEXT_REASON" ]]; then
      SYSTEM_MSG="🔄 Loop (prd): Phase $CURRENT_PHASE iteration $PHASE_ITERATION - $INVALID_NEXT_REASON"
    elif [[ $PHASE_ITERATION -eq 1 ]]; then
      SYSTEM_MSG="🔄 Loop (prd): Phase $CURRENT_PHASE - continuing"
    else
      SYSTEM_MSG="🔄 Loop (prd): Phase $CURRENT_PHASE iteration $PHASE_ITERATION - work in progress"
    fi

    # Generate phase prompt
    PROMPT_TEXT=$(generate_prd_phase_prompt "$CURRENT_PHASE")

    # Add gentle reminder only after first iteration (not aggressive)
    if [[ $PHASE_ITERATION -gt 1 ]] && [[ -n "$INVALID_NEXT_REASON" ]]; then
      PROMPT_TEXT="$PROMPT_TEXT

---
**Note:** $INVALID_NEXT_REASON"
    fi

    jq -n --arg prompt "$PROMPT_TEXT" --arg msg "$SYSTEM_MSG" '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
    exit 0
  fi

  # Update state file with new phase
  sed_inplace "s/^current_phase: .*/current_phase: \"$NEXT_PHASE\"/" "$STATE_FILE"

  # Reset phase iteration on successful phase transition
  sed_inplace "s/^phase_iteration: .*/phase_iteration: 0/" "$STATE_FILE"

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
      local prd_for_log
      prd_for_log=$(get_field "$FRONTMATTER" "prd_path")
      log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"loop_complete\",\"notes\":\"Promise fulfilled: $COMPLETION_PROMISE\"}" "$prd_for_log"
    else
      log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"loop_complete\",\"iteration\":$ITERATION,\"notes\":\"Promise fulfilled: $COMPLETION_PROMISE\"}"
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
  SPEC_PATH=$(get_field "$FRONTMATTER" "spec_path")
  FEATURE_NAME=$(get_field "$FRONTMATTER" "feature_name")

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

  # ==========================================================================
  # SINGLE SOURCE OF TRUTH: Derive state from prd.json
  # ==========================================================================
  TOTAL_STORIES=$(jq '.stories | length' "$PRD_PATH")
  COMPLETED_COUNT=$(jq '[.stories[] | select(.passes == true)] | length' "$PRD_PATH")

  # Parse structured output markers FIRST (before checking "all complete")
  # This allows us to validate a story_complete marker even when all stories show passes=true
  REVIEWS_COMPLETE_MARKER=$(extract_regex_last "$LAST_OUTPUT" '<reviews_complete/>')
  STORY_COMPLETE_MARKER=$(extract_regex_last "$LAST_OUTPUT" '<story_complete[^>]*story_id="([^"]+)"')
  TASKS_SYNCED_MARKER=$(extract_regex_last "$LAST_OUTPUT" '<tasks_synced/>')

  # Update task_list_synced when marker detected
  if [[ -n "$TASKS_SYNCED_MARKER" ]]; then
    if grep -q '^task_list_synced:' "$STATE_FILE"; then
      sed_inplace "s/^task_list_synced: .*/task_list_synced: true/" "$STATE_FILE"
    fi
  fi

  # Current story = first story with passes: false (sorted by priority)
  CURRENT_STORY_ID=$(jq -r '[.stories[] | select(.passes == false)] | sort_by(.priority) | first | .id // empty' "$PRD_PATH")

  # If all stories complete AND no pending story_complete marker, we're done
  if [[ -z "$CURRENT_STORY_ID" ]] && [[ -z "$STORY_COMPLETE_MARKER" ]]; then
    echo "✅ Loop (go/prd): All stories complete!"
    notify "Loop (go/prd)" "All stories complete! $FEATURE_NAME done"
    log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"loop_complete\",\"notes\":\"All $TOTAL_STORIES stories complete\"}" "$PRD_PATH"
    show_loop_summary "$STATE_FILE" "$ITERATION"
    rm "$STATE_FILE"
    exit 0
  fi

  # NOTE: Reconciliation removed - state is now derived from prd.json each time
  # No drift possible since prd.json IS the source of truth

  STORY_TITLE=""
  if [[ -n "$CURRENT_STORY_ID" ]]; then
    STORY_TITLE=$(jq -r ".stories[] | select(.id == $CURRENT_STORY_ID) | .title" "$PRD_PATH")
  fi

  # ==========================================================================
  # NEW LOGIC: If story_complete marker present, use that story ID for validation
  # This handles the case where Claude set passes=true before outputting marker
  # ==========================================================================
  if [[ -n "$STORY_COMPLETE_MARKER" ]]; then
    MARKER_STORY_ID="$STORY_COMPLETE_MARKER"
    MARKER_PASSES=$(jq ".stories[] | select(.id == $MARKER_STORY_ID) | .passes" "$PRD_PATH" 2>/dev/null || echo "false")

    # Verify the story exists
    if ! jq -e ".stories[] | select(.id == $MARKER_STORY_ID)" "$PRD_PATH" >/dev/null 2>&1; then
      PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")
      SYSTEM_MSG="🔄 Loop (go/prd): Invalid story_id in marker. Story #$MARKER_STORY_ID not found in prd.json"
      jq -n --arg prompt "$PROMPT_TEXT" --arg msg "$SYSTEM_MSG" '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
      exit 0
    fi

    # Verify prd.json shows passes: true for the marked story
    if [[ "$MARKER_PASSES" != "true" ]]; then
      PROMPT_TEXT="**prd.json needs update**

You output \`<story_complete story_id=\"$MARKER_STORY_ID\"/>\` but prd.json still shows \`passes: false\` for story #$MARKER_STORY_ID.

**Fix with this edit:**
\`\`\`
File: $PRD_PATH
Find story with id: $MARKER_STORY_ID
Change: \"passes\": false
To:     \"passes\": true
\`\`\`

After updating prd.json, output the marker again:
\`<story_complete story_id=\"$MARKER_STORY_ID\"/>\`"
      SYSTEM_MSG="🔄 Loop (go/prd): prd.json shows passes: false for story #$MARKER_STORY_ID. Update it, then re-output marker."
      jq -n --arg prompt "$PROMPT_TEXT" --arg msg "$SYSTEM_MSG" '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
      exit 0
    fi

    # Verify reviews were done (MANDATORY quality gate)
    if [[ -z "$REVIEWS_COMPLETE_MARKER" ]]; then
      PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")
      SYSTEM_MSG="🔄 Loop (go/prd): <story_complete/> found but <reviews_complete/> missing. Run reviews first."
      jq -n --arg prompt "$PROMPT_TEXT" --arg msg "$SYSTEM_MSG" '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
      exit 0
    fi

    # All checks passed for marker - use marker story as current for advancement
    CURRENT_STORY_ID="$MARKER_STORY_ID"
    # Fall through to commit check and advancement
  else
    # No marker yet - check what the current story needs
    CURRENT_PASSES=$(jq ".stories[] | select(.id == $CURRENT_STORY_ID) | .passes" "$PRD_PATH" 2>/dev/null || echo "false")
    PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")

    if [[ "$CURRENT_PASSES" != "true" ]]; then
      SYSTEM_MSG="🔄 Loop (go/prd): Story #$CURRENT_STORY_ID - working on verification steps.

**When steps pass, update prd.json:**
Edit \`$PRD_PATH\` → find story id:$CURRENT_STORY_ID → set \"passes\": true

Then run reviews and output markers."
    elif [[ -z "$REVIEWS_COMPLETE_MARKER" ]]; then
      SYSTEM_MSG="🔄 Loop (go/prd): Story #$CURRENT_STORY_ID passes ✓ Now run reviews.

**Steps:**
1. Run code-simplifier: \`pr-review-toolkit:code-simplifier\` (max_turns: 15)
2. Run Kieran reviewer for your code type (max_turns: 20)
3. Address findings
4. Output: \`<reviews_complete/>\`
5. Commit with story reference
6. Output: \`<story_complete story_id=\"$CURRENT_STORY_ID\"/>\`"
    else
      # Reviews done, passes true, but no story_complete marker
      # FALLBACK: Check if commit exists - if so, auto-advance without marker
      if git log --oneline -10 2>/dev/null | grep -qiE "(story.*#?${CURRENT_STORY_ID}([^0-9]|$)|#${CURRENT_STORY_ID}([^0-9]|$)|story ${CURRENT_STORY_ID}([^0-9]|$))"; then
        echo "⚠️  Loop (go/prd): AUTO-ADVANCE - Story #$CURRENT_STORY_ID passes ✓ reviews ✓ commit ✓ (marker missing but work complete)" >&2
        # Synthesize the marker and fall through to advancement
        STORY_COMPLETE_MARKER="$CURRENT_STORY_ID"
      else
        SYSTEM_MSG="🔄 Loop (go/prd): Reviews done ✓ Story passes ✓ Now commit and output:
\`<story_complete story_id=\"$CURRENT_STORY_ID\"/>\`"
        jq -n \
          --arg prompt "$PROMPT_TEXT" \
          --arg msg "$SYSTEM_MSG" \
          '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
        exit 0
      fi
    fi

    # If we still don't have a marker, block and wait
    if [[ -z "$STORY_COMPLETE_MARKER" ]]; then
      jq -n \
        --arg prompt "$PROMPT_TEXT" \
        --arg msg "$SYSTEM_MSG" \
        '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
      exit 0
    fi
  fi

    # Step 4: Verify reviews were run
    if [[ -z "$REVIEWS_COMPLETE_MARKER" ]]; then
      PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")
      SYSTEM_MSG="🔄 Loop (go/prd): <story_complete/> found but <reviews_complete/> missing. Run reviews first."
      jq -n --arg prompt "$PROMPT_TEXT" --arg msg "$SYSTEM_MSG" '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
      exit 0
    fi

    # Step 5: Verify commit exists
    # Use word boundary ([^0-9]|$) to prevent #1 matching #10, #11, etc.
    if git log --oneline -10 2>/dev/null | grep -qiE "(story.*#?${CURRENT_STORY_ID}([^0-9]|$)|#${CURRENT_STORY_ID}([^0-9]|$)|story ${CURRENT_STORY_ID}([^0-9]|$))"; then
        # Commit found - get commit hash for logging
        COMMIT_HASH=$(git log --format="%h" -1 2>/dev/null || echo "unknown")

        # Update story with completed_at and commit in prd.json
        NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        temp_file="/tmp/prd_update_$$.tmp"
        jq --arg now "$NOW" --arg commit "$COMMIT_HASH" --argjson sid "$CURRENT_STORY_ID" \
          '(.stories[] | select(.id == $sid)) |= . + {completed_at: $now, commit: $commit}' \
          "$PRD_PATH" > "$temp_file" && mv "$temp_file" "$PRD_PATH"

        # Log to embedded log in prd.json
        log_progress "{\"ts\":\"$NOW\",\"event\":\"story_complete\",\"story_id\":$CURRENT_STORY_ID,\"commit\":\"$COMMIT_HASH\"}" "$PRD_PATH"

        # Find next incomplete story
        NEXT_STORY_ID=$(jq -r '[.stories[] | select(.passes == false)] | sort_by(.priority) | first | .id // empty' "$PRD_PATH")

        if [[ -z "$NEXT_STORY_ID" ]]; then
          echo "✅ Loop (go/prd): All stories complete!"
          echo "   Feature '$FEATURE_NAME' is done."
          notify "Loop (go/prd)" "All stories complete! $FEATURE_NAME done"
          log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"loop_complete\",\"notes\":\"All $TOTAL_STORIES stories complete\"}" "$PRD_PATH"
          show_loop_summary "$STATE_FILE" "$ITERATION"
          rm "$STATE_FILE"
          exit 0
        fi

        # Advance to next story - rebuild state file
        NEXT_ITERATION=$((ITERATION + 1))
        NEXT_STORY=$(jq ".stories[] | select(.id == $NEXT_STORY_ID)" "$PRD_PATH")
        NEXT_TITLE=$(echo "$NEXT_STORY" | jq -r '.title')
        INCOMPLETE_COUNT=$(jq '[.stories[] | select(.passes == false)] | length' "$PRD_PATH")

        # Handle skills array from story
        NEXT_SKILLS_JSON=$(echo "$NEXT_STORY" | jq -r '.skills // empty')

        # Extract task_id for this story from story_tasks (if synced)
        # Don't use get_field - it breaks JSON. Extract directly from YAML.
        NEXT_TASK_ID=""
        STORY_TASKS_JSON=$(sed -n "s/^story_tasks: '\\(.*\\)'/\\1/p" "$STATE_FILE" | head -1)
        if [[ -n "$STORY_TASKS_JSON" ]] && [[ "$STORY_TASKS_JSON" != "{}" ]]; then
          # Parse JSON to find task for this story (using jq for safety)
          NEXT_TASK_ID=$(echo "$STORY_TASKS_JSON" | jq -r ".\"$NEXT_STORY_ID\" // empty" 2>/dev/null)
        fi

        SKILL_FRONTMATTER=""
        SKILL_SECTION=""
        SKILLS_LOG=""
        WORKING_BRANCH=$(get_field "$FRONTMATTER" "working_branch")
        BRANCH_SETUP_DONE=$(get_field "$FRONTMATTER" "branch_setup_done")
        BRANCH_FRONTMATTER=""

        if [[ -n "$NEXT_SKILLS_JSON" ]] && [[ "$NEXT_SKILLS_JSON" != "null" ]]; then
          SKILLS_LIST=$(echo "$NEXT_SKILLS_JSON" | jq -r '.[]' 2>/dev/null || echo "")
          if [[ -n "$SKILLS_LIST" ]]; then
            SKILL_FRONTMATTER="skills: $NEXT_SKILLS_JSON"
            SKILLS_LOG=$(echo "$SKILLS_LIST" | LC_ALL=C tr '\n' ',' | sed 's/,$//')
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
        fi

        if [[ -n "$WORKING_BRANCH" ]]; then
          WORKING_BRANCH=${WORKING_BRANCH//\"/\\\"}
          BRANCH_FRONTMATTER="working_branch: \"$WORKING_BRANCH\""
        fi
        if [[ -n "$BRANCH_SETUP_DONE" ]]; then
          if [[ -n "$BRANCH_FRONTMATTER" ]]; then
            BRANCH_FRONTMATTER="$BRANCH_FRONTMATTER
branch_setup_done: $BRANCH_SETUP_DONE"
          else
            BRANCH_FRONTMATTER="branch_setup_done: $BRANCH_SETUP_DONE"
          fi
        fi

        # Log story_started to embedded log
        if [[ -n "$SKILLS_LOG" ]]; then
          log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"story_started\",\"story_id\":$NEXT_STORY_ID,\"skills\":\"$SKILLS_LOG\"}" "$PRD_PATH"
        else
          log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"story_started\",\"story_id\":$NEXT_STORY_ID}" "$PRD_PATH"
        fi

        # Build minimal frontmatter (state derived from prd.json)
        # Only keep: loop_type, mode, prd_path, started_at, working_branch
        FRONTMATTER_CONTENT="---
loop_type: \"go\"
mode: \"prd\"
active: true
prd_path: \"$PRD_PATH\"
spec_path: \"$SPEC_PATH\"
feature_name: \"$FEATURE_NAME\""
        if [[ -n "$SKILL_FRONTMATTER" ]]; then
          FRONTMATTER_CONTENT="$FRONTMATTER_CONTENT
$SKILL_FRONTMATTER"
        fi
        if [[ -n "$BRANCH_FRONTMATTER" ]]; then
          FRONTMATTER_CONTENT="$FRONTMATTER_CONTENT
$BRANCH_FRONTMATTER"
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
6. **Update \`$PRD_PATH\`**: set \`passes: true\` for story $NEXT_STORY_ID
7. **Commit** with type: \`<type>($FEATURE_NAME): story #$NEXT_STORY_ID - $NEXT_TITLE\`
8. Output markers: \`<reviews_complete/>\` then \`<story_complete story_id=\"$NEXT_STORY_ID\"/>\`

**Hook handles automatically:** progress log in prd.json (don't touch it)

CRITICAL: Only mark the story as passing when it genuinely passes all verification steps."

        # Add task reference if synced
        if [[ -n "$NEXT_TASK_ID" ]]; then
          BODY_CONTENT="$BODY_CONTENT

## Task System (Ctrl+T)

**Task:** \`$NEXT_TASK_ID\`
- On story start: \`TaskUpdate(\"$NEXT_TASK_ID\", status: \"in_progress\")\`
- On story complete: \`TaskUpdate(\"$NEXT_TASK_ID\", status: \"completed\")\`"
        fi

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
        # Story passes but no commit - remind to commit with exact command
        NEXT_ITERATION=$((ITERATION + 1))
        update_iteration "$STATE_FILE" "$NEXT_ITERATION"

        PROMPT_TEXT="**Commit needed for story #$CURRENT_STORY_ID**

All checks pass except commit verification. The hook scans the last 10 commits for a reference to story #$CURRENT_STORY_ID.

**Create commit:**
\`\`\`bash
git add -A && git commit -m \"feat($FEATURE_NAME): story #$CURRENT_STORY_ID - $STORY_TITLE\"
\`\`\`

**Required patterns (any of these work):**
- \`story #$CURRENT_STORY_ID\`
- \`#$CURRENT_STORY_ID\` (with word boundary)
- \`story $CURRENT_STORY_ID\`

After committing, output:
\`<story_complete story_id=\"$CURRENT_STORY_ID\"/>\`"
        SYSTEM_MSG="🔄 Loop (go/prd): Story passes ✓ Reviews done ✓ Now commit with story reference."

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
  # Get state JSON path (single source of truth for UT/E2E)
  STATE_JSON=$(get_field "$FRONTMATTER" "state_json")

  # Parse markers
  REVIEWS_COMPLETE_MARKER=$(extract_regex_last "$LAST_OUTPUT" '<reviews_complete/>')
  ITER_COMPLETE_MARKER=$(extract_regex_last "$LAST_OUTPUT" '<iteration_complete[^>]*test_file="([^"]+)"')
  TASKS_SYNCED_MARKER=$(extract_regex_last "$LAST_OUTPUT" '<tasks_synced/>')

  # Update task_list_synced when marker detected
  if [[ -n "$TASKS_SYNCED_MARKER" ]]; then
    if grep -q '^task_list_synced:' "$STATE_FILE"; then
      sed_inplace "s/^task_list_synced: .*/task_list_synced: true/" "$STATE_FILE"
    fi
  fi

  # Fallback detection: Check for test commit in git log (ralph-loop style)
  # If test commit exists but markers missing, we can still advance
  TEST_COMMIT_FOUND=false
  TEST_COMMIT_FILE=""
  if [[ "$ACTIVE_LOOP" == "ut" ]]; then
    # Look for test commits (test: or test(scope): formats)
    if git log --oneline -5 2>/dev/null | grep -qiE "^[a-f0-9]+ test[:(]"; then
      TEST_COMMIT_FOUND=true
      # Try to extract test file from recent commit
      TEST_COMMIT_FILE=$(git diff --name-only HEAD~1 2>/dev/null | grep -E '\.(test|spec)\.(ts|tsx|js|jsx)$' | head -1 || echo "")
    fi
  elif [[ "$ACTIVE_LOOP" == "e2e" ]]; then
    # Look for test or e2e commits (test: or test(scope): formats)
    if git log --oneline -5 2>/dev/null | grep -qiE "^[a-f0-9]+ (test|e2e)[:(]"; then
      TEST_COMMIT_FOUND=true
      TEST_COMMIT_FILE=$(git diff --name-only HEAD~1 2>/dev/null | grep -E '\.(e2e|spec|test)\.(ts|tsx|js|jsx)$' | head -1 || echo "")
    fi
  fi

  # Step 1: Check for reviews_complete marker (MANDATORY - quality gate, no fallback)
  if [[ -z "$REVIEWS_COMPLETE_MARKER" ]]; then
    PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")
    SYSTEM_MSG="🔄 Loop ($ACTIVE_LOOP): Reviews not yet run. Run reviewers before completing iteration.

**Steps:**
1. Run code-simplifier: \`pr-review-toolkit:code-simplifier\` (max_turns: 15)
2. Run Kieran reviewer for your code type (max_turns: 20)
3. Address findings
4. Output: \`<reviews_complete/>\`
5. Commit and output: \`<iteration_complete test_file=\"...\"/>\`"

    jq -n \
      --arg prompt "$PROMPT_TEXT" \
      --arg msg "$SYSTEM_MSG" \
      '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
    exit 0
  fi

  # Step 2: Check for iteration_complete marker OR fallback to git detection
  if [[ -z "$ITER_COMPLETE_MARKER" ]]; then
    if [[ "$TEST_COMMIT_FOUND" == "true" ]]; then
      # Fallback: Test commit exists but marker missing - auto-advance
      echo "⚠️  Loop ($ACTIVE_LOOP): AUTO-ADVANCE - reviews ✓ test commit ✓ (marker missing but work complete)" >&2
      ITER_COMPLETE_MARKER="${TEST_COMMIT_FILE:-auto-detected}"
      # Fall through to success path
    else
      # No marker and no test commit - continue working
      PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")
      SYSTEM_MSG="🔄 Loop ($ACTIVE_LOOP): Reviews done ✓ Commit your test, then output: <iteration_complete test_file=\"path/to/test.ts\"/>"

      jq -n \
        --arg prompt "$PROMPT_TEXT" \
        --arg msg "$SYSTEM_MSG" \
        '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
      exit 0
    fi
  fi

  # Step 3: Verify commit exists (or already verified via fallback)
  if [[ "$TEST_COMMIT_FOUND" == "true" ]] || git log --oneline -5 2>/dev/null | grep -qiE "^[a-f0-9]+ (test|e2e)[:(]"; then
    # All checks passed - log to state.json and continue to advance
    COMMIT_HASH=$(git log --format="%h" -1 2>/dev/null || echo "unknown")
    log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"iteration_complete\",\"iteration\":$ITERATION,\"test_file\":\"$ITER_COMPLETE_MARKER\",\"commit\":\"$COMMIT_HASH\"}" "$STATE_JSON"
    echo "✓ Loop ($ACTIVE_LOOP): Iteration $ITERATION complete - reviews ✓ commit ✓ $ITER_COMPLETE_MARKER"
  else
    # Markers but no commit - continue working
    PROMPT_TEXT=$(awk '/^---$/{i++; next} i>=2' "$STATE_FILE")
    SYSTEM_MSG="🔄 Loop ($ACTIVE_LOOP): Reviews done ✓ Commit your test: git add && git commit -m \"test(...): ...\""

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
      GO_PRD_PATH=$(get_field "$FRONTMATTER" "prd_path")
      # Derive current story from prd.json (single source of truth)
      CURRENT_STORY=$(jq -r '[.stories[] | select(.passes == false)] | sort_by(.priority) | first | .id // "unknown"' "$GO_PRD_PATH" 2>/dev/null || echo "unknown")
      SYSTEM_MSG="🔄 Loop (go/prd) iteration $NEXT_ITERATION | Story #$CURRENT_STORY not yet passing"
      log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"iteration_started\",\"iteration\":$NEXT_ITERATION,\"story_id\":$CURRENT_STORY}" "$GO_PRD_PATH"
    else
      SYSTEM_MSG="🔄 Loop (go) iteration $NEXT_ITERATION | Output <promise>$COMPLETION_PROMISE</promise> when done"
      log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"iteration_started\",\"iteration\":$NEXT_ITERATION}"
    fi
    ;;
  ut)
    TARGET_COVERAGE=$(get_field "$FRONTMATTER" "target_coverage")
    UT_STATE_JSON=$(get_field "$FRONTMATTER" "state_json")
    if [[ -n "$TARGET_COVERAGE" ]] && [[ "$TARGET_COVERAGE" != "0" ]]; then
      SYSTEM_MSG="🔄 Loop (ut) iteration $NEXT_ITERATION | Target: ${TARGET_COVERAGE}% | Output <promise>$COMPLETION_PROMISE</promise> when done"
      log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"iteration_started\",\"iteration\":$NEXT_ITERATION,\"target_coverage\":$TARGET_COVERAGE}" "$UT_STATE_JSON"
    else
      SYSTEM_MSG="🔄 Loop (ut) iteration $NEXT_ITERATION | Output <promise>$COMPLETION_PROMISE</promise> when done"
      log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"iteration_started\",\"iteration\":$NEXT_ITERATION}" "$UT_STATE_JSON"
    fi
    ;;
  e2e)
    E2E_STATE_JSON=$(get_field "$FRONTMATTER" "state_json")
    SYSTEM_MSG="🔄 Loop (e2e) iteration $NEXT_ITERATION | Output <promise>$COMPLETION_PROMISE</promise> when all flows covered"
    log_progress "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"iteration_started\",\"iteration\":$NEXT_ITERATION}" "$E2E_STATE_JSON"
    ;;
esac

# Output JSON to block stop and continue loop
jq -n \
  --arg prompt "$PROMPT_TEXT" \
  --arg msg "$SYSTEM_MSG" \
  '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'

exit 0
