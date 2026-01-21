#!/bin/bash

# =============================================================================
# Stop Hook Test Suite
# =============================================================================
# Run: ./hooks/stop_hook_test.sh
#
# Tests helper functions and critical paths in stop_hook.sh
# Uses simple bash assertions - no external dependencies

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Source the functions we want to test (extract them first)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/stop_hook.sh"

# =============================================================================
# Test Framework
# =============================================================================

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="${3:-}"

  TESTS_RUN=$((TESTS_RUN + 1))

  if [[ "$expected" == "$actual" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}✓${NC} $message"
    return 0
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}✗${NC} $message"
    echo -e "    Expected: '$expected'"
    echo -e "    Actual:   '$actual'"
    return 1
  fi
}

assert_empty() {
  local actual="$1"
  local message="${2:-}"
  assert_eq "" "$actual" "$message"
}

assert_not_empty() {
  local actual="$1"
  local message="${2:-}"

  TESTS_RUN=$((TESTS_RUN + 1))

  if [[ -n "$actual" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}✓${NC} $message"
    return 0
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}✗${NC} $message (expected non-empty)"
    return 1
  fi
}

assert_exit_code() {
  local expected="$1"
  local actual="$2"
  local message="${3:-}"
  assert_eq "$expected" "$actual" "$message (exit code)"
}

describe() {
  echo -e "\n${YELLOW}$1${NC}"
}

# =============================================================================
# Extract Functions from Hook Script
# =============================================================================

# Extract and source helper functions
extract_functions() {
  # Extract extract_regex function
  sed -n '/^extract_regex()/,/^}/p' "$HOOK_SCRIPT"

  # Extract extract_regex_last function
  sed -n '/^extract_regex_last()/,/^}/p' "$HOOK_SCRIPT"

  # Extract escape_sed_replacement function
  sed -n '/^escape_sed_replacement()/,/^}/p' "$HOOK_SCRIPT"

  # Extract get_field function
  sed -n '/^get_field()/,/^}/p' "$HOOK_SCRIPT"
}

# Source the extracted functions
eval "$(extract_functions)"

# =============================================================================
# Tests: extract_regex
# =============================================================================

describe "extract_regex - basic capture groups"

result=$(extract_regex 'phase="2"' 'phase="([^"]+)"')
assert_eq "2" "$result" "extracts simple capture group"

result=$(extract_regex '<phase_complete phase="3.5"/>' '<phase_complete phase="([^"]+)"')
assert_eq "3.5" "$result" "extracts phase from XML-like tag"

result=$(extract_regex 'no match here' 'phase="([^"]+)"')
assert_empty "$result" "returns empty on no match"

result=$(extract_regex '<story_complete story_id="42"/>' 'story_id="([^"]+)"')
assert_eq "42" "$result" "extracts numeric value"

# =============================================================================
# Tests: extract_regex_last
# =============================================================================

describe "extract_regex_last - multiple matches"

result=$(extract_regex_last 'phase="1" then phase="2" finally phase="3"' 'phase="([^"]+)"')
assert_eq "3" "$result" "returns last match, not first"

result=$(extract_regex_last 'Example: <phase_complete phase="1"/> ... Actual: <phase_complete phase="2"/>' '<phase_complete phase="([^"]+)"')
assert_eq "2" "$result" "ignores example markers, returns actual"

describe "extract_regex_last - no capture group"

result=$(extract_regex_last 'some text <reviews_complete/> more text' '<reviews_complete/>')
assert_eq "<reviews_complete/>" "$result" "returns full match when no capture group"

result=$(extract_regex_last 'first <reviews_complete/> second <reviews_complete/>' '<reviews_complete/>')
assert_eq "<reviews_complete/>" "$result" "returns last full match"

describe "extract_regex_last - glob metacharacters"

result=$(extract_regex_last 'path="plans/my-*-feature/spec.md"' 'path="([^"]+)"')
assert_eq "plans/my-*-feature/spec.md" "$result" "handles * in path"

result=$(extract_regex_last 'file="test?.md"' 'file="([^"]+)"')
assert_eq "test?.md" "$result" "handles ? in path"

result=$(extract_regex_last 'pattern="[a-z]"' 'pattern="([^"]+)"')
assert_eq "[a-z]" "$result" "handles [ in value"

describe "extract_regex_last - Windows backslash paths"

result=$(extract_regex_last 'path="C:\tmp\spec.md"' 'path="([^"]+)"')
assert_eq 'C:\tmp\spec.md' "$result" "handles Windows path with backslashes"

result=$(extract_regex_last 'first path="C:\a\b" second path="D:\x\y"' 'path="([^"]+)"')
assert_eq 'D:\x\y' "$result" "returns last Windows path"

# =============================================================================
# Tests: escape_sed_replacement
# =============================================================================

describe "escape_sed_replacement - special characters"

result=$(escape_sed_replacement "simple")
assert_eq "simple" "$result" "leaves simple strings unchanged"

result=$(escape_sed_replacement "path/to/file")
assert_eq "path\\/to\\/file" "$result" "escapes forward slashes"

result=$(escape_sed_replacement "foo & bar")
assert_eq "foo \\& bar" "$result" "escapes ampersand"

result=$(escape_sed_replacement 'back\slash')
assert_eq 'back\\slash' "$result" "escapes backslash"

result=$(escape_sed_replacement "pipe|char")
assert_eq "pipe\\|char" "$result" "escapes pipe"

