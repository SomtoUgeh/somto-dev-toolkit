#!/usr/bin/env bash
# sync-sessions-to-qmd.sh - Sync Claude Code sessions to qmd-indexable markdown
#
# Usage:
#   ./sync-sessions-to-qmd.sh [--full]
#   ./sync-sessions-to-qmd.sh --single <session_file> <session_id> <project_path> [--no-embed]
#
# Modes:
#   (default)  Incremental - skip sessions where markdown is newer than source
#   --full     Rebuild all session markdown files
#   --single   Index a single session (used by stop hook)
#
# Options:
#   --no-embed  Skip qmd embed step (used by PreCompact hook to stay under timeout)

set -euo pipefail

OUTPUT_DIR="$HOME/.claude/qmd-sessions"
PROJECTS_DIR="$HOME/.claude/projects"

# Parse arguments
MODE="incremental"
SINGLE_FILE=""
SINGLE_ID=""
SINGLE_PROJECT=""
SKIP_EMBED=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --full)
      MODE="full"
      shift
      ;;
    --single)
      MODE="single"
      SINGLE_FILE="$2"
      SINGLE_ID="$3"
      SINGLE_PROJECT="$4"
      shift 4
      ;;
    --no-embed)
      SKIP_EMBED=true
      shift
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# Extract project name from path (e.g., /Users/somto/code/my-project -> my-project)
get_project_name() {
  basename "$1"
}

# Get numeric mtime in a cross-platform way (Linux/WSL vs macOS BSD stat).
get_mtime() {
  local file="$1"
  local mtime="0"

  # Prefer GNU stat on Linux/WSL; fallback to BSD stat on macOS.
  if mtime=$(stat -c %Y "$file" 2>/dev/null); then
    :
  elif mtime=$(stat -f %m "$file" 2>/dev/null); then
    :
  else
    mtime=0
  fi

  # Guard against non-numeric output (e.g., GNU stat -f filesystem info).
  if [[ ! "$mtime" =~ ^[0-9]+$ ]]; then
    mtime=0
  fi

  printf '%s' "$mtime"
}

# Extract summary from JSONL file (first line with type:summary)
extract_summary() {
  local jsonl_file="$1"
  grep -m1 '"type":"summary"' "$jsonl_file" 2>/dev/null | jq -r '.summary // empty' 2>/dev/null || echo ""
}

# Extract all user prompts from JSONL (the actual questions/requests)
extract_user_prompts() {
  local jsonl_file="$1"
  # Get user messages where content is a string (direct prompts, not tool results)
  # Filter out system reminders, compaction messages, and skill content
  # Use awk to limit lines instead of head (avoids SIGPIPE with pipefail)
  jq -r 'select(.type == "user" and .message.role == "user" and (.message.content | type == "string")) | .message.content' "$jsonl_file" 2>/dev/null | \
    grep -v '^\[' | \
    grep -v '^<' | \
    grep -v '^Base directory for this skill' | \
    grep -v '^#' | \
    grep -v 'This session is being continued' | \
    grep -v '^Analysis:' | \
    awk 'NR<=20'
}

