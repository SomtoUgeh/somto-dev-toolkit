#!/bin/bash

# Unit Test Loop Setup Script
# Creates state file for 2-phase unit test workflow with Dex tracking

set -euo pipefail

# Source shared helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/loop-helpers.sh
source "$SCRIPT_DIR/lib/loop-helpers.sh"

# Defaults
TARGET_COVERAGE=0
CUSTOM_PROMPT_PARTS=()

show_help() {
  cat << 'HELP_EOF'
Unit Test Loop - Coverage improvement with Dex task tracking

USAGE:
  /ut [OPTIONS] [CUSTOM PROMPT...]

OPTIONS:
  --target <N%>     Target coverage percentage
  -h, --help        Show this help message

CUSTOM PROMPT:
  Optional positional arguments to customize the task:
    /ut focus on error handling paths --target 80%
    /ut refactor existing tests to follow AAA pattern

DESCRIPTION:
  Two-phase workflow:
  Phase 1: Analyze coverage gaps, prioritize files to test
  Phase 2: Create Dex epic and tasks for each gap

  Then use /complete <task-id> for each test task.

EXAMPLES:
  /ut --target 80%
  /ut focus on auth module --target 90%

STOPPING:
  - /cancel-ut
HELP_EOF
}

detect_package_manager() {
  if [[ -f "pnpm-lock.yaml" ]]; then
    echo "pnpm"
  elif [[ -f "bun.lockb" ]]; then
    echo "bun"
  elif [[ -f "yarn.lock" ]]; then
    echo "yarn"
  else
    echo "npm"
  fi
}

detect_coverage_tool() {
  local pm
  pm=$(detect_package_manager)

  # Check for vitest config
  if [[ -f "vitest.config.ts" ]] || [[ -f "vitest.config.js" ]] || [[ -f "vitest.config.mts" ]]; then
    echo "vitest run --coverage"
    return
  fi

  # Check for jest config
  if [[ -f "jest.config.js" ]] || [[ -f "jest.config.ts" ]] || [[ -f "jest.config.mjs" ]]; then
    echo "jest --coverage"
    return
  fi

  # Check package.json for coverage tools or scripts
  if [[ -f "package.json" ]]; then
    if grep -q '"c8"' package.json 2>/dev/null; then
      echo "npx c8 ${pm} test"
      return
    fi
    if grep -q '"nyc"' package.json 2>/dev/null; then
      echo "npx nyc ${pm} test"
      return
    fi
    if grep -q '"coverage"' package.json 2>/dev/null; then
      echo "${pm} run coverage"
      return
    fi
    if grep -q '"test:coverage"' package.json 2>/dev/null; then
      echo "${pm} run test:coverage"
      return
    fi
  fi

  echo ""
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      show_help
      exit 0
      ;;
    --target)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --target requires a percentage argument" >&2
        exit 1
      fi
      TARGET_COVERAGE="${2%\%}"
      if ! [[ "$TARGET_COVERAGE" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        echo "Error: --target must be a number, got: $2" >&2
        exit 1
      fi
      shift 2
      ;;
    -*)
      echo "Error: Unknown option: $1" >&2
      echo "Use --help for usage information" >&2
      exit 1
      ;;
    *)
      CUSTOM_PROMPT_PARTS+=("$1")
      shift
      ;;
  esac
done

CUSTOM_PROMPT="${CUSTOM_PROMPT_PARTS[*]:-}"

# Auto-detect test command
TEST_COMMAND=$(detect_coverage_tool)
if [[ -z "$TEST_COMMAND" ]]; then
  echo "Warning: Could not detect coverage tool" >&2
  echo "You may need to specify coverage command when running tests" >&2
  TEST_COMMAND="npm test -- --coverage"
fi

# Create .claude directory if needed
mkdir -p .claude

# Read session_id
SESSION_ID=$(cat .claude/.current_session 2>/dev/null || echo "default")

# Branch setup - prompt user if on main/master
prompt_feature_branch "test/unit-coverage"

# Create state file for hook routing
STATE_FILE=".claude/ut-loop-${SESSION_ID}.local.md"
cat > "$STATE_FILE" <<EOF
---
loop_type: "ut"
active: true
current_phase: "1"
target_coverage: $TARGET_COVERAGE
test_command: "$TEST_COMMAND"
custom_prompt: "$CUSTOM_PROMPT"
working_branch: "$WORKING_BRANCH"
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---

# Unit Test Coverage Loop

**Phase:** 1 - Coverage Analysis
**Target:** $(if awk "BEGIN {exit !($TARGET_COVERAGE > 0)}" 2>/dev/null; then echo "${TARGET_COVERAGE}%"; else echo "none (analyze and prioritize)"; fi)
**Coverage command:** \`$TEST_COMMAND\`
$(if [[ -n "$CUSTOM_PROMPT" ]]; then echo -e "\n## Custom Instructions\n\n$CUSTOM_PROMPT"; fi)

## Phase 1: Coverage Analysis

1. Run \`$TEST_COMMAND\` to see current state
2. Identify files with low coverage
3. Prioritize 3-7 test tasks for user-facing behavior
4. Output: \`<phase_complete phase="1"/>\`

## Phase 2: Dex Handoff

Create Dex epic with target, then tasks for each gap.
Use /complete <task-id> for each test.
EOF

# Output setup message
cat <<EOF
Unit test loop activated!

Phase: 1 - Coverage Analysis
Target: $(if awk "BEGIN {exit !($TARGET_COVERAGE > 0)}" 2>/dev/null; then echo "${TARGET_COVERAGE}%"; else echo "none"; fi)
Coverage command: $TEST_COMMAND
$(if [[ -n "$CUSTOM_PROMPT" ]]; then echo "Custom: $CUSTOM_PROMPT"; fi)

Workflow:
1. Phase 1: Analyze coverage gaps
2. Phase 2: Create Dex tasks
3. Use /complete for each task

To cancel: /cancel-ut
EOF
