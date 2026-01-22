#!/bin/bash
# =============================================================================
# Shared Loop Helpers
# =============================================================================
# Portable functions used by both setup scripts and stop_hook.sh
# Source this file: source "${BASH_SOURCE%/*}/lib/loop-helpers.sh"
# =============================================================================

# Escape special characters for sed replacement string
# Escapes: / & \ | newlines (prevents injection when variable contains these)
# Usage: ESCAPED=$(escape_sed_replacement "$UNSAFE_VALUE")
escape_sed_replacement() {
  local str="$1"
  str="${str//\\/\\\\}"
  str="${str//\//\\/}"
  str="${str//&/\\&}"
  str="${str//|/\\|}"
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

# Write state file atomically (write to temp, then move)
# Uses printf to handle multiline content safely
write_state_file() {
  local state_file="$1"
  local content="$2"
  local temp_file="${state_file}.tmp.$$"
  printf '%s\n' "$content" > "$temp_file"
  mv "$temp_file" "$state_file"
}

# Update a single field in state file frontmatter
# Usage: update_state_field "$STATE_FILE" "iteration" "5"
update_state_field() {
  local state_file="$1"
  local field="$2"
  local value="$3"
  local escaped_value
  escaped_value=$(escape_sed_replacement "$value")
  sed_inplace "s/^${field}: .*/${field}: ${escaped_value}/" "$state_file"
}

# Send desktop notification (cross-platform, non-blocking)
# Usage: notify "Title" "Message"
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
      powershell.exe -Command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show('$message', '$title')" </dev/null >/dev/null 2>&1 &
      ;;
  esac
}

# Get field from YAML frontmatter
# Usage: VALUE=$(get_frontmatter_field "$FRONTMATTER" "field_name")
get_frontmatter_field() {
  local frontmatter="$1"
  local field="$2"
  echo "$frontmatter" | grep "^${field}:" | head -1 | sed "s/${field}: *//" | LC_ALL=C tr -d '"' || true
}

# Parse frontmatter from state file (returns content between first two ---)
# Usage: FRONTMATTER=$(parse_frontmatter "$STATE_FILE") || handle_error
parse_frontmatter() {
  local file="$1"
  local delimiters
  delimiters=$(grep -n '^---$' "$file" 2>/dev/null | head -2 | cut -d: -f1 || true)

  if [[ -z "$delimiters" ]]; then
    echo "Error: No frontmatter delimiters found in $file" >&2
    return 1
  fi

  local first_delim second_delim
  first_delim=$(echo "$delimiters" | head -1)
  second_delim=$(echo "$delimiters" | tail -1)

  if [[ "$first_delim" != "1" ]] || [[ -z "$second_delim" ]] || [[ "$first_delim" == "$second_delim" ]]; then
    echo "Error: Invalid frontmatter format in $file" >&2
    return 1
  fi

  sed -n "2,$((second_delim - 1))p" "$file"
}

# Detect main branch name (main or master)
# Usage: MAIN_BRANCH=$(detect_main_branch)
detect_main_branch() {
  git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "main"
}

# Check if on main/master branch
# Usage: if is_on_main_branch; then prompt_for_feature_branch; fi
is_on_main_branch() {
  local current_branch main_branch
  current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  main_branch=$(detect_main_branch)
  [[ "$current_branch" == "$main_branch" ]] || [[ "$current_branch" == "main" ]] || [[ "$current_branch" == "master" ]]
}

# Prompt user to create feature branch (used by setup scripts)
# Returns: sets WORKING_BRANCH variable
# Usage: prompt_feature_branch "feat/my-feature"
prompt_feature_branch() {
  local suggested_branch="$1"
  local current_branch main_branch
  current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  main_branch=$(detect_main_branch)

  WORKING_BRANCH="$current_branch"

  if ! is_on_main_branch; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    # Non-interactive stdin: auto-create suggested branch if possible.
    local branch_name="$suggested_branch"
    if git show-ref --verify --quiet "refs/heads/$branch_name"; then
      if git checkout "$branch_name" 2>/dev/null; then
        WORKING_BRANCH="$branch_name"
      fi
    elif git checkout -b "$branch_name" 2>/dev/null; then
      WORKING_BRANCH="$branch_name"
    fi
    return 0
  fi

  echo ""
  echo "You're on '$current_branch'. Create a feature branch?"
  echo "  1) Yes, from $main_branch (recommended)"
  echo "  2) No, work on $current_branch"
  echo ""
  if ! read -r -p "Choice [1/2]: " BRANCH_CHOICE; then
    return 0
  fi

  if [[ "$BRANCH_CHOICE" == "1" ]]; then
    if ! read -r -p "Branch name [$suggested_branch]: " CUSTOM_BRANCH; then
      CUSTOM_BRANCH=""
    fi
    local branch_name="${CUSTOM_BRANCH:-$suggested_branch}"

    if git checkout -b "$branch_name" 2>/dev/null; then
      WORKING_BRANCH="$branch_name"
      echo "✓ Created and switched to branch: $branch_name"
    else
      echo "⚠️  Failed to create branch '$branch_name' - continuing on $current_branch"
    fi
  fi
}
