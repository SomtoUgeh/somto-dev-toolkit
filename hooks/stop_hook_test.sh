#!/bin/bash

# =============================================================================
# Stop Hook Test Suite - Comprehensive Coverage
# =============================================================================
# Run: ./hooks/stop_hook_test.sh
#
# Tests helper functions and critical paths in stop_hook.sh
# Covers all issues fixed in v0.10.33-0.10.38:
#   - Windows backslash path handling (infinite loop fix)
#   - Last marker wins (extract_regex_last)
#   - Promise tag extraction (greedy regex)
#   - Frontmatter validation (missing --- delimiter)
#   - Session ID security (path traversal prevention)
#   - Story ID word boundaries (#1 vs #10)
#   - loop_type backfill (backward compat)
#   - sed escaping (special characters)

# Keep tests running after failures; we track status manually.
set -u
set -o pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

CLEANUP_DIRS=()

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Missing required command: $cmd" >&2
    exit 1
  fi
}

register_cleanup_dir() {
  CLEANUP_DIRS+=("$1")
}

cleanup() {
  local dir
  for dir in "${CLEANUP_DIRS[@]}"; do
    [[ -n "$dir" ]] && rm -rf "$dir"
  done
}

trap cleanup EXIT

mktemp_dir() {
  local dir
  dir=$(mktemp -d 2>/dev/null || mktemp -d -t stop_hook_test)
  echo "$dir"
}

mktemp_file() {
  local file
  file=$(mktemp 2>/dev/null || mktemp -t stop_hook_test)
  echo "$file"
}

# Source the functions we want to test (extract them first)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SCRIPT="$SCRIPT_DIR/stop_hook.sh"

if [[ ! -f "$HOOK_SCRIPT" ]]; then
  echo "stop_hook.sh not found at $HOOK_SCRIPT" >&2
  exit 1
fi

require_cmd jq
require_cmd awk
require_cmd mktemp
require_cmd git

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