# Extract assistant text responses (explanations, plans, insights)
extract_assistant_insights() {
  local jsonl_file="$1"
  # Get text blocks from assistant messages (not tool_use blocks)
  # Use awk to limit lines instead of head (avoids SIGPIPE with pipefail)
  jq -r '
    select(.type == "assistant" and .message.content) |
    .message.content[] |
    select(.type == "text") |
    .text // empty
  ' "$jsonl_file" 2>/dev/null | \
    grep -v '^\[' | \
    grep -v '^<' | \
    grep -v '^🏁' | \
    awk 'NR<=30 {print substr($0,1,500)}'
}

# Extract thinking blocks (problem analysis, reasoning, plans)
extract_thinking() {
  local jsonl_file="$1"
  # Get thinking blocks - these contain valuable reasoning
  # Use awk to limit instead of head (avoids SIGPIPE with pipefail)
  jq -r '
    select(.type == "assistant" and .message.content) |
    .message.content[] |
    select(.type == "thinking") |
    .thinking // empty
  ' "$jsonl_file" 2>/dev/null | \
    awk 'NR<=50 {print substr($0,1,2000)}'
}

# Extract key actions from JSONL (tool_use entries in message.content)
extract_key_actions() {
  local jsonl_file="$1"

  # Extract file paths from Read/Edit/Write tool uses
  # Tool uses are in message.content array with type:tool_use
  # Use awk to limit instead of head (avoids SIGPIPE with pipefail)
  local file_actions
  file_actions=$(jq -r '
    select(.type == "assistant" and .message.content) |
    .message.content[] |
    select(.type == "tool_use") |
    select(.name == "Read" or .name == "Edit" or .name == "Write") |
    "- \(.name): \(.input.file_path // empty)"
  ' "$jsonl_file" 2>/dev/null | grep -v ': $' | awk 'NR<=10' || echo "")

  # Extract Bash commands (just the command, truncated)
  local bash_cmds
  bash_cmds=$(jq -r '
    select(.type == "assistant" and .message.content) |
    .message.content[] |
    select(.type == "tool_use" and .name == "Bash") |
    .input.command // empty
  ' "$jsonl_file" 2>/dev/null | awk 'NR<=5 {print "- Ran: " substr($0,1,60)}' || echo "")

  # Combine
  printf "%s\n%s" "$file_actions" "$bash_cmds" | grep -v '^$' | awk 'NR<=15'
}

# Generate markdown for a single session
generate_session_markdown() {
  local session_id="$1"
  local full_path="${2:-}"
  [[ -z "$full_path" ]] && return 0
  local first_prompt="$3"
  local message_count="$4"
  local created="$5"
  local modified="$6"
  local git_branch="$7"
  local project_path="$8"

  local project_name
  project_name=$(get_project_name "$project_path")

  # Create project subdirectory
  local project_output_dir="$OUTPUT_DIR/$project_name"
  mkdir -p "$project_output_dir"

  local output_file="$project_output_dir/${session_id}.md"

  # Check if we should skip (incremental mode)
  if [[ "$MODE" == "incremental" && -f "$output_file" && -n "${full_path:-}" ]]; then
    local md_mtime jsonl_mtime
    md_mtime=$(get_mtime "$output_file")
    jsonl_mtime=$(get_mtime "$full_path")
    if [[ "$md_mtime" -gt "$jsonl_mtime" ]]; then
      return 0  # Skip - markdown is newer
    fi
  fi

  # Extract additional context from JSONL
  local summary=""
  local key_actions=""
  local user_prompts=""
  local assistant_insights=""
  local thinking=""
  if [[ -f "$full_path" ]]; then
    summary=$(extract_summary "$full_path")
    key_actions=$(extract_key_actions "$full_path")
    user_prompts=$(extract_user_prompts "$full_path")
    assistant_insights=$(extract_assistant_insights "$full_path")
    thinking=$(extract_thinking "$full_path")
  fi

  # Format date for display
  local created_date
  created_date=$(echo "$created" | cut -dT -f1)

  # Use summary as title if available and meaningful, else first prompt
  local title="$first_prompt"
  if [[ -n "$summary" && ${#summary} -gt 10 ]]; then
    title="$summary"
  fi

  # Generate markdown
  cat > "$output_file" << EOF
---
session_id: $session_id
project_path: $project_path
project_name: $project_name
branch: $git_branch
created: $created
modified: $modified
messages: $message_count
full_path: $full_path
---

# $title

EOF

  # Add first prompt if different from title (for search context)
  if [[ -n "$summary" && ${#summary} -gt 10 && "$first_prompt" != "$summary" ]]; then
    cat >> "$output_file" << EOF
**Initial request:** $first_prompt

EOF
  fi

  # Add project info
  cat >> "$output_file" << EOF
## Project
$project_name (branch: $git_branch)
Created: $created_date | Messages: $message_count

EOF

  # Add key actions if available
  if [[ -n "$key_actions" ]]; then
    cat >> "$output_file" << EOF
## Key Actions
$key_actions

EOF
  fi

  # Add user prompts for richer search context
  if [[ -n "$user_prompts" ]]; then
    cat >> "$output_file" << EOF
## Conversation Highlights
$user_prompts

EOF
  fi

  # Add assistant insights (explanations, solutions)
  if [[ -n "$assistant_insights" ]]; then
    cat >> "$output_file" << EOF
## Key Insights
$assistant_insights

EOF
  fi

  # Add thinking (reasoning, problem analysis, plans)
  if [[ -n "$thinking" ]]; then
    cat >> "$output_file" << EOF
## Problem Analysis
$thinking
EOF
  fi

  echo "  ✓ $project_name/$session_id"
}

# Process a single session (for --single mode)
process_single_session() {
  local project_name
  project_name=$(get_project_name "$SINGLE_PROJECT")

  # Try to find session in index for metadata
  local project_dir_name="-$(echo "$SINGLE_PROJECT" | LC_ALL=C tr '/' '-')"
  local index_file="$PROJECTS_DIR/$project_dir_name/sessions-index.json"

  if [[ -f "$index_file" ]]; then
    local session_data
    session_data=$(jq -r --arg id "$SINGLE_ID" '.entries[] | select(.sessionId == $id)' "$index_file" 2>/dev/null)

    if [[ -n "$session_data" ]]; then
      local first_prompt message_count created modified git_branch
      first_prompt=$(echo "$session_data" | jq -r '.firstPrompt // "No prompt"')
      message_count=$(echo "$session_data" | jq -r '.messageCount // 0')
      created=$(echo "$session_data" | jq -r '.created // ""')
      modified=$(echo "$session_data" | jq -r '.modified // ""')
      git_branch=$(echo "$session_data" | jq -r '.gitBranch // "unknown"')

      generate_session_markdown "$SINGLE_ID" "$SINGLE_FILE" "$first_prompt" \
        "$message_count" "$created" "$modified" "$git_branch" "$SINGLE_PROJECT"

      # Re-embed just this document (if qmd is available and not skipped)
      if [[ "$SKIP_EMBED" == false ]] && command -v qmd &>/dev/null; then
        qmd embed 2>/dev/null || true
      fi
      return 0
    fi
  fi

  # Fallback: generate with minimal metadata
  local summary
  summary=$(extract_summary "$SINGLE_FILE")
  local first_prompt="${summary:-Session $SINGLE_ID}"

  generate_session_markdown "$SINGLE_ID" "$SINGLE_FILE" "$first_prompt" \
    "0" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    "unknown" "$SINGLE_PROJECT"
}

# Process all sessions
process_all_sessions() {
  local total=0
  local processed=0

  echo "Syncing Claude Code sessions to qmd..."
  echo "Mode: $MODE"
  echo ""

  # Find all sessions-index.json files
  for index_file in "$PROJECTS_DIR"/*/sessions-index.json; do
    [[ -f "$index_file" ]] || continue

    local project_dir
    project_dir=$(dirname "$index_file")

    # Process each session in the index
    local entries
    entries=$(jq -c '.entries[]' "$index_file" 2>/dev/null) || continue

    while IFS= read -r entry; do
      [[ -z "$entry" ]] && continue

      local session_id full_path first_prompt message_count created modified git_branch project_path
      session_id=$(echo "$entry" | jq -r '.sessionId')
      full_path=$(echo "$entry" | jq -r '.fullPath')
      first_prompt=$(echo "$entry" | jq -r '.firstPrompt // "No prompt"')
      message_count=$(echo "$entry" | jq -r '.messageCount // 0')
      created=$(echo "$entry" | jq -r '.created // ""')
      modified=$(echo "$entry" | jq -r '.modified // ""')
      git_branch=$(echo "$entry" | jq -r '.gitBranch // "unknown"')
      project_path=$(echo "$entry" | jq -r '.projectPath // ""')

      # Skip if session file doesn't exist
      [[ -f "$full_path" ]] || continue

      ((total++)) || true

      if generate_session_markdown "$session_id" "$full_path" "$first_prompt" \
        "$message_count" "$created" "$modified" "$git_branch" "$project_path"; then
        ((processed++)) || true
      fi
    done <<< "$entries"
  done

  echo ""
  echo "Done: $processed sessions synced"
  echo "Output: $OUTPUT_DIR"
}

# Main
if [[ "$MODE" == "single" ]]; then
  process_single_session
else
  process_all_sessions
fi
