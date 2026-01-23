#!/bin/bash

# =============================================================================
# AFK GO LOOP - External Ralph-Style Iteration Loop
# =============================================================================
#
# PURPOSE: Run Claude Code in an external bash loop for truly AFK (away from
#          keyboard) autonomous coding. Each iteration is a fresh Claude session
#          reading state from files, preventing context rot.
#
# ARCHITECTURE:
#   - External loop (this script) controls iteration count
#   - Each iteration: claude -p "prompt" runs and exits
#   - State persists in prd.json (single source of truth with embedded log)
#   - Fresh context per iteration (no context rot)
#   - Optional streaming output for visibility while AFK
#
# MODES:
#   PRD Mode:     ./afk-go.sh plans/feature/prd.json [OPTIONS]
#   Generic Mode: ./afk-go.sh --prompt "task" --promise "DONE" [OPTIONS]
#
# INSPIRED BY:
#   - Ralph Wiggum pattern (Matt Pocock / aihero.dev)
#   - "Here's How To Stream Claude Code With AFK Ralph"
#
# =============================================================================

set -euo pipefail

# Force consistent locale for text processing
export LC_ALL=C
export LANG=C

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$SCRIPT_DIR")}"

# Source shared helpers
# shellcheck source=lib/loop-helpers.sh
source "$SCRIPT_DIR/lib/loop-helpers.sh"

# Defaults
MAX_ITERATIONS=50
PRD_PATH=""
PROMPT=""
COMPLETION_PROMISE=""
STREAMING=false
SANDBOX=false
VERBOSE=false
DRY_RUN=false
NOTIFY_ON_COMPLETE=true
PERMISSION_MODE="acceptEdits"

# Runtime state
ITERATION=0
START_TIME=""
INTERRUPTED=false

# =============================================================================
# Help & Usage
# =============================================================================

show_help() {
  cat << 'HELP'
AFK Go Loop - External Ralph-Style Iteration Loop

USAGE:
  afk-go.sh <prd.json> [OPTIONS]                     # PRD mode
  afk-go.sh --prompt "task" --promise "DONE" [OPTIONS]  # Generic mode

OPTIONS:
  PRD Mode:
    <prd.json>                   Path to PRD file (auto-detected by .json)

  Generic Mode:
    --prompt <text>              Task description
    --promise <text>             Completion promise (required for generic)

  Iteration Control:
    --max <n>, --max-iterations <n>   Max iterations (default: 50)

  Execution:
    --stream                     Stream Claude output in real-time (jq filter)
    --sandbox                    Run in Docker sandbox (recommended for AFK)
    --permission-mode <mode>     Claude permission mode (default: acceptEdits)
    --verbose                    Show detailed progress
    --dry-run                    Show what would run without executing

  Notifications:
    --no-notify                  Disable desktop notifications

  Help:
    -h, --help                   Show this help

EXAMPLES:
  # PRD mode - implement all stories
  afk-go.sh plans/auth/prd.json --max 30

  # PRD mode with streaming and sandbox
  afk-go.sh plans/auth/prd.json --stream --sandbox

  # Generic mode
  afk-go.sh --prompt "Build CSV parser" --promise "PARSER COMPLETE" --max 10

  # Dry run to preview
  afk-go.sh plans/auth/prd.json --dry-run

STREAMING:
  Without --stream: Output appears only after each iteration completes
  With --stream:    Real-time output via jq filter (see aihero.dev article)

SANDBOX:
  Without --sandbox: Runs claude directly (faster, less isolated)
  With --sandbox:    Runs docker sandbox run claude (safer for AFK)

STOPPING:
  - Ctrl+C to interrupt gracefully (shows summary)
  - All stories pass in prd.json (PRD mode)
  - <promise>TEXT</promise> output (generic mode)
  - Max iterations reached
HELP
}

# =============================================================================
# Logging & Output
# =============================================================================

log_info() {
  echo "[$(date +%H:%M:%S)] $*"
}