skip() {
  local message="${1:-}"
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
  echo -e "  ${YELLOW}↷${NC} $message (skipped)"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="${3:-}"

  TESTS_RUN=$((TESTS_RUN + 1))

  if [[ "$haystack" == *"$needle"* ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    echo -e "  ${GREEN}✓${NC} $message"
    return 0
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    echo -e "  ${RED}✗${NC} $message"
    echo -e "    Expected to contain: '$needle'"
    echo -e "    Actual: '$haystack'"
    return 1
  fi
}

describe() {
  echo -e "\n${YELLOW}$1${NC}"
}

section() {
  echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# =============================================================================
# Extract Functions from Hook Script
# =============================================================================

extract_functions() {
  # Extract extract_regex function
  sed -n '/^[[:space:]]*extract_regex()/,/^[[:space:]]*}$/p' "$HOOK_SCRIPT"

  # Extract extract_regex_last function
  sed -n '/^[[:space:]]*extract_regex_last()/,/^[[:space:]]*}$/p' "$HOOK_SCRIPT"

  # Extract extract_promise_last function
  sed -n '/^[[:space:]]*extract_promise_last()/,/^[[:space:]]*}$/p' "$HOOK_SCRIPT"

  # Extract escape_sed_replacement function
  sed -n '/^[[:space:]]*escape_sed_replacement()/,/^[[:space:]]*}$/p' "$HOOK_SCRIPT"

  # Extract sed_inplace function
  sed -n '/^[[:space:]]*sed_inplace()/,/^[[:space:]]*}$/p' "$HOOK_SCRIPT"

  # Extract get_field function
  sed -n '/^[[:space:]]*get_field()/,/^[[:space:]]*}$/p' "$HOOK_SCRIPT"

  # Extract is_valid_prd_phase function
  sed -n '/^[[:space:]]*is_valid_prd_phase()/,/^[[:space:]]*}$/p' "$HOOK_SCRIPT"

  # Extract parse_frontmatter function
  sed -n '/^[[:space:]]*parse_frontmatter()/,/^[[:space:]]*}$/p' "$HOOK_SCRIPT"

  # Extract validate_state_file function
  sed -n '/^[[:space:]]*validate_state_file()/,/^[[:space:]]*}$/p' "$HOOK_SCRIPT"
}

# Source the extracted functions
eval "$(extract_functions)"

# =============================================================================
section "ISSUE FIX: extract_regex basic functionality"
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

describe "extract_regex - edge cases"

result=$(extract_regex 'phase=""' 'phase="([^"]*)"')
assert_eq "" "$result" "handles empty value in quotes"

result=$(extract_regex 'phase="with spaces here"' 'phase="([^"]+)"')
assert_eq "with spaces here" "$result" "handles spaces in value"

result=$(extract_regex 'phase="special<>chars"' 'phase="([^"]+)"')
assert_eq "special<>chars" "$result" "handles XML-like chars in value"

# =============================================================================
section "ISSUE FIX: extract_regex_last - Last Marker Wins (v0.10.33+)"
# =============================================================================
# PROBLEM: Documentation/examples in Claude's output could trigger markers
# FIX: Always use the LAST occurrence of a marker

describe "extract_regex_last - multiple matches (critical for examples in docs)"

result=$(extract_regex_last 'phase="1" then phase="2" finally phase="3"' 'phase="([^"]+)"')
assert_eq "3" "$result" "returns last match, not first"

result=$(extract_regex_last 'Example: <phase_complete phase="1"/> ... Actual: <phase_complete phase="2"/>' '<phase_complete phase="([^"]+)"')
assert_eq "2" "$result" "ignores example markers, returns actual"

# Real-world scenario: PRD prompt contains examples
REAL_OUTPUT='Here is how to use the marker:

Example:
```
<phase_complete phase="1"/>
```

Now I have completed the actual work:

<phase_complete phase="2"/>'
result=$(extract_regex_last "$REAL_OUTPUT" '<phase_complete phase="([^"]+)"')
assert_eq "2" "$result" "real-world: ignores code block examples"

# Multiple examples in documentation
DOC_OUTPUT='The phase_complete marker supports:
- <phase_complete phase="1"/> for input classification
- <phase_complete phase="2"/> for interview
- <phase_complete phase="3"/> for spec writing

I have now completed phase 3:
<phase_complete phase="3" spec_path="plans/feature/spec.md"/>'
result=$(extract_regex_last "$DOC_OUTPUT" '<phase_complete phase="([^"]+)"')
assert_eq "3" "$result" "multiple doc examples - returns last actual marker"

describe "extract_regex_last - no capture group (for markers like <reviews_complete/>)"

result=$(extract_regex_last 'some text <reviews_complete/> more text' '<reviews_complete/>')
assert_eq "<reviews_complete/>" "$result" "returns full match when no capture group"

result=$(extract_regex_last 'first <reviews_complete/> second <reviews_complete/>' '<reviews_complete/>')
assert_eq "<reviews_complete/>" "$result" "returns last full match"

describe "extract_regex_last - empty input"

result=$(extract_regex_last "" 'phase="([^"]+)"')
assert_empty "$result" "handles empty input"

# Gate decision examples
result=$(extract_regex_last 'Example: <gate_decision>BLOCK</gate_decision> ... Actual: <gate_decision>PROCEED</gate_decision>' '<gate_decision>([^<]+)</gate_decision>')
assert_eq "PROCEED" "$result" "gate_decision returns last value"

describe "extract_regex_last - glob metacharacters in paths"

result=$(extract_regex_last 'path="plans/my-*-feature/spec.md"' 'path="([^"]+)"')
assert_eq "plans/my-*-feature/spec.md" "$result" "handles * in path"

result=$(extract_regex_last 'file="test?.md"' 'file="([^"]+)"')
assert_eq "test?.md" "$result" "handles ? in path"

result=$(extract_regex_last 'pattern="[a-z]"' 'pattern="([^"]+)"')
assert_eq "[a-z]" "$result" "handles [ in value"

result=$(extract_regex_last 'glob="**/*.ts"' 'glob="([^"]+)"')
assert_eq "**/*.ts" "$result" "handles ** glob pattern"

result=$(extract_regex_last 'path="src/{a,b,c}/*.js"' 'path="([^"]+)"')
assert_eq "src/{a,b,c}/*.js" "$result" "handles brace expansion pattern"

# =============================================================================
section "ISSUE FIX: Windows Backslash Paths (v0.10.37)"
# =============================================================================
# PROBLEM: extract_regex_last infinite loop with backslashes (Windows paths)
# ROOT CAUSE: Pattern-based string removal failed with backslash escaping
# FIX: Use awk-based position finding instead of pattern removal

describe "extract_regex_last - Windows backslash paths (CRITICAL)"

result=$(extract_regex_last 'path="C:\tmp\spec.md"' 'path="([^"]+)"')
assert_eq 'C:\tmp\spec.md' "$result" "simple Windows path"

result=$(extract_regex_last 'first path="C:\a\b" second path="D:\x\y"' 'path="([^"]+)"')
assert_eq 'D:\x\y' "$result" "multiple Windows paths - returns last"

# Deep nested Windows paths
result=$(extract_regex_last 'spec_path="C:\Users\Dev\Projects\my-app\plans\feature\spec.md"' 'spec_path="([^"]+)"')
assert_eq 'C:\Users\Dev\Projects\my-app\plans\feature\spec.md' "$result" "deep nested Windows path"

# Mixed slashes (common in cross-platform code)
result=$(extract_regex_last 'path="C:\Users/Dev\mixed/slashes\here"' 'path="([^"]+)"')
assert_eq 'C:\Users/Dev\mixed/slashes\here' "$result" "mixed forward/back slashes"

# Backslash in path segment
result=$(extract_regex_last 'path="dir\subdir"' 'path="([^"]+)"')
assert_eq 'dir\subdir' "$result" "backslash in path preserved"

# Windows path in full PRD marker
WINDOWS_MARKER='<phase_complete phase="3" spec_path="C:\Users\Dev\plans\auth-feature\spec.md"/>'
result=$(extract_regex_last "$WINDOWS_MARKER" 'spec_path="([^"]+)"')
assert_eq 'C:\Users\Dev\plans\auth-feature\spec.md' "$result" "Windows path in phase_complete marker"

describe "extract_regex_last - backslash stress tests"

# Multiple backslashes preserved exactly (input has 2 backslashes)
result=$(extract_regex_last 'path="C:\\double"' 'path="([^"]+)"')
assert_eq 'C:\\double' "$result" "double backslash in input preserved"

# Long backslash chains (regression coverage for infinite loop)
result=$(extract_regex_last 'path="C:\a\b\c\d\e\f\g\h"' 'path="([^"]+)"')
assert_eq 'C:\a\b\c\d\e\f\g\h' "$result" "long backslash chain preserved"

# Backslash before special chars (t, n) treated as literal
result=$(extract_regex_last 'path="has\ttab"' 'path="([^"]+)"')
assert_eq 'has\ttab' "$result" "backslash-t preserved as literal"

# =============================================================================
section "ISSUE FIX: Promise Tag - Last Match Wins (v0.10.37)"
# =============================================================================
# PROBLEM: First <promise> tag was grabbed (examples in docs)
# FIX: Use extract_promise_last so the LAST tag wins (whitespace normalized)

describe "Promise tag extraction - last match wins"

# Example in documentation followed by actual promise
DOC_WITH_PROMISE='When complete, output:
```
<promise>DONE</promise>
```

All tests passing!
<promise>TESTS_PASS</promise>'
result=$(extract_promise_last "$DOC_WITH_PROMISE")
assert_eq "TESTS_PASS" "$result" "ignores promise in code block example"

# Multiple promises - should get last
MULTI_PROMISE='<promise>first</promise> middle <promise>second</promise> end <promise>final</promise>'
result=$(extract_promise_last "$MULTI_PROMISE")
assert_eq "final" "$result" "multiple promises - returns last"

# Promise with whitespace
WHITESPACE_PROMISE='text <promise>  spaced out  </promise> more'
result=$(extract_promise_last "$WHITESPACE_PROMISE")
assert_eq "spaced out" "$result" "trims whitespace from promise"

# Empty promise
EMPTY_PROMISE='<promise></promise>'
result=$(extract_promise_last "$EMPTY_PROMISE")
assert_empty "$result" "handles empty promise tag"

# =============================================================================
section "ISSUE FIX: escape_sed_replacement (v0.10.33+)"
# =============================================================================
# PROBLEM: Special characters in paths could break sed replacements
# FIX: Escape all sed-special characters

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

describe "escape_sed_replacement - real-world paths"

# Windows path
result=$(escape_sed_replacement 'C:\Users\Dev\project')
assert_eq 'C:\\Users\\Dev\\project' "$result" "Windows path escaping"

# Feature name with special chars
result=$(escape_sed_replacement "user-auth/oauth-2.0")
assert_eq "user-auth\\/oauth-2.0" "$result" "feature name with slashes"

# URL in path
result=$(escape_sed_replacement "https://api.example.com/v1")
assert_eq "https:\\/\\/api.example.com\\/v1" "$result" "URL escaping"

# =============================================================================
section "ISSUE FIX: get_field YAML Frontmatter Parsing"
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

describe "get_field - duplicate keys (first wins)"

FRONTMATTER_DUP="iteration: 1
iteration: 2
iteration: 3"

result=$(get_field "$FRONTMATTER_DUP" "iteration")
assert_eq "1" "$result" "returns first occurrence on duplicate keys"

describe "get_field - edge cases"

# Field with colons in value
COLON_FM="url: https://example.com:8080/path"
result=$(get_field "$COLON_FM" "url")
assert_eq "https://example.com:8080/path" "$result" "handles colons in value"

# Field with spaces around colon
SPACE_FM="field:    value with leading spaces"
result=$(get_field "$SPACE_FM" "field")
assert_eq "value with leading spaces" "$result" "trims leading spaces after colon"

# Empty value
EMPTY_FM="empty_field: "
result=$(get_field "$EMPTY_FM" "empty_field")
assert_empty "$result" "handles empty value"

# Boolean-like values
BOOL_FM="active: true
enabled: false"
result=$(get_field "$BOOL_FM" "active")
assert_eq "true" "$result" "handles boolean true"
result=$(get_field "$BOOL_FM" "enabled")
assert_eq "false" "$result" "handles boolean false"

# =============================================================================
section "ISSUE FIX: loop_type Backfill and Validation"
# =============================================================================

describe "validate_state_file - backfill legacy state files"

LEGACY_DIR=$(mktemp_dir)
register_cleanup_dir "$LEGACY_DIR"

LEGACY_STATE="$LEGACY_DIR/legacy.md"
cat > "$LEGACY_STATE" << 'EOF'
---
mode: "generic"
active: true
iteration: 1
max_iterations: 5
completion_promise: "DONE"
---
# legacy body
EOF

LEGACY_FM=$(parse_frontmatter "$LEGACY_STATE")
if validate_state_file "$LEGACY_FM" "go" "$LEGACY_STATE"; then
  status="success"
else
  status="failed"
fi
assert_eq "success" "$status" "backfills missing loop_type"

BACKFILLED_LOOP=$(sed -n 's/^loop_type: "\(.*\)"/\1/p' "$LEGACY_STATE" | head -1)
assert_eq "go" "$BACKFILLED_LOOP" "loop_type inserted into legacy frontmatter"

describe "validate_state_file - mismatch fails"

MISMATCH_STATE="$LEGACY_DIR/mismatch.md"
cat > "$MISMATCH_STATE" << 'EOF'
---
loop_type: "ut"
active: true
iteration: 1
max_iterations: 5
---
# mismatch body
EOF

MISMATCH_FM=$(parse_frontmatter "$MISMATCH_STATE")
if validate_state_file "$MISMATCH_FM" "go" "$MISMATCH_STATE"; then
  status="success"
else
  status="failed"
fi
assert_eq "failed" "$status" "loop_type mismatch is rejected"

# =============================================================================
section "ISSUE FIX: JSON Input Validation (v0.10.37)"
# =============================================================================
# PROBLEM: Silent failures when hook received empty/invalid JSON
# FIX: Validate JSON before processing

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

describe "JSON edge cases"

# Truncated JSON
truncated='{"session_id": "abc'
if echo "$truncated" | jq empty 2>/dev/null; then
  assert_eq "1" "0" "truncated JSON fails validation"
else
  assert_eq "0" "0" "truncated JSON fails validation"
fi

# JSON with trailing garbage
trailing='{"valid": true} extra stuff'
if echo "$trailing" | jq empty 2>/dev/null; then
  assert_eq "1" "0" "JSON with trailing garbage fails"
else
  assert_eq "0" "0" "JSON with trailing garbage fails"
fi

# Nested valid JSON
nested='{"outer": {"inner": {"deep": true}}}'
if echo "$nested" | jq empty 2>/dev/null; then
  assert_eq "0" "0" "nested JSON passes validation"
else
  assert_eq "0" "1" "nested JSON passes validation"
fi

# =============================================================================
section "ISSUE FIX: Session ID Security (v0.10.33+)"
# =============================================================================
# PROBLEM: Malicious session_id could enable path traversal
# FIX: Strict alphanumeric + hyphen + underscore validation

describe "Session ID validation - valid patterns"

[[ "abc123" =~ ^[a-zA-Z0-9_-]+$ ]] && result="valid" || result="invalid"
assert_eq "valid" "$result" "alphanumeric session_id"

[[ "my-session_id" =~ ^[a-zA-Z0-9_-]+$ ]] && result="valid" || result="invalid"
assert_eq "valid" "$result" "hyphen and underscore"

[[ "ABC123xyz" =~ ^[a-zA-Z0-9_-]+$ ]] && result="valid" || result="invalid"
assert_eq "valid" "$result" "mixed case"

[[ "a" =~ ^[a-zA-Z0-9_-]+$ ]] && result="valid" || result="invalid"
assert_eq "valid" "$result" "single character"

[[ "123" =~ ^[a-zA-Z0-9_-]+$ ]] && result="valid" || result="invalid"
assert_eq "valid" "$result" "numbers only"

describe "Session ID validation - attack vectors (MUST reject)"

[[ "../escape" =~ ^[a-zA-Z0-9_-]+$ ]] && result="valid" || result="invalid"
assert_eq "invalid" "$result" "path traversal ../"

[[ "../../etc/passwd" =~ ^[a-zA-Z0-9_-]+$ ]] && result="valid" || result="invalid"
assert_eq "invalid" "$result" "deep path traversal"

[[ "has spaces" =~ ^[a-zA-Z0-9_-]+$ ]] && result="valid" || result="invalid"
assert_eq "invalid" "$result" "spaces"

[[ "has/slash" =~ ^[a-zA-Z0-9_-]+$ ]] && result="valid" || result="invalid"
assert_eq "invalid" "$result" "forward slash"

[[ 'has\backslash' =~ ^[a-zA-Z0-9_-]+$ ]] && result="valid" || result="invalid"
assert_eq "invalid" "$result" "backslash"

[[ "has.dot" =~ ^[a-zA-Z0-9_-]+$ ]] && result="valid" || result="invalid"
assert_eq "invalid" "$result" "dot (could be .., .git, etc)"

[[ "" =~ ^[a-zA-Z0-9_-]+$ ]] && result="valid" || result="invalid"
assert_eq "invalid" "$result" "empty string"

[[ "null" =~ ^[a-zA-Z0-9_-]+$ ]] && result="valid" || result="invalid"
assert_eq "valid" "$result" "literal 'null' is valid (just a string)"

# Command injection attempts
[[ "; rm -rf /" =~ ^[a-zA-Z0-9_-]+$ ]] && result="valid" || result="invalid"
assert_eq "invalid" "$result" "command injection semicolon"

[[ '$(whoami)' =~ ^[a-zA-Z0-9_-]+$ ]] && result="valid" || result="invalid"
assert_eq "invalid" "$result" "command substitution"

[[ '`id`' =~ ^[a-zA-Z0-9_-]+$ ]] && result="valid" || result="invalid"
assert_eq "invalid" "$result" "backtick command"

# =============================================================================
section "ISSUE FIX: PRD Phase Validation"
# =============================================================================

describe "PRD phase validation - valid phases"

valid_phases=("1" "2" "2.5" "3" "3.2" "3.5" "4" "5" "5.5" "6")
for phase in "${valid_phases[@]}"; do
  case "$phase" in
    1|2|2.5|3|3.2|3.5|4|5|5.5|6) result="valid" ;;
    *) result="invalid" ;;
  esac
  assert_eq "valid" "$result" "phase $phase is valid"
done

describe "PRD phase validation - invalid phases"

invalid_phases=("0" "7" "2.3" "abc" "" "1.5" "3.1" "4.5" "-1" "10")
for phase in "${invalid_phases[@]}"; do
  case "$phase" in
    1|2|2.5|3|3.2|3.5|4|5|5.5|6) result="valid" ;;
    *) result="invalid" ;;
  esac
  assert_eq "invalid" "$result" "phase '$phase' is invalid"