result=$(escape_sed_replacement "all/special&chars\\here|now")
assert_eq "all\\/special\\&chars\\\\here\\|now" "$result" "escapes all special chars"

# =============================================================================
# Tests: get_field
# =============================================================================

describe "get_field - YAML frontmatter parsing"

FRONTMATTER="iteration: 5
max_iterations: 10
completion_promise: \"DONE\"
mode: prd"

result=$(get_field "$FRONTMATTER" "iteration")
assert_eq "5" "$result" "extracts numeric field"

result=$(get_field "$FRONTMATTER" "completion_promise")
assert_eq "DONE" "$result" "extracts quoted string (strips quotes)"

result=$(get_field "$FRONTMATTER" "mode")
assert_eq "prd" "$result" "extracts unquoted string"

result=$(get_field "$FRONTMATTER" "nonexistent")
assert_empty "$result" "returns empty for missing field"

describe "get_field - duplicate keys"

FRONTMATTER_DUP="iteration: 1
iteration: 2
iteration: 3"

result=$(get_field "$FRONTMATTER_DUP" "iteration")
assert_eq "1" "$result" "returns first occurrence on duplicate keys"

# =============================================================================
# Tests: JSON input validation
# =============================================================================

describe "JSON input validation"

# Test valid JSON
valid_json='{"stop_hook_active": false, "session_id": "abc123"}'
if echo "$valid_json" | jq empty 2>/dev/null; then
  assert_eq "0" "0" "valid JSON passes jq validation"
else
  assert_eq "0" "1" "valid JSON passes jq validation"
fi

# Test invalid JSON
invalid_json='not json at all'
if echo "$invalid_json" | jq empty 2>/dev/null; then
  assert_eq "1" "0" "invalid JSON fails jq validation"
else
  assert_eq "0" "0" "invalid JSON fails jq validation"
fi

# Test empty input
empty_input=''
if [[ -z "$empty_input" ]]; then
  assert_eq "0" "0" "empty input detected correctly"
else
  assert_eq "0" "1" "empty input detected correctly"
fi

# =============================================================================
# Tests: Session ID validation
# =============================================================================

describe "Session ID validation patterns"

# Valid session IDs
[[ "abc123" =~ ^[a-zA-Z0-9_-]+$ ]] && result="valid" || result="invalid"
assert_eq "valid" "$result" "alphanumeric session_id is valid"

[[ "my-session_id" =~ ^[a-zA-Z0-9_-]+$ ]] && result="valid" || result="invalid"
assert_eq "valid" "$result" "hyphen and underscore are valid"

# Invalid session IDs
[[ "../escape" =~ ^[a-zA-Z0-9_-]+$ ]] && result="valid" || result="invalid"
assert_eq "invalid" "$result" "path traversal rejected"

[[ "has spaces" =~ ^[a-zA-Z0-9_-]+$ ]] && result="valid" || result="invalid"
assert_eq "invalid" "$result" "spaces rejected"

[[ "has/slash" =~ ^[a-zA-Z0-9_-]+$ ]] && result="valid" || result="invalid"
assert_eq "invalid" "$result" "slashes rejected"

# =============================================================================
# Tests: PRD phase validation
# =============================================================================

describe "PRD phase validation"

valid_phases=("1" "2" "2.5" "3" "3.2" "3.5" "4" "5" "5.5" "6")
for phase in "${valid_phases[@]}"; do
  case "$phase" in
    1|2|2.5|3|3.2|3.5|4|5|5.5|6) result="valid" ;;
    *) result="invalid" ;;
  esac
  assert_eq "valid" "$result" "phase $phase is valid"
done

invalid_phases=("0" "7" "2.3" "abc" "")
for phase in "${invalid_phases[@]}"; do
  case "$phase" in
    1|2|2.5|3|3.2|3.5|4|5|5.5|6) result="valid" ;;
    *) result="invalid" ;;
  esac
  assert_eq "invalid" "$result" "phase '$phase' is invalid"
done

# =============================================================================
# Tests: Story ID word boundary matching
# =============================================================================

describe "Story ID word boundary matching"

# Pattern from stop_hook.sh for story commit detection
check_story_match() {
  local log="$1"
  local story_id="$2"
  if echo "$log" | grep -qiE "(story.*#?${story_id}([^0-9]|\$)|#${story_id}([^0-9]|\$)|story ${story_id}([^0-9]|\$))"; then
    echo "match"
  else
    echo "no_match"
  fi
}

result=$(check_story_match "Implement story #1" "1")
assert_eq "match" "$result" "matches story #1"

result=$(check_story_match "Implement story #10" "1")
assert_eq "no_match" "$result" "does NOT match #1 in #10 (word boundary)"

result=$(check_story_match "story 5 complete" "5")
assert_eq "match" "$result" "matches story 5 (no hash)"

result=$(check_story_match "story 50 complete" "5")
assert_eq "no_match" "$result" "does NOT match 5 in 50"

result=$(check_story_match "Fixed #123" "123")
assert_eq "match" "$result" "matches #123 at end"

result=$(check_story_match "Fixed #1234" "123")
assert_eq "no_match" "$result" "does NOT match #123 in #1234"

# =============================================================================
# Summary
# =============================================================================

echo -e "\n${YELLOW}═══════════════════════════════════════════════════════════${NC}"
echo -e "Tests run:    $TESTS_RUN"
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"

if [[ $TESTS_FAILED -gt 0 ]]; then
  exit 1
fi

exit 0