log_verbose() {
  if [[ "$VERBOSE" == "true" ]]; then
    echo "[$(date +%H:%M:%S)] [VERBOSE] $*"
  fi
}

log_error() {
  echo "[$(date +%H:%M:%S)] [ERROR] $*" >&2
}

log_success() {
  echo "[$(date +%H:%M:%S)] ✅ $*"
}

log_warning() {
  echo "[$(date +%H:%M:%S)] ⚠️  $*"
}

print_banner() {
  local mode="$1"
  local target="$2"
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  AFK Go Loop - Ralph-Style External Iteration"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Mode:           $mode"
  echo "  Target:         $target"
  echo "  Max iterations: $MAX_ITERATIONS"
  echo "  Streaming:      $STREAMING"
  echo "  Sandbox:        $SANDBOX"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

print_iteration_header() {
  local current="$1"
  local max="$2"
  local status="$3"
  echo ""
  echo "┌──────────────────────────────────────────────────────────────────────┐"
  printf "│  Iteration %d of %d                                                   │\n" "$current" "$max"
  echo "│  $status"
  echo "└──────────────────────────────────────────────────────────────────────┘"
  echo ""
}

# =============================================================================
# Signal Handling
# =============================================================================

cleanup() {
  if [[ "$INTERRUPTED" == "true" ]]; then
    return
  fi
  INTERRUPTED=true

  echo ""
  log_warning "Interrupted by user (Ctrl+C)"
  print_summary
  exit 130
}

trap cleanup SIGINT SIGTERM

# =============================================================================
# Summary & Notifications
# =============================================================================

print_summary() {
  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - START_TIME))
  local mins=$((duration / 60))
  local secs=$((duration % 60))
  local duration_str

  if [[ $mins -gt 0 ]]; then
    duration_str="${mins}m ${secs}s"
  else
    duration_str="${secs}s"
  fi

  # Git stats
  local git_stats=""
  local commit_count=0
  if git rev-parse --git-dir >/dev/null 2>&1; then
    local base_branch
    base_branch=$(detect_main_branch)
    git_stats=$(git diff "$base_branch" --stat 2>/dev/null | tail -1 || echo "")

    local start_iso
    start_iso=$(date -r "$START_TIME" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -d "@$START_TIME" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    if [[ -n "$start_iso" ]]; then
      commit_count=$(git log --since="$start_iso" --oneline 2>/dev/null | wc -l | tr -d ' ')
    fi
  fi

  # PRD stats
  local stories_complete=0
  local stories_total=0
  if [[ -n "$PRD_PATH" ]] && [[ -f "$PRD_PATH" ]]; then
    stories_complete=$(jq '[.stories[] | select(.passes == true)] | length' "$PRD_PATH" 2>/dev/null || echo "0")
    stories_total=$(jq '.stories | length' "$PRD_PATH" 2>/dev/null || echo "0")
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  AFK Loop Summary"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Iterations:     $ITERATION"
  echo "  Duration:       $duration_str"
  [[ "$commit_count" -gt 0 ]] && echo "  Commits:        $commit_count"
  [[ -n "$git_stats" ]] && echo "  Changes:        $git_stats"
  if [[ "$stories_total" -gt 0 ]]; then
    echo "  Stories:        $stories_complete / $stories_total complete"
  fi
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

send_notification() {
  local title="$1"
  local message="$2"

  if [[ "$NOTIFY_ON_COMPLETE" == "true" ]]; then
    notify "$title" "$message"
  fi
}

# =============================================================================
# Claude Execution
# =============================================================================

# Build the claude command
build_claude_command() {
  local prompt="$1"
  local cmd_parts=()

  if [[ "$SANDBOX" == "true" ]]; then
    cmd_parts+=(docker sandbox run --credentials host claude)
  else
    cmd_parts+=(claude)
  fi

  cmd_parts+=(--permission-mode "$PERMISSION_MODE")
  cmd_parts+=(-p)

  if [[ "$STREAMING" == "true" ]]; then
    cmd_parts+=(--output-format stream-json)
    cmd_parts+=(--verbose)
  else
    cmd_parts+=(--print)
  fi

  # Store command for execution (prompt added separately)
  printf '%s\n' "${cmd_parts[@]}"
}

# Execute claude with streaming support
run_claude_streaming() {
  local prompt="$1"
  local tmpfile
  tmpfile=$(mktemp)

  # jq filters from aihero.dev article
  local stream_text='select(.type == "assistant").message.content[]? | select(.type == "text").text // empty | gsub("\n"; "\r\n") | . + "\r\n\n"'
  local final_result='select(.type == "result").result // empty'

  local cmd_args
  cmd_args=$(build_claude_command "$prompt")

  # Build command array
  local -a cmd=()
  while IFS= read -r line; do
    cmd+=("$line")
  done <<< "$cmd_args"

  log_verbose "Executing: ${cmd[*]} <prompt>"

  # Execute with streaming
  "${cmd[@]}" "$prompt" 2>&1 \
    | grep --line-buffered '^{' \
    | tee "$tmpfile" \
    | jq --unbuffered -rj "$stream_text" 2>/dev/null || true

  # Extract final result
  local result
  result=$(jq -rs "$final_result" "$tmpfile" 2>/dev/null || cat "$tmpfile")

  rm -f "$tmpfile"
  printf '%s' "$result"
}

# Execute claude without streaming
run_claude_simple() {
  local prompt="$1"

  local cmd_args
  cmd_args=$(build_claude_command "$prompt")

  # Build command array
  local -a cmd=()
  while IFS= read -r line; do
    cmd+=("$line")
  done <<< "$cmd_args"

  log_verbose "Executing: ${cmd[*]} <prompt>"

  "${cmd[@]}" "$prompt" 2>&1
}

# Main execution wrapper
run_claude() {
  local prompt="$1"

  if [[ "$STREAMING" == "true" ]]; then
    run_claude_streaming "$prompt"
  else
    run_claude_simple "$prompt"
  fi
}

# =============================================================================
# PRD Mode
# =============================================================================

validate_prd() {
  if [[ ! -f "$PRD_PATH" ]]; then
    log_error "PRD file not found: $PRD_PATH"
    exit 1
  fi

  if ! jq empty "$PRD_PATH" 2>/dev/null; then
    log_error "Invalid JSON in PRD file: $PRD_PATH"
    exit 1
  fi

  local story_count
  story_count=$(jq '.stories | length' "$PRD_PATH")
  if [[ "$story_count" -eq 0 ]]; then
    log_error "No stories found in PRD file"
    exit 1
  fi

  log_verbose "PRD validated: $story_count stories"
}

get_prd_status() {
  local incomplete complete total
  incomplete=$(jq '[.stories[] | select(.passes == false)] | length' "$PRD_PATH")
  complete=$(jq '[.stories[] | select(.passes == true)] | length' "$PRD_PATH")
  total=$(jq '.stories | length' "$PRD_PATH")
  echo "$complete/$total complete ($incomplete remaining)"
}

get_next_story() {
  jq -r '[.stories[] | select(.passes == false)] | sort_by(.priority) | first | .id // empty' "$PRD_PATH"
}

get_story_title() {
  local story_id="$1"
  jq -r ".stories[] | select(.id == $story_id) | .title" "$PRD_PATH"
}

build_prd_prompt() {
  local prd_dir spec_path feature_name
  prd_dir=$(dirname "$PRD_PATH")
  spec_path="$prd_dir/spec.md"
  feature_name=$(basename "$prd_dir")

  local next_story next_title incomplete_count total_count
  next_story=$(get_next_story)
  next_title=$(get_story_title "$next_story")
  incomplete_count=$(jq '[.stories[] | select(.passes == false)] | length' "$PRD_PATH")
  total_count=$(jq '.stories | length' "$PRD_PATH")

  # Get story details including skills
  local story_json skills_json skill_instructions=""
  story_json=$(jq ".stories[] | select(.id == $next_story)" "$PRD_PATH")
  skills_json=$(echo "$story_json" | jq -r '.skills // empty')

  if [[ -n "$skills_json" ]] && [[ "$skills_json" != "null" ]]; then
    local skills_list
    skills_list=$(echo "$skills_json" | jq -r '.[]' 2>/dev/null || echo "")
    if [[ -n "$skills_list" ]]; then
      skill_instructions="
## Required Skills

This story requires the following skills. Load each one BEFORE implementing:
"
      while IFS= read -r skill; do
        [[ -n "$skill" ]] && skill_instructions="${skill_instructions}
- /Skill $skill"
      done <<< "$skills_list"
      skill_instructions="${skill_instructions}

Follow each skill's guidance for implementation patterns and quality standards.
"
    fi
  fi

  cat << PROMPT
@$PRD_PATH @$spec_path

# AFK Go Loop - Story Implementation

You are in an AFK go loop. Work autonomously without asking questions.

## Current Status

- **Feature:** $feature_name
- **Progress:** $incomplete_count of $total_count stories remaining
- **Current Story:** #$next_story - $next_title

## Story Details

\`\`\`json
$story_json
\`\`\`
$skill_instructions
## Your Task

1. **Read** the full spec at \`$spec_path\`
2. **Implement** story #$next_story completely
3. **Verify** all steps listed in the story pass
4. **Run feedback loops:** tests, types, lint (all must pass)
5. **Update prd.json:** set \`passes: true\` for story #$next_story
6. **Run reviews:** spawn code-simplifier + kieran reviewer agents
7. **Commit** with format: \`<type>($feature_name): story #$next_story - $next_title\`

## Code Quality

- Production code only. No shortcuts.
- Minimal comments - code should be self-documenting
- Only comment the non-obvious "why", never the "what"
- Tests live next to the code they test

## Completion

When you have:
1. Implemented the story
2. Updated prd.json with passes: true
3. Committed with story reference

Then EXIT. The loop will check prd.json and continue with the next story.

If ALL stories in prd.json have \`passes: true\`, output:
\`\`\`
<promise>ALL STORIES COMPLETE</promise>
\`\`\`

CRITICAL: Only mark stories as passing when they genuinely pass all verification steps.
PROMPT
}

run_prd_loop() {
  validate_prd

  local feature_name
  feature_name=$(basename "$(dirname "$PRD_PATH")")

  print_banner "PRD" "$PRD_PATH"

  # Log loop start to prd.json's embedded log
  local log_entry="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"afk_loop_started\",\"max_iterations\":$MAX_ITERATIONS}"
  local temp_file="/tmp/prd_afk_start_$$.tmp"
  if jq -e '.log' "$PRD_PATH" >/dev/null 2>&1; then
    jq --argjson entry "$log_entry" '.log += [$entry]' "$PRD_PATH" > "$temp_file" && mv "$temp_file" "$PRD_PATH"
  else
    jq --argjson entry "$log_entry" '. + {log: [$entry]}' "$PRD_PATH" > "$temp_file" && mv "$temp_file" "$PRD_PATH"
  fi

  for ((ITERATION=1; ITERATION<=MAX_ITERATIONS; ITERATION++)); do
    # Check if all stories complete
    local incomplete
    incomplete=$(jq '[.stories[] | select(.passes == false)] | length' "$PRD_PATH")

    if [[ "$incomplete" == "0" ]]; then
      log_success "All stories complete!"
      send_notification "AFK Loop Complete" "All $feature_name stories finished!"

      # Log completion to prd.json's embedded log
      local log_entry="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"afk_loop_complete\",\"iterations\":$((ITERATION-1))}"
      local temp_file="/tmp/prd_afk_complete_$$.tmp"
      jq --argjson entry "$log_entry" '.log += [$entry]' "$PRD_PATH" > "$temp_file" && mv "$temp_file" "$PRD_PATH"

      print_summary
      exit 0
    fi

    # Get current story info
    local next_story next_title status_str
    next_story=$(get_next_story)
    next_title=$(get_story_title "$next_story")
    status_str="Story #$next_story: $next_title | $(get_prd_status)"

    print_iteration_header "$ITERATION" "$MAX_ITERATIONS" "$status_str"

    # Log iteration start to prd.json's embedded log
    local log_entry="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"afk_iteration\",\"iteration\":$ITERATION,\"story_id\":$next_story}"
    local temp_file="/tmp/prd_afk_iter_$$.tmp"
    jq --argjson entry "$log_entry" '.log += [$entry]' "$PRD_PATH" > "$temp_file" && mv "$temp_file" "$PRD_PATH"

    # Build and run prompt
    local prompt result
    prompt=$(build_prd_prompt)

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "=== DRY RUN: Would execute claude with prompt ==="
      echo "$prompt" | head -50
      echo "..."
      echo "=== END DRY RUN ==="
      continue
    fi

    result=$(run_claude "$prompt") || true

    # Check for explicit completion promise
    if [[ "$result" == *"<promise>ALL STORIES COMPLETE</promise>"* ]]; then
      log_success "Detected completion promise - all stories complete!"
      send_notification "AFK Loop Complete" "All $feature_name stories finished!"

      # Log completion to prd.json's embedded log
      local log_entry="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"afk_loop_complete\",\"iterations\":$ITERATION,\"notes\":\"Completion promise detected\"}"
      local temp_file="/tmp/prd_afk_promise_$$.tmp"
      jq --argjson entry "$log_entry" '.log += [$entry]' "$PRD_PATH" > "$temp_file" && mv "$temp_file" "$PRD_PATH"

      print_summary
      exit 0
    fi

    # Brief pause between iterations (prevents rate limiting)
    sleep 2
  done

  # Max iterations reached
  log_warning "Max iterations ($MAX_ITERATIONS) reached"
  send_notification "AFK Loop Stopped" "Max iterations reached for $feature_name"

  # Log max iterations to prd.json's embedded log
  local log_entry="{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"event\":\"afk_max_iterations\",\"iterations\":$MAX_ITERATIONS}"
  local temp_file="/tmp/prd_afk_max_$$.tmp"
  jq --argjson entry "$log_entry" '.log += [$entry]' "$PRD_PATH" > "$temp_file" && mv "$temp_file" "$PRD_PATH"

  print_summary
  exit 1
}

# =============================================================================
# Generic Mode
# =============================================================================

build_generic_prompt() {
  cat << PROMPT
# AFK Go Loop - Task Execution

You are in an AFK go loop. Work autonomously without asking questions.

## Task

$PROMPT

## Instructions

1. Work on the task iteratively
2. Make incremental progress each iteration
3. Commit meaningful changes
4. Run tests, types, lint (all must pass)

## Completion

When the task is GENUINELY complete, output:
\`\`\`
<promise>$COMPLETION_PROMISE</promise>
\`\`\`

CRITICAL: Only output this promise when the task is truly finished.
Do NOT output false promises to escape the loop.
PROMPT
}

run_generic_loop() {
  if [[ -z "$PROMPT" ]]; then
    log_error "--prompt required for generic mode"
    exit 1
  fi

  if [[ -z "$COMPLETION_PROMISE" ]]; then
    log_error "--promise required for generic mode"
    exit 1
  fi

  print_banner "Generic" "$PROMPT"

  for ((ITERATION=1; ITERATION<=MAX_ITERATIONS; ITERATION++)); do
    print_iteration_header "$ITERATION" "$MAX_ITERATIONS" "Working on task..."

    local prompt result
    prompt=$(build_generic_prompt)

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "=== DRY RUN: Would execute claude with prompt ==="
      echo "$prompt" | head -30
      echo "..."
      echo "=== END DRY RUN ==="
      continue
    fi

    result=$(run_claude "$prompt") || true

    # Check for completion promise
    if [[ "$result" == *"<promise>$COMPLETION_PROMISE</promise>"* ]]; then
      log_success "Task complete! Promise fulfilled: $COMPLETION_PROMISE"
      send_notification "AFK Loop Complete" "Task finished: $COMPLETION_PROMISE"
      print_summary
      exit 0
    fi

    sleep 2
  done

  log_warning "Max iterations ($MAX_ITERATIONS) reached"
  send_notification "AFK Loop Stopped" "Max iterations reached"
  print_summary
  exit 1
}

# =============================================================================
# Argument Parsing
# =============================================================================

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help)
        show_help
        exit 0
        ;;
      --prompt)
        PROMPT="$2"
        shift 2
        ;;
      --promise|--completion-promise)
        COMPLETION_PROMISE="$2"
        shift 2
        ;;
      --max|--max-iterations)
        if ! [[ "$2" =~ ^[0-9]+$ ]]; then
          log_error "--max must be a positive integer"
          exit 1
        fi
        MAX_ITERATIONS="$2"
        shift 2
        ;;
      --stream|--streaming)
        STREAMING=true
        shift
        ;;
      --sandbox)
        SANDBOX=true
        shift
        ;;
      --permission-mode)
        PERMISSION_MODE="$2"
        shift 2
        ;;
      --verbose|-v)
        VERBOSE=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --no-notify)
        NOTIFY_ON_COMPLETE=false
        shift
        ;;
      -*)
        log_error "Unknown option: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
      *)
        # Positional argument - check if it's a PRD file
        if [[ "$1" == *.json ]]; then
          PRD_PATH="$1"
        else
          # Append to prompt
          if [[ -n "$PROMPT" ]]; then
            PROMPT="$PROMPT $1"
          else
            PROMPT="$1"
          fi
        fi
        shift
        ;;
    esac
  done
}

# =============================================================================
# Pre-flight Checks
# =============================================================================

preflight_checks() {
  # Check claude is available
  if ! command -v claude &>/dev/null; then
    log_error "Claude CLI not found. Install with: curl -fsSL https://claude.ai/install.sh | bash"
    exit 1
  fi
  log_verbose "Claude CLI available"

  # Check sandbox mode requirements
  if [[ "$SANDBOX" == "true" ]]; then
    if ! command -v docker &>/dev/null; then
      log_error "Docker not found. Install Docker Desktop 4.50+ or remove --sandbox flag."
      exit 1
    fi

    # Verify docker sandbox is available (Docker Desktop 4.50+ feature)
    if ! docker sandbox --help &>/dev/null 2>&1; then
      log_error "docker sandbox not available."
      echo ""
      echo "The --sandbox flag requires Docker Desktop 4.50+ with the sandbox feature."
      echo "See: https://docs.docker.com/desktop/features/sandbox/"
      echo ""
      echo "Options:"
      echo "  1. Update Docker Desktop to 4.50+ and enable sandbox feature"
      echo "  2. Remove --sandbox flag to run directly"
      echo ""
      exit 1
    fi
    log_verbose "Docker sandbox available"
  fi

  # Check jq for streaming
  if [[ "$STREAMING" == "true" ]]; then
    if ! command -v jq &>/dev/null; then
      log_error "jq not found. Required for --stream mode. Install with: brew install jq"
      exit 1
    fi
    log_verbose "jq available for streaming"
  fi

  # Check git
  if ! git rev-parse --git-dir &>/dev/null; then
    log_warning "Not in a git repository. Commits won't work."
  fi
}

# =============================================================================
# Main
# =============================================================================

main() {
  parse_args "$@"

  # Validate we have something to do
  if [[ -z "$PRD_PATH" ]] && [[ -z "$PROMPT" ]]; then
    log_error "No PRD file or prompt provided"
    echo ""
    echo "Usage:"
    echo "  afk-go.sh <prd.json> [OPTIONS]                      # PRD mode"
    echo "  afk-go.sh --prompt \"task\" --promise \"DONE\" [OPTIONS]  # Generic mode"
    echo ""
    echo "Use --help for full usage information"
    exit 1
  fi

  preflight_checks

  START_TIME=$(date +%s)

  if [[ -n "$PRD_PATH" ]]; then
    run_prd_loop
  else
    run_generic_loop
  fi
}

main "$@"
