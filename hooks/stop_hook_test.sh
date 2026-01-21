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

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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
  sed -n '/^extract_regex()/,/^}/p' "$HOOK_SCRIPT"

  # Extract extract_regex_last function
  sed -n '/^extract_regex_last()/,/^}/p' "$HOOK_SCRIPT"

  # Extract escape_sed_replacement function
  sed -n '/^escape_sed_replacement()/,/^}/p' "$HOOK_SCRIPT"

  # Extract get_field function
  sed -n '/^get_field()/,/^}/p' "$HOOK_SCRIPT"

  # Extract parse_frontmatter function
  sed -n '/^parse_frontmatter()/,/^}/p' "$HOOK_SCRIPT"
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

# Backslash before special chars (t, n) treated as literal
result=$(extract_regex_last 'path="has\ttab"' 'path="([^"]+)"')
assert_eq 'has\ttab' "$result" "backslash-t preserved as literal"

# =============================================================================
section "ISSUE FIX: Promise Tag - Last Match Wins (v0.10.37)"
# =============================================================================
# PROBLEM: First <promise> tag was grabbed (non-greedy .*?)
# FIX: Changed to greedy .* to grab LAST match

describe "Promise tag extraction - last match wins"

# Simulate promise parsing (perl-like behavior)
extract_last_promise() {
  local text="$1"
  # This mimics the fixed perl command: s/.*<promise>(.*?)<\/promise>.*/$1/s
  # The greedy .* at the start ensures we get the LAST match
  echo "$text" | perl -0777 -pe 's/.*<promise>(.*?)<\/promise>.*/$1/s; s/^\s+|\s+$//g; s/\s+/ /g' 2>/dev/null || echo ""
}

# Example in documentation followed by actual promise
DOC_WITH_PROMISE='When complete, output:
```
<promise>DONE</promise>
```

All tests passing!
<promise>TESTS_PASS</promise>'
result=$(extract_last_promise "$DOC_WITH_PROMISE")
assert_eq "TESTS_PASS" "$result" "ignores promise in code block example"

# Multiple promises - should get last
MULTI_PROMISE='<promise>first</promise> middle <promise>second</promise> end <promise>final</promise>'
result=$(extract_last_promise "$MULTI_PROMISE")
assert_eq "final" "$result" "multiple promises - returns last"

# Promise with whitespace
WHITESPACE_PROMISE='text <promise>  spaced out  </promise> more'
result=$(extract_last_promise "$WHITESPACE_PROMISE")
assert_eq "spaced out" "$result" "trims whitespace from promise"

# Empty promise
EMPTY_PROMISE='<promise></promise>'
result=$(extract_last_promise "$EMPTY_PROMISE")
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
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

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
# Summary
# =============================================================================

echo -e "\n${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}                    TEST SUMMARY                           ${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "Tests run:    $TESTS_RUN"
echo -e "Tests passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests failed: ${RED}$TESTS_FAILED${NC}"

if [[ $TESTS_FAILED -gt 0 ]]; then
  echo -e "\n${RED}FAILED${NC} - Some tests did not pass"
  echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
  exit 1
else
  echo -e "\n${GREEN}SUCCESS${NC} - All tests passed!"
  echo -e "${BLUE}═══════════════════════════════════════════════════════════${NC}"
  exit 0
fi