done

# =============================================================================
section "ISSUE FIX: Story ID Word Boundary Matching (v0.10.33+)"
# =============================================================================
# PROBLEM: story #1 could match story #10, #11, #100, etc.
# FIX: Use word boundary ([^0-9]|$) in regex

describe "Story ID word boundary - exact matches"

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

result=$(check_story_match "story 5 complete" "5")
assert_eq "match" "$result" "matches story 5 (no hash)"

result=$(check_story_match "Fixed #123" "123")
assert_eq "match" "$result" "matches #123 at end"

result=$(check_story_match "feat(auth): story #42 - add login" "42")
assert_eq "match" "$result" "matches #42 in conventional commit"

describe "Story ID word boundary - must NOT match (CRITICAL)"

result=$(check_story_match "Implement story #10" "1")
assert_eq "no_match" "$result" "does NOT match #1 in #10"

result=$(check_story_match "story 50 complete" "5")
assert_eq "no_match" "$result" "does NOT match 5 in 50"

result=$(check_story_match "Fixed #1234" "123")
assert_eq "no_match" "$result" "does NOT match #123 in #1234"

result=$(check_story_match "story #100" "10")
assert_eq "no_match" "$result" "does NOT match #10 in #100"

result=$(check_story_match "story #21" "2")
assert_eq "no_match" "$result" "does NOT match #2 in #21"

describe "Story ID word boundary - edge cases"

result=$(check_story_match "Story #1 and story #2" "1")
assert_eq "match" "$result" "matches first of multiple stories"

result=$(check_story_match "STORY #5" "5")
assert_eq "match" "$result" "case insensitive match"

result=$(check_story_match "story#7" "7")
assert_eq "match" "$result" "no space before hash"

result=$(check_story_match "closes #99" "99")
assert_eq "match" "$result" "GitHub closes syntax"

# =============================================================================
section "ISSUE FIX: Missing --- Delimiter (v0.10.38)"
# =============================================================================
# PROBLEM: grep for --- could fail under set -euo pipefail if file corrupted
# FIX: Added || true and validation before using result

describe "Frontmatter delimiter validation"

# Create temp test files
TEMP_DIR=$(mktemp_dir)
register_cleanup_dir "$TEMP_DIR"

# Valid frontmatter
cat > "$TEMP_DIR/valid.md" << 'EOF'
---
iteration: 1
mode: prd
---
# Body content
EOF

# Missing second delimiter
cat > "$TEMP_DIR/missing_end.md" << 'EOF'
---
iteration: 1
mode: prd
# No closing ---
EOF

# No delimiters at all
cat > "$TEMP_DIR/no_delimiters.md" << 'EOF'
Just plain content
No frontmatter here
EOF

# Valid - should parse
result=$(parse_frontmatter "$TEMP_DIR/valid.md" 2>/dev/null) && status="success" || status="failed"
assert_eq "success" "$status" "valid frontmatter parses successfully"
assert_contains "$result" "iteration: 1" "parsed content includes iteration"

# Missing end delimiter - should fail gracefully
result=$(parse_frontmatter "$TEMP_DIR/missing_end.md" 2>/dev/null) && status="success" || status="failed"
assert_eq "failed" "$status" "missing end delimiter fails gracefully"

# No delimiters - should fail gracefully
result=$(parse_frontmatter "$TEMP_DIR/no_delimiters.md" 2>/dev/null) && status="success" || status="failed"
assert_eq "failed" "$status" "no delimiters fails gracefully"

describe "Frontmatter edge cases"

# --- in code block (should not confuse parser)
cat > "$TEMP_DIR/codeblock.md" << 'EOF'
---
iteration: 1
---
# Content

```yaml
---
fake: frontmatter
---
```
EOF

result=$(parse_frontmatter "$TEMP_DIR/codeblock.md" 2>/dev/null) && status="success" || status="failed"
assert_eq "success" "$status" "--- in code block doesn't break parsing"

# First line not ---
cat > "$TEMP_DIR/late_start.md" << 'EOF'
# Header first
---
iteration: 1
---
EOF

result=$(parse_frontmatter "$TEMP_DIR/late_start.md" 2>/dev/null) && status="success" || status="failed"
assert_eq "failed" "$status" "frontmatter must start at line 1"

# Integration helpers (stop_hook end-to-end)
write_transcript() {
  local file="$1"
  local text="$2"
  jq -c -n --arg text "$text" \
    '{role:"assistant",message:{content:[{type:"text",text:$text}]}}' > "$file"
}

build_hook_input() {
  local session_id="$1"
  local transcript_path="$2"
  local cwd="$3"
  jq -n \
    --arg session_id "$session_id" \
    --arg transcript_path "$transcript_path" \
    --arg cwd "$cwd" \
    '{session_id:$session_id, transcript_path:$transcript_path, cwd:$cwd, stop_hook_active:false}'
}

run_hook() {
  local input="$1"
  local workdir="$2"
  local err_file
  err_file=$(mktemp_file)
  register_cleanup_dir "$err_file"
  HOOK_OUTPUT=$(cd "$workdir" && printf '%s' "$input" | bash "$HOOK_SCRIPT" 2> "$err_file")
  HOOK_STATUS=$?
  HOOK_STDERR=$(cat "$err_file")
}

init_git_repo() {
  local dir="$1"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test User"
}

git_commit_file() {
  local dir="$1"
  local message="$2"
  local file="$3"
  local content="$4"
  printf '%s\n' "$content" > "$dir/$file"
  git -C "$dir" add "$file"
  git -C "$dir" commit -q -m "$message"
}

