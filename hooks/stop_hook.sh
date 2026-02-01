#!/bin/bash

# =============================================================================
# UNIFIED STOP HOOK - Architecture Overview
# =============================================================================
#
# PURPOSE: Intercepts session exit to enforce iterative workflows (loops).
#          When a loop is active, blocks exit and feeds prompts back to Claude.
#
# SUPPORTED LOOPS (all use 2-4 phase workflows):
#   - ut:  Unit test coverage (2 phases: Analysis → Dex Handoff)
#   - e2e: Playwright E2E tests (2 phases: Flow Analysis → Dex Handoff)
#   - prd: PRD generation (4 phases: Classification → Interview → Spec → Dex)
#
# CONTROL FLOW:
#   1. GUARDS: Check for recursion, validate session_id, find active loop
#   2. PARSE:  Read state file frontmatter (YAML between first two ---)
#   3. OUTPUT: Parse Claude's last output for structured markers
#   4. ROUTE:  Branch to loop-specific logic with phase transitions
#   5. BLOCK:  Output JSON to block exit and inject next prompt
#
# STATE FILES: .claude/{ut,e2e,prd}-loop-{session_id}.local.md
#   Format: YAML frontmatter (---...---) + markdown body (prompt)
#   Key fields: current_phase, feature_name, spec_path, etc.
#
# STRUCTURED OUTPUT MARKERS (parsed from Claude's response):
#   - <phase_complete phase="N" .../> - Phase transitions
#   - <promise>TEXT</promise> - Loop completion signal
#
# =============================================================================

set -euo pipefail

# Force byte-wise locale to avoid macOS "Illegal byte sequence" in tr/sed on non-UTF8 bytes.
export LC_ALL=C
export LANG=C

# =============================================================================
# Cross-platform helper functions (macOS/Linux/Windows Git Bash)
# =============================================================================

