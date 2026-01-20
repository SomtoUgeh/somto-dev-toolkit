#!/usr/bin/env bash
# sync-sessions-to-qmd.sh - Sync Claude Code sessions to qmd-indexable markdown
#
# Usage:
#   ./sync-sessions-to-qmd.sh [--full]
#   ./sync-sessions-to-qmd.sh --single <session_file> <session_id> <project_path>
#
# Modes:
#   (default)  Incremental - skip sessions where markdown is newer than source
#   --full     Rebuild all session markdown files
#   --single   Index a single session (used by stop hook)

set -euo pipefail

OUTPUT_DIR="$HOME/.claude/qmd-sessions"
PROJECTS_DIR="$HOME/.claude/projects"

# Parse arguments
MODE="incremental"
SINGLE_FILE=""
SINGLE_ID=""
SINGLE_PROJECT=""

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

# Extract summary from JSONL file (first line with type:summary)
extract_summary() {
  local jsonl_file="$1"
  grep -m1 '"type":"summary"' "$jsonl_file" 2>/dev/null | jq -r '.summary // empty' 2>/dev/null || echo ""
}

# Extract key actions from JSONL (tool_use entries)
extract_key_actions() {
  local jsonl_file="$1"
  local actions=""

  # Extract Read tool uses
  local reads
  reads=$(grep '"tool_name":"Read"' "$jsonl_file" 2>/dev/null | \
    jq -r '.tool_input.file_path // empty' 2>/dev/null | \
    head -5 | sed 's/^/- Read: /' || echo "")

  # Extract Edit/Write tool uses
  local edits
  edits=$(grep -E '"tool_name":"(Edit|Write)"' "$jsonl_file" 2>/dev/null | \
    jq -r '.tool_input.file_path // empty' 2>/dev/null | \
    head -5 | sed 's/^/- Edited: /' || echo "")

  # Extract Bash commands (first word only for brevity)
  local bash_cmds
  bash_cmds=$(grep '"tool_name":"Bash"' "$jsonl_file" 2>/dev/null | \
    jq -r '.tool_input.command // empty' 2>/dev/null | \
    head -5 | cut -d' ' -f1 | sed 's/^/- Ran: /' || echo "")

  # Combine, remove empty lines, limit total
  printf "%s\n%s\n%s" "$reads" "$edits" "$bash_cmds" | grep -v '^$' | head -10
}

# Generate markdown for a single session
generate_session_markdown() {
  local session_id="$1"
  local full_path="$2"
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
  if [[ "$MODE" == "incremental" && -f "$output_file" ]]; then
    local md_mtime jsonl_mtime
    md_mtime=$(stat -f %m "$output_file" 2>/dev/null || stat -c %Y "$output_file" 2>/dev/null || echo 0)
    jsonl_mtime=$(stat -f %m "$full_path" 2>/dev/null || stat -c %Y "$full_path" 2>/dev/null || echo 0)
    if [[ "$md_mtime" -gt "$jsonl_mtime" ]]; then
      return 0  # Skip - markdown is newer
    fi
  fi

  # Extract additional context from JSONL
  local summary=""
  local key_actions=""
  if [[ -f "$full_path" ]]; then
    summary=$(extract_summary "$full_path")
    key_actions=$(extract_key_actions "$full_path")
  fi

  # Format date for display
  local created_date
  created_date=$(echo "$created" | cut -dT -f1)

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

# $first_prompt

EOF

  # Add summary section if available
  if [[ -n "$summary" ]]; then
    cat >> "$output_file" << EOF
## Session Summary
$summary

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

  echo "  ✓ $project_name/$session_id"
}

# Process a single session (for --single mode)
process_single_session() {
  local project_name
  project_name=$(get_project_name "$SINGLE_PROJECT")

  # Try to find session in index for metadata
  local project_dir_name="-$(echo "$SINGLE_PROJECT" | tr '/' '-')"
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

      # Re-embed just this document (if qmd is available)
      if command -v qmd &>/dev/null; then
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