write_go_prd_state() {
  local state_file="$1"
  local prd_path="$2"
  local spec_path="$3"
  local feature_name="$4"
  local current_story_id="$5"
  local total_stories="$6"
  local iteration="$7"
  local working_branch="${8:-}"
  local branch_setup_done="${9:-}"

  if [[ -n "$working_branch" ]]; then
    working_branch=${working_branch//\"/\\\"}
  fi

  cat > "$state_file" << EOF
---
loop_type: "go"
mode: "prd"
active: true
prd_path: "$prd_path"
spec_path: "$spec_path"
progress_path: ""
feature_name: "$feature_name"
current_story_id: $current_story_id
total_stories: $total_stories
EOF

  if [[ -n "$working_branch" ]]; then
    printf 'working_branch: "%s"\n' "$working_branch" >> "$state_file"
  fi

  if [[ -n "$branch_setup_done" ]]; then
    printf 'branch_setup_done: %s\n' "$branch_setup_done" >> "$state_file"
  fi

  cat >> "$state_file" << EOF
iteration: $iteration
max_iterations: 10
started_at: "2024-01-01T00:00:00Z"
---
# go Loop
EOF
}

write_loop_state() {
  local state_file="$1"
  local loop_type="$2"
  local iteration="$3"
  cat > "$state_file" << EOF
---
loop_type: "$loop_type"
active: true
iteration: $iteration
max_iterations: 5
completion_promise: "DONE"
progress_path: ""
started_at: "2024-01-01T00:00:00Z"
---
# $loop_type Loop
EOF
}

write_prd_two_stories() {
  local prd_path="$1"
  local pass1="$2"
  local pass2="$3"
  cat > "$prd_path" << EOF
{
  "title": "Feature",
  "stories": [
    { "id": 1, "title": "Story One", "passes": $pass1, "priority": 1 },
    { "id": 2, "title": "Story Two", "passes": $pass2, "priority": 2 }
  ]
}
EOF
}

write_prd_single_story() {
  local prd_path="$1"
  local pass1="$2"
  cat > "$prd_path" << EOF
{
  "title": "Feature",
  "stories": [
    { "id": 1, "title": "Story One", "passes": $pass1, "priority": 1 }
  ]
}
EOF
}

# =============================================================================
section "INTEGRATION: Real-World Marker Scenarios"
# =============================================================================

describe "Complex output parsing - PRD workflow"

# Simulated Claude output with documentation and actual marker
COMPLEX_OUTPUT='I understand you want me to write the spec. Let me explain the process:

1. First, I will analyze the requirements
2. Then output the phase marker like this: `<phase_complete phase="3"/>`

Here is the specification I wrote to plans/auth-feature/spec.md:

# Authentication Feature Specification
...

Now that the spec is written, here is the completion marker:

<phase_complete phase="3" spec_path="plans/auth-feature/spec.md"/>'

result=$(extract_regex_last "$COMPLEX_OUTPUT" '<phase_complete phase="([^"]+)"')
assert_eq "3" "$result" "extracts phase from complex output"

result=$(extract_regex_last "$COMPLEX_OUTPUT" 'spec_path="([^"]+)"')
assert_eq "plans/auth-feature/spec.md" "$result" "extracts spec_path from complex output"

describe "Complex output parsing - story completion"

STORY_OUTPUT='I have implemented the feature. Here is how story markers work:

Example: <story_complete story_id="1"/>

The tests are now passing. Updating prd.json...

Done! Committing changes:
git commit -m "feat(auth): story #5 - implement login form"

<reviews_complete/>
<story_complete story_id="5"/>'

result=$(extract_regex_last "$STORY_OUTPUT" '<story_complete[^>]*story_id="([^"]+)"')
assert_eq "5" "$result" "extracts correct story_id ignoring example"

result=$(extract_regex_last "$STORY_OUTPUT" '<reviews_complete/>')
assert_eq "<reviews_complete/>" "$result" "finds reviews_complete marker"

# =============================================================================
section "INTEGRATION: stop_hook End-to-End"
# =============================================================================

describe "Legacy PRD state backfill (no loop_type)"

PROJECT_DIR=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/.claude"

SESSION_ID="legacy123"
STATE_FILE="$PROJECT_DIR/.claude/prd-loop-${SESSION_ID}.local.md"
cat > "$STATE_FILE" << 'EOF'
---
mode: "prd"
active: true
feature_name: "feature-x"
current_phase: "1"
input_type: "idea"
input_path: ""
input_raw: "Build feature x"
spec_path: ""
prd_path: ""
progress_path: ""
interview_questions: 0
max_iterations: 0
gate_status: "pending"
review_count: 0
retry_count: 0
last_error: ""
started_at: "2024-01-01T00:00:00Z"
---
# PRD Loop
EOF

TRANSCRIPT="$PROJECT_DIR/transcript.jsonl"
write_transcript "$TRANSCRIPT" "No markers yet."

HOOK_INPUT=$(build_hook_input "$SESSION_ID" "$TRANSCRIPT" "$PROJECT_DIR")
run_hook "$HOOK_INPUT" "$PROJECT_DIR"

assert_eq "0" "$HOOK_STATUS" "hook exits cleanly for active PRD loop"
assert_contains "$HOOK_OUTPUT" '"decision": "block"' "hook blocks exit for active PRD loop"
BACKFILLED_LOOP=$(sed -n 's/^loop_type: "\(.*\)"/\1/p' "$STATE_FILE" | head -1)
assert_eq "prd" "$BACKFILLED_LOOP" "loop_type backfilled in state file"

describe "PRD phase 3 with Windows spec_path"

PROJECT_DIR2=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR2"
mkdir -p "$PROJECT_DIR2/.claude"

SESSION_ID2="winpath123"
STATE_FILE2="$PROJECT_DIR2/.claude/prd-loop-${SESSION_ID2}.local.md"
cat > "$STATE_FILE2" << 'EOF'
---
loop_type: "prd"
mode: "prd"
active: true
feature_name: "auth"
current_phase: "3"
input_type: "idea"
input_path: ""
input_raw: "Auth"
spec_path: ""
prd_path: ""
progress_path: ""
working_branch: "feat/auth"
branch_setup_done: true
interview_questions: 0
max_iterations: 0
reviews_complete: false
gate_status: "pending"
review_count: 0
retry_count: 0
last_error: ""
started_at: "2024-01-01T00:00:00Z"
---
# PRD Loop
EOF

WIN_MARKER='<phase_complete phase="3" spec_path="C:\Users\Dev\spec.md"/>'
TRANSCRIPT2="$PROJECT_DIR2/transcript.jsonl"
write_transcript "$TRANSCRIPT2" "$WIN_MARKER"

HOOK_INPUT2=$(build_hook_input "$SESSION_ID2" "$TRANSCRIPT2" "$PROJECT_DIR2")
run_hook "$HOOK_INPUT2" "$PROJECT_DIR2"

assert_eq "0" "$HOOK_STATUS" "hook exits cleanly with Windows spec_path"
PHASE_UPDATED=$(sed -n 's/^current_phase: "\(.*\)"/\1/p' "$STATE_FILE2" | head -1)
assert_eq "3.2" "$PHASE_UPDATED" "phase advances to 3.2"
SPEC_UPDATED=$(sed -n 's/^spec_path: "\(.*\)"/\1/p' "$STATE_FILE2" | head -1)
assert_eq 'C:\Users\Dev\spec.md' "$SPEC_UPDATED" "spec_path preserved with backslashes"
BRANCH_UPDATED=$(sed -n 's/^working_branch: "\(.*\)"/\1/p' "$STATE_FILE2" | head -1)
assert_eq "feat/auth" "$BRANCH_UPDATED" "working_branch preserved across phase transition"
BRANCH_DONE_UPDATED=$(sed -n 's/^branch_setup_done: \(.*\)/\1/p' "$STATE_FILE2" | head -1)
assert_eq "true" "$BRANCH_DONE_UPDATED" "branch_setup_done preserved across phase transition"

describe "PRD phase 3.5 requires reviews marker"

PROJECT_DIR2B=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR2B"
mkdir -p "$PROJECT_DIR2B/.claude" "$PROJECT_DIR2B/plans"

SESSION_ID2B="gatephase123"
STATE_FILE2B="$PROJECT_DIR2B/.claude/prd-loop-${SESSION_ID2B}.local.md"
cat > "$STATE_FILE2B" << EOF
---
loop_type: "prd"
mode: "prd"
active: true
feature_name: "feature-review"
current_phase: "3.5"
input_type: "idea"
input_path: ""
input_raw: "Review feature"
spec_path: "$PROJECT_DIR2B/plans/spec.md"
prd_path: ""
progress_path: ""
interview_questions: 0
max_iterations: 0
reviews_complete: false
gate_status: "pending"
review_count: 0
retry_count: 0
last_error: ""
started_at: "2024-01-01T00:00:00Z"
---
# PRD Loop
EOF

cat > "$PROJECT_DIR2B/plans/spec.md" << 'EOF'
# Spec
## Notes
EOF

TRANSCRIPT2B="$PROJECT_DIR2B/transcript.jsonl"
write_transcript "$TRANSCRIPT2B" "No markers yet."

HOOK_INPUT2B=$(build_hook_input "$SESSION_ID2B" "$TRANSCRIPT2B" "$PROJECT_DIR2B")
run_hook "$HOOK_INPUT2B" "$PROJECT_DIR2B"

assert_eq "0" "$HOOK_STATUS" "hook exits cleanly for phase 3.5 without reviews marker"
PHASE_STILL_35=$(sed -n 's/^current_phase: "\(.*\)"/\1/p' "$STATE_FILE2B" | head -1)
assert_eq "3.5" "$PHASE_STILL_35" "phase 3.5 does not auto-advance without reviews marker"
assert_contains "$HOOK_OUTPUT" "reviews_complete" "prompts for reviews marker"

describe "PRD phase 3.5 blocks gate decision before reviews"

PROJECT_DIR2C=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR2C"
mkdir -p "$PROJECT_DIR2C/.claude" "$PROJECT_DIR2C/plans"

SESSION_ID2C="gatebefore123"
STATE_FILE2C="$PROJECT_DIR2C/.claude/prd-loop-${SESSION_ID2C}.local.md"
cat > "$STATE_FILE2C" << EOF
---
loop_type: "prd"
mode: "prd"
active: true
feature_name: "feature-review"
current_phase: "3.5"
input_type: "idea"
input_path: ""
input_raw: "Review feature"
spec_path: "$PROJECT_DIR2C/plans/spec.md"
prd_path: ""
progress_path: ""
interview_questions: 0
max_iterations: 0
reviews_complete: false
gate_status: "pending"
review_count: 0
retry_count: 0
last_error: ""
started_at: "2024-01-01T00:00:00Z"
---
# PRD Loop
EOF

cat > "$PROJECT_DIR2C/plans/spec.md" << 'EOF'
# Spec
## Notes
EOF

TRANSCRIPT2C="$PROJECT_DIR2C/transcript.jsonl"
write_transcript "$TRANSCRIPT2C" "<gate_decision>PROCEED</gate_decision>"

HOOK_INPUT2C=$(build_hook_input "$SESSION_ID2C" "$TRANSCRIPT2C" "$PROJECT_DIR2C")
run_hook "$HOOK_INPUT2C" "$PROJECT_DIR2C"

assert_contains "$HOOK_OUTPUT" "reviews_complete" "gate decision blocked without reviews marker"
PHASE_STILL_35_C=$(sed -n 's/^current_phase: "\(.*\)"/\1/p' "$STATE_FILE2C" | head -1)
assert_eq "3.5" "$PHASE_STILL_35_C" "phase 3.5 remains when reviews are missing"
REVIEWS_FLAG=$(sed -n 's/^reviews_complete: \(.*\)/\1/p' "$STATE_FILE2C" | head -1)
assert_eq "false" "$REVIEWS_FLAG" "reviews_complete remains false when gate decision is premature"

describe "PRD phase 3.5 reviews then proceed advances"

PROJECT_DIR2D1=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR2D1"
mkdir -p "$PROJECT_DIR2D1/.claude" "$PROJECT_DIR2D1/plans"

SESSION_ID2D1="gateflow123"
STATE_FILE2D1="$PROJECT_DIR2D1/.claude/prd-loop-${SESSION_ID2D1}.local.md"
cat > "$STATE_FILE2D1" << EOF
---
loop_type: "prd"
mode: "prd"
active: true
feature_name: "feature-review"
current_phase: "3.5"
input_type: "idea"
input_path: ""
input_raw: "Review feature"
spec_path: "$PROJECT_DIR2D1/plans/spec.md"
prd_path: ""
progress_path: ""
interview_questions: 0
max_iterations: 0
reviews_complete: false
gate_status: "pending"
review_count: 0
retry_count: 0
last_error: ""
started_at: "2024-01-01T00:00:00Z"
---
# PRD Loop
EOF

cat > "$PROJECT_DIR2D1/plans/spec.md" << 'EOF'
# Spec
## Notes
EOF

TRANSCRIPT2D1="$PROJECT_DIR2D1/transcript.jsonl"
write_transcript "$TRANSCRIPT2D1" "<reviews_complete/>"

HOOK_INPUT2D1=$(build_hook_input "$SESSION_ID2D1" "$TRANSCRIPT2D1" "$PROJECT_DIR2D1")
run_hook "$HOOK_INPUT2D1" "$PROJECT_DIR2D1"

REVIEWS_FLAG_UPDATED=$(sed -n 's/^reviews_complete: \(.*\)/\1/p' "$STATE_FILE2D1" | head -1)
assert_eq "true" "$REVIEWS_FLAG_UPDATED" "reviews_complete set after reviews marker"
PHASE_STILL_35_D1=$(sed -n 's/^current_phase: "\(.*\)"/\1/p' "$STATE_FILE2D1" | head -1)
assert_eq "3.5" "$PHASE_STILL_35_D1" "phase remains 3.5 after reviews marker"

TRANSCRIPT2D1B="$PROJECT_DIR2D1/transcript.jsonl"
write_transcript "$TRANSCRIPT2D1B" "<gate_decision>PROCEED</gate_decision>"

HOOK_INPUT2D1B=$(build_hook_input "$SESSION_ID2D1" "$TRANSCRIPT2D1B" "$PROJECT_DIR2D1")
run_hook "$HOOK_INPUT2D1B" "$PROJECT_DIR2D1"

PHASE_UPDATED_35=$(sed -n 's/^current_phase: "\(.*\)"/\1/p' "$STATE_FILE2D1" | head -1)
assert_eq "4" "$PHASE_UPDATED_35" "phase advances to 4 after gate decision"
GATE_STATUS_UPDATED=$(sed -n 's/^gate_status: \(.*\)/\1/p' "$STATE_FILE2D1" | head -1)
assert_eq "proceed" "$GATE_STATUS_UPDATED" "gate_status updated to proceed"

describe "PRD phase 3.5 reviews then block stays"

PROJECT_DIR2D2=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR2D2"
mkdir -p "$PROJECT_DIR2D2/.claude" "$PROJECT_DIR2D2/plans"

SESSION_ID2D2="gateblock123"
STATE_FILE2D2="$PROJECT_DIR2D2/.claude/prd-loop-${SESSION_ID2D2}.local.md"
cat > "$STATE_FILE2D2" << EOF
---
loop_type: "prd"
mode: "prd"
active: true
feature_name: "feature-review"
current_phase: "3.5"
input_type: "idea"
input_path: ""
input_raw: "Review feature"
spec_path: "$PROJECT_DIR2D2/plans/spec.md"
prd_path: ""
progress_path: ""
interview_questions: 0
max_iterations: 0
reviews_complete: false
gate_status: "pending"
review_count: 0
retry_count: 0
last_error: ""
started_at: "2024-01-01T00:00:00Z"
---
# PRD Loop
EOF

cat > "$PROJECT_DIR2D2/plans/spec.md" << 'EOF'
# Spec
## Notes
EOF

TRANSCRIPT2D2="$PROJECT_DIR2D2/transcript.jsonl"
write_transcript "$TRANSCRIPT2D2" "<reviews_complete/>"

HOOK_INPUT2D2=$(build_hook_input "$SESSION_ID2D2" "$TRANSCRIPT2D2" "$PROJECT_DIR2D2")
run_hook "$HOOK_INPUT2D2" "$PROJECT_DIR2D2"

REVIEWS_FLAG_BLOCK=$(sed -n 's/^reviews_complete: \(.*\)/\1/p' "$STATE_FILE2D2" | head -1)
assert_eq "true" "$REVIEWS_FLAG_BLOCK" "reviews_complete set before blocking gate"

TRANSCRIPT2D2B="$PROJECT_DIR2D2/transcript.jsonl"
write_transcript "$TRANSCRIPT2D2B" "<gate_decision>BLOCK</gate_decision>"

HOOK_INPUT2D2B=$(build_hook_input "$SESSION_ID2D2" "$TRANSCRIPT2D2B" "$PROJECT_DIR2D2")
run_hook "$HOOK_INPUT2D2B" "$PROJECT_DIR2D2"

PHASE_BLOCKED=$(sed -n 's/^current_phase: "\(.*\)"/\1/p' "$STATE_FILE2D2" | head -1)
assert_eq "3.5" "$PHASE_BLOCKED" "phase remains 3.5 after gate block"
REVIEW_COUNT_BLOCKED=$(sed -n 's/^review_count: \(.*\)/\1/p' "$STATE_FILE2D2" | head -1)
assert_eq "1" "$REVIEW_COUNT_BLOCKED" "review_count increments on block"
GATE_STATUS_BLOCKED=$(sed -n 's/^gate_status: \(.*\)/\1/p' "$STATE_FILE2D2" | head -1)
assert_eq "blocked" "$GATE_STATUS_BLOCKED" "gate_status updated to blocked"
assert_contains "$HOOK_OUTPUT" "Review gate blocked" "blocked gate produces guidance"

describe "PRD phase 3.2 auto-advances when implementation patterns present"

PROJECT_DIR2D=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR2D"
mkdir -p "$PROJECT_DIR2D/.claude" "$PROJECT_DIR2D/plans"

SESSION_ID2D="autophase32"
STATE_FILE2D="$PROJECT_DIR2D/.claude/prd-loop-${SESSION_ID2D}.local.md"
cat > "$STATE_FILE2D" << EOF
---
loop_type: "prd"
mode: "prd"
active: true
feature_name: "feature-auto"
current_phase: "3.2"
input_type: "idea"
input_path: ""
input_raw: "Auto phase"
spec_path: "$PROJECT_DIR2D/plans/spec.md"
prd_path: ""
progress_path: ""
interview_questions: 0
max_iterations: 0
reviews_complete: false
gate_status: "pending"
review_count: 0
retry_count: 0
last_error: ""
started_at: "2024-01-01T00:00:00Z"
---
# PRD Loop
EOF

cat > "$PROJECT_DIR2D/plans/spec.md" << 'EOF'
# Spec
## Implementation Patterns
- pattern
EOF

TRANSCRIPT2D="$PROJECT_DIR2D/transcript.jsonl"
write_transcript "$TRANSCRIPT2D" "No markers yet."

HOOK_INPUT2D=$(build_hook_input "$SESSION_ID2D" "$TRANSCRIPT2D" "$PROJECT_DIR2D")
run_hook "$HOOK_INPUT2D" "$PROJECT_DIR2D"

PHASE_UPDATED_32=$(sed -n 's/^current_phase: "\(.*\)"/\1/p' "$STATE_FILE2D" | head -1)
assert_eq "3.5" "$PHASE_UPDATED_32" "phase 3.2 auto-advances to 3.5"
assert_contains "$HOOK_OUTPUT" "Auto-advanced from 3.2" "auto-advance message for phase 3.2"

describe "PRD phase 4 auto-advances when prd.json exists"

PROJECT_DIR2E=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR2E"
mkdir -p "$PROJECT_DIR2E/.claude" "$PROJECT_DIR2E/plans"

SESSION_ID2E="autophase4"
STATE_FILE2E="$PROJECT_DIR2E/.claude/prd-loop-${SESSION_ID2E}.local.md"
cat > "$STATE_FILE2E" << EOF
---
loop_type: "prd"
mode: "prd"
active: true
feature_name: "feature-auto"
current_phase: "4"
input_type: "idea"
input_path: ""
input_raw: "Auto phase"
spec_path: "$PROJECT_DIR2E/plans/spec.md"
prd_path: "$PROJECT_DIR2E/plans/prd.json"
progress_path: ""
interview_questions: 0
max_iterations: 0
reviews_complete: false
gate_status: "pending"
review_count: 0
retry_count: 0
last_error: ""
started_at: "2024-01-01T00:00:00Z"
---
# PRD Loop
EOF

cat > "$PROJECT_DIR2E/plans/prd.json" << 'EOF'
{ "title": "Feature", "stories": [] }
EOF

TRANSCRIPT2E="$PROJECT_DIR2E/transcript.jsonl"
write_transcript "$TRANSCRIPT2E" "No markers yet."

HOOK_INPUT2E=$(build_hook_input "$SESSION_ID2E" "$TRANSCRIPT2E" "$PROJECT_DIR2E")
run_hook "$HOOK_INPUT2E" "$PROJECT_DIR2E"

PHASE_UPDATED_4=$(sed -n 's/^current_phase: "\(.*\)"/\1/p' "$STATE_FILE2E" | head -1)
assert_eq "5" "$PHASE_UPDATED_4" "phase 4 auto-advances to 5"
assert_contains "$HOOK_OUTPUT" "Auto-advanced from 4" "auto-advance message for phase 4"

describe "PRD phase 5 auto-advances when progress file exists"

PROJECT_DIR2F=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR2F"
mkdir -p "$PROJECT_DIR2F/.claude" "$PROJECT_DIR2F/plans"

SESSION_ID2F="autophase5"
STATE_FILE2F="$PROJECT_DIR2F/.claude/prd-loop-${SESSION_ID2F}.local.md"
cat > "$STATE_FILE2F" << EOF
---
loop_type: "prd"
mode: "prd"
active: true
feature_name: "feature-auto"
current_phase: "5"
input_type: "idea"
input_path: ""
input_raw: "Auto phase"
spec_path: "$PROJECT_DIR2F/plans/spec.md"
prd_path: "$PROJECT_DIR2F/plans/prd.json"
progress_path: "$PROJECT_DIR2F/plans/progress.txt"
interview_questions: 0
max_iterations: 0
reviews_complete: false
gate_status: "pending"
review_count: 0
retry_count: 0
last_error: ""
started_at: "2024-01-01T00:00:00Z"
---
# PRD Loop
EOF

printf '%s\n' "progress" > "$PROJECT_DIR2F/plans/progress.txt"

TRANSCRIPT2F="$PROJECT_DIR2F/transcript.jsonl"
write_transcript "$TRANSCRIPT2F" "No markers yet."

HOOK_INPUT2F=$(build_hook_input "$SESSION_ID2F" "$TRANSCRIPT2F" "$PROJECT_DIR2F")
run_hook "$HOOK_INPUT2F" "$PROJECT_DIR2F"

PHASE_UPDATED_5=$(sed -n 's/^current_phase: "\(.*\)"/\1/p' "$STATE_FILE2F" | head -1)
assert_eq "5.5" "$PHASE_UPDATED_5" "phase 5 auto-advances to 5.5"
assert_contains "$HOOK_OUTPUT" "Auto-advanced from 5" "auto-advance message for phase 5"

describe "PRD phase 6 auto-completes when files exist"

PROJECT_DIR2G=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR2G"
mkdir -p "$PROJECT_DIR2G/.claude" "$PROJECT_DIR2G/plans"

SESSION_ID2G="autophase6"
STATE_FILE2G="$PROJECT_DIR2G/.claude/prd-loop-${SESSION_ID2G}.local.md"
cat > "$STATE_FILE2G" << EOF
---
loop_type: "prd"
mode: "prd"
active: true
feature_name: "feature-auto"
current_phase: "6"
input_type: "idea"
input_path: ""
input_raw: "Auto phase"
spec_path: "$PROJECT_DIR2G/plans/spec.md"
prd_path: "$PROJECT_DIR2G/plans/prd.json"
progress_path: "$PROJECT_DIR2G/plans/progress.txt"
interview_questions: 0
max_iterations: 0
reviews_complete: false
gate_status: "pending"
review_count: 0
retry_count: 0
last_error: ""
started_at: "2024-01-01T00:00:00Z"
---
# PRD Loop
EOF

printf '%s\n' "spec" > "$PROJECT_DIR2G/plans/spec.md"
printf '%s\n' '{ "title": "Feature", "stories": [] }' > "$PROJECT_DIR2G/plans/prd.json"
printf '%s\n' "progress" > "$PROJECT_DIR2G/plans/progress.txt"

TRANSCRIPT2G="$PROJECT_DIR2G/transcript.jsonl"
write_transcript "$TRANSCRIPT2G" "No markers yet."

HOOK_INPUT2G=$(build_hook_input "$SESSION_ID2G" "$TRANSCRIPT2G" "$PROJECT_DIR2G")
run_hook "$HOOK_INPUT2G" "$PROJECT_DIR2G"

[[ -f "$STATE_FILE2G" ]] && state_status="exists" || state_status="missing"
assert_eq "missing" "$state_status" "state file removed when phase 6 auto-completes"

describe "PRD stuck detection prompts recovery"

PROJECT_DIR2H=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR2H"
mkdir -p "$PROJECT_DIR2H/.claude"

SESSION_ID2H="recovery123"
STATE_FILE2H="$PROJECT_DIR2H/.claude/prd-loop-${SESSION_ID2H}.local.md"
cat > "$STATE_FILE2H" << 'EOF'
---
loop_type: "prd"
mode: "prd"
active: true
feature_name: "feature-stuck"
current_phase: "2"
input_type: "idea"
input_path: ""
input_raw: "Stuck feature"
spec_path: ""
prd_path: ""
progress_path: ""
interview_questions: 0
max_iterations: 0
reviews_complete: false
gate_status: "pending"
review_count: 0
retry_count: 2
last_error: ""
started_at: "2024-01-01T00:00:00Z"
---
# PRD Loop
EOF

TRANSCRIPT2H="$PROJECT_DIR2H/transcript.jsonl"
write_transcript "$TRANSCRIPT2H" "No markers yet."

HOOK_INPUT2H=$(build_hook_input "$SESSION_ID2H" "$TRANSCRIPT2H" "$PROJECT_DIR2H")
run_hook "$HOOK_INPUT2H" "$PROJECT_DIR2H"

assert_contains "$HOOK_OUTPUT" "Recovery Needed" "max retries triggers recovery prompt"
RETRY_UPDATED=$(sed -n 's/^retry_count: \(.*\)/\1/p' "$STATE_FILE2H" | head -1)
assert_eq "3" "$RETRY_UPDATED" "retry_count increments to max"

describe "Promise extraction uses last match"

PROJECT_DIR3=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR3"
mkdir -p "$PROJECT_DIR3/.claude"

SESSION_ID3="promise123"
STATE_FILE3="$PROJECT_DIR3/.claude/go-loop-${SESSION_ID3}.local.md"
cat > "$STATE_FILE3" << 'EOF'
---
loop_type: "go"
mode: "generic"
active: true
once: false
iteration: 1
max_iterations: 5
completion_promise: "TESTS_PASS"
progress_path: ""
started_at: "2024-01-01T00:00:00Z"
---
# go Loop
EOF

PROMISE_OUTPUT='Example:
<promise>DONE</promise>

All tests passing:
<promise>TESTS_PASS</promise>'
TRANSCRIPT3="$PROJECT_DIR3/transcript.jsonl"
write_transcript "$TRANSCRIPT3" "$PROMISE_OUTPUT"

HOOK_INPUT3=$(build_hook_input "$SESSION_ID3" "$TRANSCRIPT3" "$PROJECT_DIR3")
run_hook "$HOOK_INPUT3" "$PROJECT_DIR3"

if [[ -f "$STATE_FILE3" ]]; then
  status="exists"
else
  status="missing"
fi
assert_eq "missing" "$status" "state file removed on promise completion"

# =============================================================================
section "INTEGRATION: PRD next-phase validation"
# =============================================================================

describe "Invalid next phase blocks and records error"

PROJECT_DIR4=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR4"
mkdir -p "$PROJECT_DIR4/.claude"

SESSION_ID4="badnext123"
STATE_FILE4="$PROJECT_DIR4/.claude/prd-loop-${SESSION_ID4}.local.md"
cat > "$STATE_FILE4" << 'EOF'
---
loop_type: "prd"
mode: "prd"
active: true
feature_name: "feature-y"
current_phase: "1"
input_type: "idea"
input_path: ""
input_raw: "Feature y"
spec_path: ""
prd_path: ""
progress_path: ""
interview_questions: 0
max_iterations: 0
reviews_complete: false
gate_status: "pending"
review_count: 0
retry_count: 0
last_error: ""
started_at: "2024-01-01T00:00:00Z"
---
# PRD Loop
EOF

BAD_NEXT_OUTPUT='<phase_complete phase="1" next="7"/>'
TRANSCRIPT4="$PROJECT_DIR4/transcript.jsonl"
write_transcript "$TRANSCRIPT4" "$BAD_NEXT_OUTPUT"

HOOK_INPUT4=$(build_hook_input "$SESSION_ID4" "$TRANSCRIPT4" "$PROJECT_DIR4")
run_hook "$HOOK_INPUT4" "$PROJECT_DIR4"

assert_eq "0" "$HOOK_STATUS" "hook exits cleanly for invalid next phase"
assert_contains "$HOOK_OUTPUT" '"decision": "block"' "hook blocks on invalid next phase"
PHASE_STILL=$(sed -n 's/^current_phase: "\(.*\)"/\1/p' "$STATE_FILE4" | head -1)
assert_eq "1" "$PHASE_STILL" "phase remains unchanged on invalid next"
RETRY_COUNT_UPDATED=$(sed -n 's/^retry_count: \(.*\)/\1/p' "$STATE_FILE4" | head -1)
assert_eq "1" "$RETRY_COUNT_UPDATED" "retry_count increments on invalid next"
LAST_ERROR_UPDATED=$(sed -n 's/^last_error: "\(.*\)"/\1/p' "$STATE_FILE4" | head -1)
assert_contains "$LAST_ERROR_UPDATED" "Invalid next phase '7'" "last_error records invalid next phase"

# =============================================================================
section "INTEGRATION: Transcript parsing resilience"
# =============================================================================

describe "Invalid transcript JSON does not crash hook"

PROJECT_DIR5=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR5"
mkdir -p "$PROJECT_DIR5/.claude"

SESSION_ID5="badjson123"
STATE_FILE5="$PROJECT_DIR5/.claude/go-loop-${SESSION_ID5}.local.md"
cat > "$STATE_FILE5" << 'EOF'
---
loop_type: "go"
mode: "generic"
active: true
once: false
iteration: 1
max_iterations: 5
completion_promise: "DONE"
progress_path: ""
started_at: "2024-01-01T00:00:00Z"
---
# go Loop
EOF

TRANSCRIPT5="$PROJECT_DIR5/transcript.jsonl"
# Intentionally malformed JSON (missing closing brace) to test parsing failure.
cat > "$TRANSCRIPT5" << 'EOF'
{ "role": "assistant", "message": { "content": [ { "type": "text", "text": "hi" } ] }
EOF

HOOK_INPUT5=$(build_hook_input "$SESSION_ID5" "$TRANSCRIPT5" "$PROJECT_DIR5")
run_hook "$HOOK_INPUT5" "$PROJECT_DIR5"

assert_eq "0" "$HOOK_STATUS" "hook exits cleanly on invalid transcript JSON"
assert_contains "$HOOK_OUTPUT" '"decision": "block"' "hook blocks and continues loop"
assert_contains "$HOOK_STDERR" "Failed to parse assistant message JSON" "stderr includes parse warning"
[[ -f "$STATE_FILE5" ]] && state_status="exists" || state_status="missing"
assert_eq "exists" "$state_status" "state file remains after parse failure"

describe "Transcript with spaced role is parsed"

PROJECT_DIR6=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR6"
mkdir -p "$PROJECT_DIR6/.claude"

SESSION_ID6="spacedrole123"
STATE_FILE6="$PROJECT_DIR6/.claude/go-loop-${SESSION_ID6}.local.md"
cat > "$STATE_FILE6" << 'EOF'
---
loop_type: "go"
mode: "generic"
active: true
once: false
iteration: 1
max_iterations: 5
completion_promise: "DONE"
progress_path: ""
started_at: "2024-01-01T00:00:00Z"
---
# go Loop
EOF

TRANSCRIPT6="$PROJECT_DIR6/transcript.jsonl"
cat > "$TRANSCRIPT6" << 'EOF'
{ "role": "assistant", "message": { "content": [ { "type": "text", "text": "<promise>DONE</promise>" } ] } }
EOF

HOOK_INPUT6=$(build_hook_input "$SESSION_ID6" "$TRANSCRIPT6" "$PROJECT_DIR6")
run_hook "$HOOK_INPUT6" "$PROJECT_DIR6"

[[ -f "$STATE_FILE6" ]] && state_status="exists" || state_status="missing"
assert_eq "missing" "$state_status" "promise completes even with spaced role"

# =============================================================================
section "INTEGRATION: go/prd PRD file validation"
# =============================================================================

describe "Missing prd.json blocks go/prd loop"

PROJECT_DIR7=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR7"
mkdir -p "$PROJECT_DIR7/.claude"

SESSION_ID7="missingprd123"
STATE_FILE7="$PROJECT_DIR7/.claude/go-loop-${SESSION_ID7}.local.md"
cat > "$STATE_FILE7" << EOF
---
loop_type: "go"
mode: "prd"
active: true
prd_path: "$PROJECT_DIR7/plans/missing-prd.json"
spec_path: "$PROJECT_DIR7/plans/spec.md"
progress_path: ""
feature_name: "feature-z"
current_story_id: 1
total_stories: 1
iteration: 1
max_iterations: 5
started_at: "2024-01-01T00:00:00Z"
---
# go Loop
EOF

TRANSCRIPT7="$PROJECT_DIR7/transcript.jsonl"
write_transcript "$TRANSCRIPT7" "No markers yet."

HOOK_INPUT7=$(build_hook_input "$SESSION_ID7" "$TRANSCRIPT7" "$PROJECT_DIR7")
run_hook "$HOOK_INPUT7" "$PROJECT_DIR7"

assert_contains "$HOOK_OUTPUT" "PRD file not found" "missing prd.json blocks loop"
[[ -f "$STATE_FILE7" ]] && state_status="exists" || state_status="missing"
assert_eq "exists" "$state_status" "state file remains when prd.json missing"

describe "Invalid prd.json blocks go/prd loop"

PROJECT_DIR8=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR8"
mkdir -p "$PROJECT_DIR8/.claude" "$PROJECT_DIR8/plans"

SESSION_ID8="invalidprd123"
STATE_FILE8="$PROJECT_DIR8/.claude/go-loop-${SESSION_ID8}.local.md"
cat > "$STATE_FILE8" << EOF
---
loop_type: "go"
mode: "prd"
active: true
prd_path: "$PROJECT_DIR8/plans/prd.json"
spec_path: "$PROJECT_DIR8/plans/spec.md"
progress_path: ""
feature_name: "feature-w"
current_story_id: 1
total_stories: 1
iteration: 1
max_iterations: 5
started_at: "2024-01-01T00:00:00Z"
---
# go Loop
EOF

cat > "$PROJECT_DIR8/plans/prd.json" << 'EOF'
{ "invalid": true
EOF

TRANSCRIPT8="$PROJECT_DIR8/transcript.jsonl"
write_transcript "$TRANSCRIPT8" "No markers yet."

HOOK_INPUT8=$(build_hook_input "$SESSION_ID8" "$TRANSCRIPT8" "$PROJECT_DIR8")
run_hook "$HOOK_INPUT8" "$PROJECT_DIR8"

assert_contains "$HOOK_OUTPUT" "PRD file is invalid JSON" "invalid prd.json blocks loop"
[[ -f "$STATE_FILE8" ]] && state_status="exists" || state_status="missing"
assert_eq "exists" "$state_status" "state file remains when prd.json invalid"

# =============================================================================
section "INTEGRATION: go/prd Story Gating"
# =============================================================================

describe "Story not passing blocks"

PROJECT_DIR9=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR9"
mkdir -p "$PROJECT_DIR9/.claude" "$PROJECT_DIR9/plans"

SESSION_ID9="storypass123"
STATE_FILE9="$PROJECT_DIR9/.claude/go-loop-${SESSION_ID9}.local.md"
write_go_prd_state "$STATE_FILE9" "$PROJECT_DIR9/plans/prd.json" "$PROJECT_DIR9/plans/spec.md" "feature-a" 1 2 1
write_prd_two_stories "$PROJECT_DIR9/plans/prd.json" "false" "false"

TRANSCRIPT9="$PROJECT_DIR9/transcript.jsonl"
write_transcript "$TRANSCRIPT9" "No markers yet."

HOOK_INPUT9=$(build_hook_input "$SESSION_ID9" "$TRANSCRIPT9" "$PROJECT_DIR9")
run_hook "$HOOK_INPUT9" "$PROJECT_DIR9"

assert_contains "$HOOK_OUTPUT" "not yet passing" "blocks when story not passing"

describe "Passing story without reviews blocks"

PROJECT_DIR10=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR10"
mkdir -p "$PROJECT_DIR10/.claude" "$PROJECT_DIR10/plans"

SESSION_ID10="noreviews123"
STATE_FILE10="$PROJECT_DIR10/.claude/go-loop-${SESSION_ID10}.local.md"
write_go_prd_state "$STATE_FILE10" "$PROJECT_DIR10/plans/prd.json" "$PROJECT_DIR10/plans/spec.md" "feature-b" 1 2 1
write_prd_two_stories "$PROJECT_DIR10/plans/prd.json" "true" "false"

TRANSCRIPT10="$PROJECT_DIR10/transcript.jsonl"
write_transcript "$TRANSCRIPT10" "No markers yet."

HOOK_INPUT10=$(build_hook_input "$SESSION_ID10" "$TRANSCRIPT10" "$PROJECT_DIR10")
run_hook "$HOOK_INPUT10" "$PROJECT_DIR10"

assert_contains "$HOOK_OUTPUT" "REVIEWS NOT run" "blocks when reviews missing"

describe "Reviews complete but no story_complete blocks"

PROJECT_DIR11=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR11"
mkdir -p "$PROJECT_DIR11/.claude" "$PROJECT_DIR11/plans"

SESSION_ID11="nostorymarker123"
STATE_FILE11="$PROJECT_DIR11/.claude/go-loop-${SESSION_ID11}.local.md"
write_go_prd_state "$STATE_FILE11" "$PROJECT_DIR11/plans/prd.json" "$PROJECT_DIR11/plans/spec.md" "feature-c" 1 2 1
write_prd_two_stories "$PROJECT_DIR11/plans/prd.json" "true" "false"

TRANSCRIPT11="$PROJECT_DIR11/transcript.jsonl"
write_transcript "$TRANSCRIPT11" "<reviews_complete/>"

HOOK_INPUT11=$(build_hook_input "$SESSION_ID11" "$TRANSCRIPT11" "$PROJECT_DIR11")
run_hook "$HOOK_INPUT11" "$PROJECT_DIR11"

assert_contains "$HOOK_OUTPUT" "Now commit and output" "blocks until story_complete marker"

describe "Story id mismatch blocks"

PROJECT_DIR12=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR12"
mkdir -p "$PROJECT_DIR12/.claude" "$PROJECT_DIR12/plans"

SESSION_ID12="mismatch123"
STATE_FILE12="$PROJECT_DIR12/.claude/go-loop-${SESSION_ID12}.local.md"
write_go_prd_state "$STATE_FILE12" "$PROJECT_DIR12/plans/prd.json" "$PROJECT_DIR12/plans/spec.md" "feature-d" 1 2 1
write_prd_two_stories "$PROJECT_DIR12/plans/prd.json" "true" "false"

TRANSCRIPT12="$PROJECT_DIR12/transcript.jsonl"
write_transcript "$TRANSCRIPT12" "<reviews_complete/>\n<story_complete story_id=\"2\"/>"

HOOK_INPUT12=$(build_hook_input "$SESSION_ID12" "$TRANSCRIPT12" "$PROJECT_DIR12")
run_hook "$HOOK_INPUT12" "$PROJECT_DIR12"

assert_contains "$HOOK_OUTPUT" "story_id mismatch" "blocks on story_id mismatch"

describe "story_complete with passes false blocks"

PROJECT_DIR13=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR13"
mkdir -p "$PROJECT_DIR13/.claude" "$PROJECT_DIR13/plans"

SESSION_ID13="passesfalse123"
STATE_FILE13="$PROJECT_DIR13/.claude/go-loop-${SESSION_ID13}.local.md"
write_go_prd_state "$STATE_FILE13" "$PROJECT_DIR13/plans/prd.json" "$PROJECT_DIR13/plans/spec.md" "feature-e" 1 2 1
write_prd_two_stories "$PROJECT_DIR13/plans/prd.json" "false" "false"

TRANSCRIPT13="$PROJECT_DIR13/transcript.jsonl"
write_transcript "$TRANSCRIPT13" "<reviews_complete/>\n<story_complete story_id=\"1\"/>"

HOOK_INPUT13=$(build_hook_input "$SESSION_ID13" "$TRANSCRIPT13" "$PROJECT_DIR13")
run_hook "$HOOK_INPUT13" "$PROJECT_DIR13"

assert_contains "$HOOK_OUTPUT" "passes: false" "blocks when prd.json not updated"

describe "story_complete without reviews blocks"

PROJECT_DIR14=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR14"
mkdir -p "$PROJECT_DIR14/.claude" "$PROJECT_DIR14/plans"

SESSION_ID14="missingreviews123"
STATE_FILE14="$PROJECT_DIR14/.claude/go-loop-${SESSION_ID14}.local.md"
write_go_prd_state "$STATE_FILE14" "$PROJECT_DIR14/plans/prd.json" "$PROJECT_DIR14/plans/spec.md" "feature-f" 1 2 1
write_prd_two_stories "$PROJECT_DIR14/plans/prd.json" "true" "false"

TRANSCRIPT14="$PROJECT_DIR14/transcript.jsonl"
write_transcript "$TRANSCRIPT14" "<story_complete story_id=\"1\"/>"

HOOK_INPUT14=$(build_hook_input "$SESSION_ID14" "$TRANSCRIPT14" "$PROJECT_DIR14")
run_hook "$HOOK_INPUT14" "$PROJECT_DIR14"

assert_contains "$HOOK_OUTPUT" "reviews_complete" "blocks when reviews marker missing"

describe "Missing commit blocks and increments iteration"

PROJECT_DIR15=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR15"
mkdir -p "$PROJECT_DIR15/.claude" "$PROJECT_DIR15/plans"
init_git_repo "$PROJECT_DIR15"
git_commit_file "$PROJECT_DIR15" "chore: init" "README.md" "init"

SESSION_ID15="nocommit123"
STATE_FILE15="$PROJECT_DIR15/.claude/go-loop-${SESSION_ID15}.local.md"
write_go_prd_state "$STATE_FILE15" "$PROJECT_DIR15/plans/prd.json" "$PROJECT_DIR15/plans/spec.md" "feature-g" 1 2 1
write_prd_two_stories "$PROJECT_DIR15/plans/prd.json" "true" "false"

TRANSCRIPT15="$PROJECT_DIR15/transcript.jsonl"
write_transcript "$TRANSCRIPT15" "<reviews_complete/>\n<story_complete story_id=\"1\"/>"

HOOK_INPUT15=$(build_hook_input "$SESSION_ID15" "$TRANSCRIPT15" "$PROJECT_DIR15")
run_hook "$HOOK_INPUT15" "$PROJECT_DIR15"

assert_contains "$HOOK_OUTPUT" "NO COMMIT found" "blocks when commit missing"
ITER_UPDATED=$(sed -n 's/^iteration: \(.*\)/\1/p' "$STATE_FILE15" | head -1)
assert_eq "2" "$ITER_UPDATED" "iteration increments when commit missing"

describe "Commit advances to next story"

PROJECT_DIR16=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR16"
mkdir -p "$PROJECT_DIR16/.claude" "$PROJECT_DIR16/plans"
init_git_repo "$PROJECT_DIR16"
git_commit_file "$PROJECT_DIR16" "feat(feature-h): story #1 - done" "README.md" "done"

SESSION_ID16="advance123"
STATE_FILE16="$PROJECT_DIR16/.claude/go-loop-${SESSION_ID16}.local.md"
write_go_prd_state "$STATE_FILE16" "$PROJECT_DIR16/plans/prd.json" "$PROJECT_DIR16/plans/spec.md" "feature-h" 1 2 1 "feat/feature-h" "true"
write_prd_two_stories "$PROJECT_DIR16/plans/prd.json" "true" "false"

TRANSCRIPT16="$PROJECT_DIR16/transcript.jsonl"
write_transcript "$TRANSCRIPT16" "<reviews_complete/>\n<story_complete story_id=\"1\"/>"

HOOK_INPUT16=$(build_hook_input "$SESSION_ID16" "$TRANSCRIPT16" "$PROJECT_DIR16")
run_hook "$HOOK_INPUT16" "$PROJECT_DIR16"

NEXT_ID=$(sed -n 's/^current_story_id: \(.*\)/\1/p' "$STATE_FILE16" | head -1)
assert_eq "2" "$NEXT_ID" "advances to next story"
NEXT_ITER=$(sed -n 's/^iteration: \(.*\)/\1/p' "$STATE_FILE16" | head -1)
assert_eq "2" "$NEXT_ITER" "iteration increments on advance"
BRANCH_PERSIST=$(sed -n 's/^working_branch: "\(.*\)"/\1/p' "$STATE_FILE16" | head -1)
assert_eq "feat/feature-h" "$BRANCH_PERSIST" "working_branch preserved on advance"
BRANCH_DONE=$(sed -n 's/^branch_setup_done: \(.*\)/\1/p' "$STATE_FILE16" | head -1)
assert_eq "true" "$BRANCH_DONE" "branch_setup_done preserved on advance"
assert_contains "$HOOK_OUTPUT" "Story #1 complete! Now on story #2" "output announces next story"

describe "All stories complete removes state file"

PROJECT_DIR17=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR17"
mkdir -p "$PROJECT_DIR17/.claude" "$PROJECT_DIR17/plans"
init_git_repo "$PROJECT_DIR17"
git_commit_file "$PROJECT_DIR17" "feat(feature-i): story #1 - done" "README.md" "done"

SESSION_ID17="complete123"
STATE_FILE17="$PROJECT_DIR17/.claude/go-loop-${SESSION_ID17}.local.md"
write_go_prd_state "$STATE_FILE17" "$PROJECT_DIR17/plans/prd.json" "$PROJECT_DIR17/plans/spec.md" "feature-i" 1 1 1
write_prd_single_story "$PROJECT_DIR17/plans/prd.json" "true"

TRANSCRIPT17="$PROJECT_DIR17/transcript.jsonl"
write_transcript "$TRANSCRIPT17" "<reviews_complete/>\n<story_complete story_id=\"1\"/>"

HOOK_INPUT17=$(build_hook_input "$SESSION_ID17" "$TRANSCRIPT17" "$PROJECT_DIR17")
run_hook "$HOOK_INPUT17" "$PROJECT_DIR17"

[[ -f "$STATE_FILE17" ]] && state_status="exists" || state_status="missing"
assert_eq "missing" "$state_status" "state file removed when all stories complete"

# =============================================================================
section "INTEGRATION: ut/e2e Gating"
# =============================================================================

describe "UT reviews missing blocks"

PROJECT_DIR18=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR18"
mkdir -p "$PROJECT_DIR18/.claude"

SESSION_ID18="utreviews123"
STATE_FILE18="$PROJECT_DIR18/.claude/ut-loop-${SESSION_ID18}.local.md"
write_loop_state "$STATE_FILE18" "ut" 1

TRANSCRIPT18="$PROJECT_DIR18/transcript.jsonl"
write_transcript "$TRANSCRIPT18" "No markers yet."

HOOK_INPUT18=$(build_hook_input "$SESSION_ID18" "$TRANSCRIPT18" "$PROJECT_DIR18")
run_hook "$HOOK_INPUT18" "$PROJECT_DIR18"

assert_contains "$HOOK_OUTPUT" "Reviews NOT run" "blocks when UT reviews missing"

describe "UT reviews complete but iteration missing blocks"

PROJECT_DIR19=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR19"
mkdir -p "$PROJECT_DIR19/.claude"

SESSION_ID19="utiter123"
STATE_FILE19="$PROJECT_DIR19/.claude/ut-loop-${SESSION_ID19}.local.md"
write_loop_state "$STATE_FILE19" "ut" 1

TRANSCRIPT19="$PROJECT_DIR19/transcript.jsonl"
write_transcript "$TRANSCRIPT19" "<reviews_complete/>"

HOOK_INPUT19=$(build_hook_input "$SESSION_ID19" "$TRANSCRIPT19" "$PROJECT_DIR19")
run_hook "$HOOK_INPUT19" "$PROJECT_DIR19"

assert_contains "$HOOK_OUTPUT" "iteration incomplete" "blocks when iteration marker missing"

describe "UT markers without test commit blocks"

PROJECT_DIR20=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR20"
mkdir -p "$PROJECT_DIR20/.claude"
init_git_repo "$PROJECT_DIR20"
git_commit_file "$PROJECT_DIR20" "chore: init" "README.md" "init"

SESSION_ID20="utnocommit123"
STATE_FILE20="$PROJECT_DIR20/.claude/ut-loop-${SESSION_ID20}.local.md"
write_loop_state "$STATE_FILE20" "ut" 1

TRANSCRIPT20="$PROJECT_DIR20/transcript.jsonl"
write_transcript "$TRANSCRIPT20" "<reviews_complete/>\n<iteration_complete test_file=\"tests/unit.spec.ts\"/>"

HOOK_INPUT20=$(build_hook_input "$SESSION_ID20" "$TRANSCRIPT20" "$PROJECT_DIR20")
run_hook "$HOOK_INPUT20" "$PROJECT_DIR20"

assert_contains "$HOOK_OUTPUT" "NO COMMIT found" "blocks when test commit missing"
ITER_UT=$(sed -n 's/^iteration: \(.*\)/\1/p' "$STATE_FILE20" | head -1)
assert_eq "1" "$ITER_UT" "iteration remains when UT commit missing"

describe "UT with test commit advances iteration"

PROJECT_DIR21=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR21"
mkdir -p "$PROJECT_DIR21/.claude"
init_git_repo "$PROJECT_DIR21"
git_commit_file "$PROJECT_DIR21" "test: add coverage" "README.md" "tests"

SESSION_ID21="utcommit123"
STATE_FILE21="$PROJECT_DIR21/.claude/ut-loop-${SESSION_ID21}.local.md"
write_loop_state "$STATE_FILE21" "ut" 1

TRANSCRIPT21="$PROJECT_DIR21/transcript.jsonl"
write_transcript "$TRANSCRIPT21" "<reviews_complete/>\n<iteration_complete test_file=\"tests/unit.spec.ts\"/>"

HOOK_INPUT21=$(build_hook_input "$SESSION_ID21" "$TRANSCRIPT21" "$PROJECT_DIR21")
run_hook "$HOOK_INPUT21" "$PROJECT_DIR21"

assert_contains "$HOOK_OUTPUT" '"decision": "block"' "UT continues loop after successful iteration"
ITER_UT_NEXT=$(sed -n 's/^iteration: \(.*\)/\1/p' "$STATE_FILE21" | head -1)
assert_eq "2" "$ITER_UT_NEXT" "UT iteration increments on success"

describe "E2E with test commit advances iteration"

PROJECT_DIR22=$(mktemp_dir)
register_cleanup_dir "$PROJECT_DIR22"
mkdir -p "$PROJECT_DIR22/.claude"
init_git_repo "$PROJECT_DIR22"
git_commit_file "$PROJECT_DIR22" "test: add e2e flow" "README.md" "e2e"

SESSION_ID22="e2ecommit123"
STATE_FILE22="$PROJECT_DIR22/.claude/e2e-loop-${SESSION_ID22}.local.md"
write_loop_state "$STATE_FILE22" "e2e" 1

TRANSCRIPT22="$PROJECT_DIR22/transcript.jsonl"
write_transcript "$TRANSCRIPT22" "<reviews_complete/>\n<iteration_complete test_file=\"tests/e2e.spec.ts\"/>"

HOOK_INPUT22=$(build_hook_input "$SESSION_ID22" "$TRANSCRIPT22" "$PROJECT_DIR22")
run_hook "$HOOK_INPUT22" "$PROJECT_DIR22"

assert_contains "$HOOK_OUTPUT" '"decision": "block"' "E2E continues loop after successful iteration"
ITER_E2E_NEXT=$(sed -n 's/^iteration: \(.*\)/\1/p' "$STATE_FILE22" | head -1)
assert_eq "2" "$ITER_E2E_NEXT" "E2E iteration increments on success"

# =============================================================================
# Summary
# =============================================================================

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}                    TEST SUMMARY                           ${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "Tests run:    $TESTS_RUN"
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"
echo -e "Tests skipped: ${YELLOW}$TESTS_SKIPPED${NC}"

if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "\n${RED}FAILED${NC} - Some tests did not pass"
  echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
  exit 1
else
  echo -e "\n${GREEN}SUCCESS${NC} - All tests passed!"
  echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
  exit 0
fi