# Portable regex extraction using BASH_REMATCH (no grep -P needed)
extract_regex() {
  local string="$1"
  local pattern="$2"
  if [[ $string =~ $pattern ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
  return 0
}

# Returns LAST match's capture group
extract_regex_last() {
  local string="$1"
  local pattern="$2"
  local last_match=""
  local full_match=""

  local remaining="$string"
  while [[ $remaining =~ $pattern ]]; do
    full_match="${BASH_REMATCH[0]}"
    if [[ ${#BASH_REMATCH[@]} -gt 1 ]] && [[ -n "${BASH_REMATCH[1]+x}" ]]; then
      last_match="${BASH_REMATCH[1]}"
    else
      last_match="$full_match"
    fi

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
  normalized=$(printf '%s' "$text" | LC_ALL=C tr '\r\n' ' ')
  normalized=$(printf '%s' "$normalized" | sed 's/[[:space:]]\+/ /g')
  local promise
  promise=$(extract_regex_last "$normalized" '<promise>([^<]*)</promise>')
  promise="${promise#"${promise%%[![:space:]]*}"}"
  promise="${promise%"${promise##*[![:space:]]}"}"
  printf '%s' "$promise"
  return 0
}

# Escape special characters for sed replacement string
escape_sed_replacement() {
  local str="$1"
  str="${str//\\/\\\\}"
  str="${str//\//\\/}"
  str="${str//&/\\&}"
  str="${str//|/\\|}"
  str="${str//$'\n'/\\n}"
  printf '%s' "$str"
}

# Portable sed in-place edit
sed_inplace() {
  local expr="$1"
  local file="$2"
  local temp_file="/tmp/sed_inplace_$$.tmp"
  sed "$expr" "$file" > "$temp_file" || { rm -f "$temp_file"; return 1; }
  mv "$temp_file" "$file" 2>/dev/null || { cp "$temp_file" "$file" && rm -f "$temp_file"; }
}

# Write state file atomically
write_state_file() {
  local state_file="$1"
  local content="$2"
  local temp_file="/tmp/write_state_$$.tmp"

  printf '%s\n' "$content" > "$temp_file"
  mv "$temp_file" "$state_file" 2>/dev/null || { cp "$temp_file" "$state_file" && rm -f "$temp_file"; }
}

# Send desktop notification on loop completion
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

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Validate JSON input
if [[ -z "$HOOK_INPUT" ]]; then
  exit 0
fi

if ! echo "$HOOK_INPUT" | jq empty 2>/dev/null; then
  echo "Error: Hook input is not valid JSON" >&2
  exit 0
fi

# =============================================================================
# GUARD 1: Check stop_hook_active (prevents infinite loops)
# =============================================================================
STOP_HOOK_ACTIVE=$(echo "$HOOK_INPUT" | jq -r '.stop_hook_active // false')

if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
  exit 0
fi

# =============================================================================
# GUARD 2: Check which loop is active
# =============================================================================
SESSION_ID=$(echo "$HOOK_INPUT" | jq -r '.session_id // "default"')

if [[ ! "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
  echo "Error: Invalid session_id format" >&2
  exit 0
fi

UT_STATE=".claude/ut-loop-${SESSION_ID}.local.md"
E2E_STATE=".claude/e2e-loop-${SESSION_ID}.local.md"
PRD_STATE=".claude/prd-loop-${SESSION_ID}.local.md"

# Session indexing for qmd
index_session_for_qmd() {
  [[ -f "$UT_STATE" || -f "$E2E_STATE" || -f "$PRD_STATE" ]] && return 0
  command -v qmd &>/dev/null || return 0

  local project_path
  project_path=$(echo "$HOOK_INPUT" | jq -r '.cwd // ""')
  [[ -z "$project_path" ]] && return 0

  local project_dir_name="-$(echo "$project_path" | LC_ALL=C tr '/' '-')"
  local session_file="$HOME/.claude/projects/$project_dir_name/${SESSION_ID}.jsonl"
  [[ -f "$session_file" ]] || return 0

  (
    sleep 2
    CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$0")")}"
    "$CLAUDE_PLUGIN_ROOT/scripts/sync-sessions-to-qmd.sh" \
      --single "$session_file" "$SESSION_ID" "$project_path" 2>/dev/null
  ) &
  disown
}
trap index_session_for_qmd EXIT

ACTIVE_LOOP=""
STATE_FILE=""

if [[ -f "$UT_STATE" ]]; then
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
  exit 0
fi

# =============================================================================
# Parse state file frontmatter
# =============================================================================
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

get_field() {
  local frontmatter="$1"
  local field="$2"
  echo "$frontmatter" | grep "^${field}:" | head -1 | sed "s/${field}: *//" | LC_ALL=C tr -d '"' || true
}

# Validate state file fields
validate_state_file() {
  local frontmatter="$1"
  local expected_loop="$2"

  local loop_type
  loop_type=$(get_field "$frontmatter" "loop_type")

  if [[ -z "$loop_type" ]]; then
    echo "Error: State file missing 'loop_type' field." >&2
    return 1
  fi

  if [[ "$loop_type" != "$expected_loop" ]]; then
    echo "Error: State file loop_type '$loop_type' doesn't match detected loop '$expected_loop'" >&2
    return 1
  fi

  local phase
  phase=$(get_field "$frontmatter" "current_phase")
  if [[ -z "$phase" ]]; then
    echo "Error: State file missing 'current_phase' field" >&2
    return 1
  fi

  return 0
}

# Parse frontmatter with error handling
if ! FRONTMATTER=$(parse_frontmatter "$STATE_FILE"); then
  jq -n --arg msg "Loop ($ACTIVE_LOOP): State file has invalid frontmatter. Delete $STATE_FILE to reset." \
    '{"decision": "block", "reason": "State file corrupted", "systemMessage": $msg}'
  exit 0
fi

if ! validate_state_file "$FRONTMATTER" "$ACTIVE_LOOP"; then
  rm "$STATE_FILE"
  jq -n '{"decision": "allow"}'
  exit 0
fi

# =============================================================================
# Get transcript and check for completion
# =============================================================================
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path')

LAST_OUTPUT=""
if [[ -f "$TRANSCRIPT_PATH" ]] && grep -Eq '"role"[[:space:]]*:[[:space:]]*"assistant"' "$TRANSCRIPT_PATH" 2>/dev/null; then
  LAST_LINE=$(grep -E '"role"[[:space:]]*:[[:space:]]*"assistant"' "$TRANSCRIPT_PATH" | tail -1)
  if [[ -n "$LAST_LINE" ]]; then
    set +e
    JQ_RESULT=$(printf '%s' "$LAST_LINE" | jq -r '
      .message.content |
      map(select(.type == "text")) |
      map(.text) |
      join("\n")
    ' 2>&1)
    JQ_EXIT=$?
    set -e
    if [[ $JQ_EXIT -eq 0 ]]; then
      LAST_OUTPUT="$JQ_RESULT"
    fi
  fi
fi

# =============================================================================
# Common phase handling for all loops
# =============================================================================
CURRENT_PHASE=$(get_field "$FRONTMATTER" "current_phase")
PHASE_ITERATION=$(get_field "$FRONTMATTER" "phase_iteration")
[[ ! "$PHASE_ITERATION" =~ ^[0-9]+$ ]] && PHASE_ITERATION=0

# Parse structured output markers
PHASE_COMPLETE=""
if [[ -n "$LAST_OUTPUT" ]]; then
  PHASE_COMPLETE=$(extract_regex_last "$LAST_OUTPUT" '<phase_complete phase="([^"]+)"')
fi

# Get max phase for this loop type
get_max_phase() {
  case "$1" in
    ut|e2e) echo "2" ;;
    prd) echo "4" ;;
    *) echo "2" ;;
  esac
}

MAX_PHASE=$(get_max_phase "$ACTIVE_LOOP")

# =============================================================================
# Check for completion promises
# =============================================================================
if [[ -n "$LAST_OUTPUT" ]]; then
  PROMISE_TEXT=$(extract_promise_last "$LAST_OUTPUT")

  case "$ACTIVE_LOOP" in
    prd)
      if [[ "$PROMISE_TEXT" == "PRD COMPLETE" ]]; then
        FEATURE_NAME=$(get_field "$FRONTMATTER" "feature_name")
        echo "Loop (prd): Detected <promise>PRD COMPLETE</promise>"
        echo "   Feature '$FEATURE_NAME' PRD workflow complete!"
        notify "Loop (prd)" "PRD complete for $FEATURE_NAME!"
        rm "$STATE_FILE"
        exit 0
      fi
      ;;
    ut)
      if [[ "$PROMISE_TEXT" == "UT SETUP COMPLETE" ]]; then
        echo "Loop (ut): Detected <promise>UT SETUP COMPLETE</promise>"
        echo "   Coverage tasks created in Dex. Use /complete for each task."
        notify "Loop (ut)" "Coverage analysis complete!"
        rm "$STATE_FILE"
        exit 0
      fi
      ;;
    e2e)
      if [[ "$PROMISE_TEXT" == "E2E SETUP COMPLETE" ]]; then
        echo "Loop (e2e): Detected <promise>E2E SETUP COMPLETE</promise>"
        echo "   E2E tasks created in Dex. Use /complete for each task."
        notify "Loop (e2e)" "Flow analysis complete!"
        rm "$STATE_FILE"
        exit 0
      fi
      ;;
  esac
fi

# =============================================================================
# Generate phase-specific prompts
# =============================================================================
generate_phase_prompt() {
  local loop_type="$1"
  local phase="$2"
  local prompt=""

  case "$loop_type" in
    ut)
      case "$phase" in
        "1")
          TARGET_COVERAGE=$(get_field "$FRONTMATTER" "target_coverage")
          TEST_COMMAND=$(get_field "$FRONTMATTER" "test_command")
          CUSTOM_PROMPT=$(get_field "$FRONTMATTER" "custom_prompt")
          prompt="# UT Loop: Phase 1 - Coverage Analysis

**Target:** $(if [[ -n "$TARGET_COVERAGE" ]] && [[ "$TARGET_COVERAGE" != "0" ]]; then echo "${TARGET_COVERAGE}%"; else echo "analyze and prioritize"; fi)
**Coverage command:** \`$TEST_COMMAND\`
$(if [[ -n "$CUSTOM_PROMPT" ]]; then echo -e "\n**Custom:** $CUSTOM_PROMPT"; fi)

## Your Task

1. Run \`$TEST_COMMAND\` to see current coverage
2. Identify files with low coverage
3. Prioritize 3-7 test tasks for user-facing behavior

**Output:** \`<phase_complete phase=\"1\"/>\`"
          ;;
        "2")
          TARGET_COVERAGE=$(get_field "$FRONTMATTER" "target_coverage")
          prompt="# UT Loop: Phase 2 - Dex Handoff

## Your Task

Create Dex epic and tasks for each coverage gap.

1. Create epic:
\`\`\`bash
dex create \"Unit Test Coverage\" --description \"Target: ${TARGET_COVERAGE:-N}% coverage

Current: X%
Goal: Y%\"
\`\`\`

2. For each gap, create a task:
\`\`\`bash
dex create \"Test: [specific behavior]\" --parent <epic-id> --description \"
File: path/to/file.ts
Current coverage: X%

Test should verify:
- [ ] Specific behavior
- [ ] Edge case
\"
\`\`\`

3. Confirm: \`dex list\`

4. Use AskUserQuestion:
   - \"Start first task\" - Begin implementation
   - \"Done\" - Review tasks first

**Output:** \`<phase_complete phase=\"2\"/>\` or \`<promise>UT SETUP COMPLETE</promise>\`"
          ;;
      esac
      ;;

    e2e)
      case "$phase" in
        "1")
          E2E_FOLDER=$(get_field "$FRONTMATTER" "e2e_folder")
          CUSTOM_PROMPT=$(get_field "$FRONTMATTER" "custom_prompt")
          prompt="# E2E Loop: Phase 1 - Flow Analysis

**E2E folder:** \`$E2E_FOLDER/\`
$(if [[ -n "$CUSTOM_PROMPT" ]]; then echo -e "\n**Custom:** $CUSTOM_PROMPT"; fi)

## Your Task

1. Analyze application routes, features, user journeys
2. Identify critical flows needing E2E coverage
3. Prioritize 3-7 test tasks

Focus on:
- Happy paths users depend on
- Payment/auth/data submission flows
- Flows that broke in production

**Output:** \`<phase_complete phase=\"1\"/>\`"
          ;;
        "2")
          prompt="# E2E Loop: Phase 2 - Dex Handoff

## Your Task

Create Dex epic and tasks for each flow.

1. Create epic:
\`\`\`bash
dex create \"E2E Test Coverage\" --description \"Critical user flow coverage

Flows to cover:
- Flow 1
- Flow 2
\"
\`\`\`

2. For each flow, create a task:
\`\`\`bash
dex create \"E2E: [flow name]\" --parent <epic-id> --description \"
Flow: [user journey]

Steps:
1. User does X
2. System shows Y

Files:
- e2e/[flow].e2e.page.ts
- e2e/[flow].e2e.ts

Acceptance:
- [ ] Page object with semantic locators
- [ ] Test covers happy path
\"
\`\`\`

3. Confirm: \`dex list\`

4. Use AskUserQuestion:
   - \"Start first task\" - Begin implementation
   - \"Done\" - Review tasks first

**Output:** \`<phase_complete phase=\"2\"/>\` or \`<promise>E2E SETUP COMPLETE</promise>\`"
          ;;
      esac
      ;;

    prd)
      FEATURE_NAME=$(get_field "$FRONTMATTER" "feature_name")
      INPUT_TYPE=$(get_field "$FRONTMATTER" "input_type")
      INPUT_RAW=$(get_field "$FRONTMATTER" "input_raw")
      SPEC_PATH=$(get_field "$FRONTMATTER" "spec_path")

      case "$phase" in
        "1")
          prompt="# PRD Loop: Phase 1 - Input Classification

**Input type:** $INPUT_TYPE
**Raw input:** $INPUT_RAW

Classify input and extract feature context.

**Output:** \`<phase_complete phase=\"1\" feature_name=\"SLUG\"/>\`"
          ;;
        "2")
          prompt="# PRD Loop: Phase 2 - Interview + Exploration

**Feature:** $FEATURE_NAME

## Your Task

Conduct thorough interview (8-10+ questions) covering:
- Core problem, success criteria, MVP scope
- Technical systems, data models, existing patterns
- UX/UI flows, error states, edge cases
- Tradeoffs, compromises, priorities

### After Interview Complete, Run Agents (blocking)

Spawn ALL agents IN PARALLEL (single message, multiple Task calls):

**Research Agents:**
\`\`\`
Task 1: subagent_type=\"somto-dev-toolkit:prd-codebase-researcher\" (max_turns: 30)
Task 2: subagent_type=\"compound-engineering:research:git-history-analyzer\" (max_turns: 30)
Task 3: subagent_type=\"somto-dev-toolkit:prd-external-researcher\" (max_turns: 15)
\`\`\`

**Expert Agents:**
\`\`\`
Task 4: subagent_type=\"compound-engineering:review:architecture-strategist\" (max_turns: 20)
Task 5: subagent_type=\"compound-engineering:review:security-sentinel\" (max_turns: 20)
Task 6: subagent_type=\"compound-engineering:workflow:spec-flow-analyzer\" (max_turns: 20)
Task 7: subagent_type=\"compound-engineering:review:pattern-recognition-specialist\" (max_turns: 20)
\`\`\`

### Review Findings

Summarize key findings. Ask 1-2 clarifying questions if gaps revealed.

**Output:** \`<phase_complete phase=\"2\"/>\`"
          ;;
        "3")
          prompt="# PRD Loop: Phase 3 - Write Spec

**Feature:** $FEATURE_NAME

## Your Task

Write comprehensive spec to \`plans/$FEATURE_NAME/spec.md\`.

Include a structured **Implementation Stories** section for Dex parsing:

\`\`\`markdown
## Implementation Stories

### Story 1: <Title>
**Category:** functional|ui|integration|edge-case|performance
**Skills:** <skill-name>, <skill-name>
**Blocked by:** none
**Acceptance Criteria:**
- [ ] Criterion 1
- [ ] Criterion 2
\`\`\`

**Story Size Rules:**
- Max 7 acceptance criteria
- Max 3 files touched
- No \"and\" in title
- Independently testable

**Output:** \`<phase_complete phase=\"3\" spec_path=\"plans/$FEATURE_NAME/spec.md\"/>\`"
          ;;
        "4")
          prompt="# PRD Loop: Phase 4 - Dex Handoff

**Feature:** $FEATURE_NAME
**Spec:** \`$SPEC_PATH\`

## Your Task

Use \`dex plan\` to create tasks from the spec's Implementation Stories section.

1. Create tasks from spec:
\`\`\`bash
dex plan $SPEC_PATH
\`\`\`

This automatically creates parent task and subtasks from the spec structure.

2. Verify tasks:
\`\`\`bash
dex status
dex list
\`\`\`

3. Use AskUserQuestion with options:
   - \"Start first task\" - Begin implementation
   - \"Done\" - Review PRD first

**Output:** \`<phase_complete phase=\"4\"/>\` or \`<promise>PRD COMPLETE</promise>\`"
          ;;
      esac
      ;;
  esac

  echo "$prompt"
}

# =============================================================================
# Handle phase transitions
# =============================================================================
NEXT_PHASE=""
SYSTEM_MSG=""

# Check if marker matches current phase
if [[ -n "$PHASE_COMPLETE" ]] && [[ "$PHASE_COMPLETE" == "$CURRENT_PHASE" ]]; then
  # Calculate next phase
  NEXT_PHASE=$((CURRENT_PHASE + 1))

  # Check if we've completed all phases
  if [[ $NEXT_PHASE -gt $MAX_PHASE ]]; then
    echo "Loop ($ACTIVE_LOOP): All phases complete!"
    case "$ACTIVE_LOOP" in
      prd)
        FEATURE_NAME=$(get_field "$FRONTMATTER" "feature_name")
        notify "Loop (prd)" "PRD complete for $FEATURE_NAME!"
        ;;
      ut)
        notify "Loop (ut)" "Coverage analysis complete!"
        ;;
      e2e)
        notify "Loop (e2e)" "Flow analysis complete!"
        ;;
    esac
    rm "$STATE_FILE"
    exit 0
  fi

  SYSTEM_MSG="Loop ($ACTIVE_LOOP): Phase $CURRENT_PHASE complete! Advancing to phase $NEXT_PHASE."

  # Handle PRD-specific phase 1 feature name extraction
  if [[ "$ACTIVE_LOOP" == "prd" ]] && [[ "$CURRENT_PHASE" == "1" ]]; then
    PHASE_FEATURE=$(extract_regex_last "$LAST_OUTPUT" '<phase_complete[^>]*feature_name="([^"]+)"')
    if [[ -n "$PHASE_FEATURE" ]]; then
      ESCAPED_FEATURE=$(escape_sed_replacement "$PHASE_FEATURE")
      sed_inplace "s/^feature_name: .*/feature_name: \"$ESCAPED_FEATURE\"/" "$STATE_FILE"
    fi
  fi

  # Handle PRD-specific phase 3 spec_path extraction
  if [[ "$ACTIVE_LOOP" == "prd" ]] && [[ "$CURRENT_PHASE" == "3" ]]; then
    MARKER_SPEC=$(extract_regex_last "$LAST_OUTPUT" '<phase_complete[^>]*spec_path="([^"]+)"')
    if [[ -n "$MARKER_SPEC" ]]; then
      ESCAPED_PATH=$(escape_sed_replacement "$MARKER_SPEC")
      sed_inplace "s|^spec_path: .*|spec_path: \"$ESCAPED_PATH\"|" "$STATE_FILE"
    fi
  fi
fi

# Fallback: Auto-advance based on file existence (PRD phase 3 only)
if [[ -z "$NEXT_PHASE" ]] && [[ "$ACTIVE_LOOP" == "prd" ]] && [[ "$CURRENT_PHASE" == "3" ]]; then
  FEATURE_NAME=$(get_field "$FRONTMATTER" "feature_name")
  EXPECTED_SPEC="plans/$FEATURE_NAME/spec.md"

  if [[ -f "$EXPECTED_SPEC" ]] && grep -q "## Implementation Stories" "$EXPECTED_SPEC" 2>/dev/null; then
    echo "Loop (prd): Spec detected with stories section. Auto-advancing to phase 4." >&2
    NEXT_PHASE="4"
    ESCAPED_PATH=$(escape_sed_replacement "$EXPECTED_SPEC")
    sed_inplace "s|^spec_path: .*|spec_path: \"$ESCAPED_PATH\"|" "$STATE_FILE"
    SYSTEM_MSG="Loop (prd): Auto-advanced 3->4 (spec exists with stories)"
  fi
fi

# No valid transition - continue in current phase
if [[ -z "$NEXT_PHASE" ]]; then
  PHASE_ITERATION=$((PHASE_ITERATION + 1))

  if grep -q '^phase_iteration:' "$STATE_FILE"; then
    sed_inplace "s/^phase_iteration: .*/phase_iteration: $PHASE_ITERATION/" "$STATE_FILE"
  else
    sed_inplace "2i\\
phase_iteration: $PHASE_ITERATION" "$STATE_FILE"
  fi

  if [[ $PHASE_ITERATION -eq 1 ]]; then
    SYSTEM_MSG="Loop ($ACTIVE_LOOP): Phase $CURRENT_PHASE - continuing"
  else
    SYSTEM_MSG="Loop ($ACTIVE_LOOP): Phase $CURRENT_PHASE iteration $PHASE_ITERATION"
  fi

  PROMPT_TEXT=$(generate_phase_prompt "$ACTIVE_LOOP" "$CURRENT_PHASE")
  jq -n --arg prompt "$PROMPT_TEXT" --arg msg "$SYSTEM_MSG" '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
  exit 0
fi

# Update state file with new phase
sed_inplace "s/^current_phase: .*/current_phase: \"$NEXT_PHASE\"/" "$STATE_FILE"
sed_inplace "s/^phase_iteration: .*/phase_iteration: 0/" "$STATE_FILE"

PROMPT_TEXT=$(generate_phase_prompt "$ACTIVE_LOOP" "$NEXT_PHASE")

# Update state file body
FRONTMATTER_END=$(grep -n '^---$' "$STATE_FILE" 2>/dev/null | head -2 | tail -1 | cut -d: -f1 || true)
if [[ -z "$FRONTMATTER_END" ]] || [[ ! "$FRONTMATTER_END" =~ ^[0-9]+$ ]]; then
  rm "$STATE_FILE"
  exit 0
fi
HEAD_CONTENT=$(head -n "$FRONTMATTER_END" "$STATE_FILE")
write_state_file "$STATE_FILE" "$HEAD_CONTENT

$PROMPT_TEXT"

jq -n --arg prompt "$PROMPT_TEXT" --arg msg "$SYSTEM_MSG" '{"decision": "block", "reason": $prompt, "systemMessage": $msg}'
exit 0
