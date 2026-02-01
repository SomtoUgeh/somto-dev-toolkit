#!/bin/bash

# E2E Test Loop Setup Script
# Creates state file for 2-phase E2E workflow with Dex tracking

set -euo pipefail

# Source shared helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/loop-helpers.sh
source "$SCRIPT_DIR/lib/loop-helpers.sh"

# Defaults
CUSTOM_PROMPT_PARTS=()

show_help() {
  cat << 'HELP_EOF'
E2E Test Loop - Playwright test development with Dex task tracking

USAGE:
  /e2e [OPTIONS] [CUSTOM PROMPT...]

OPTIONS:
  -h, --help    Show this help message

CUSTOM PROMPT:
  Optional positional arguments to customize the task:
    /e2e focus on auth flows
    /e2e review existing tests and refactor

DESCRIPTION:
  Two-phase workflow:
  Phase 1: Analyze user flows that need E2E coverage
  Phase 2: Create Dex epic and tasks for each flow

  Then use /complete <task-id> for each E2E test task.

FILE NAMING:
  *.e2e.page.ts - Page objects (locators, setup, actions)
  *.e2e.ts      - Test files (concise tests using page objects)

STOPPING:
  - /cancel-e2e
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

detect_playwright() {
  if [[ -f "playwright.config.ts" ]] || [[ -f "playwright.config.js" ]]; then
    return 0
  fi
  if [[ -f "package.json" ]] && grep -q '"@playwright/test"' package.json 2>/dev/null; then
    return 0
  fi
  return 1
}

detect_e2e_folder() {
  for folder in "e2e" "tests/e2e" "test/e2e" "tests" "__tests__/e2e"; do
    if [[ -d "$folder" ]]; then
      echo "$folder"
      return
    fi
  done
  echo "e2e"
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      show_help
      exit 0
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

# Detect package manager
PM=$(detect_package_manager)

# Check for Playwright
if ! detect_playwright; then
  echo "Warning: No playwright.config.ts/js found." >&2
  echo "Make sure Playwright is installed" >&2
fi

# Set test command
TEST_COMMAND="npx playwright test"

# Detect E2E folder
E2E_FOLDER=$(detect_e2e_folder)

# Create .claude directory if needed
mkdir -p .claude

# Read session_id
SESSION_ID=$(cat .claude/.current_session 2>/dev/null || echo "default")

# Branch setup - prompt user if on main/master
prompt_feature_branch "test/e2e-coverage"

# Create state file for hook routing
STATE_FILE=".claude/e2e-loop-${SESSION_ID}.local.md"
cat > "$STATE_FILE" <<EOF
---
loop_type: "e2e"
active: true
current_phase: "1"
test_command: "$TEST_COMMAND"
e2e_folder: "$E2E_FOLDER"
custom_prompt: "$CUSTOM_PROMPT"
working_branch: "$WORKING_BRANCH"
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---

# E2E Test Development Loop

**Phase:** 1 - Flow Analysis
**Test command:** \`$TEST_COMMAND\`
**E2E folder:** \`$E2E_FOLDER/\`
$(if [[ -n "$CUSTOM_PROMPT" ]]; then echo -e "\n## Custom Instructions\n\n$CUSTOM_PROMPT"; fi)

## Phase 1: Flow Analysis

1. Analyze application routes, features, user journeys
2. Identify critical flows needing E2E coverage
3. Prioritize 3-7 test tasks
4. Output: \`<phase_complete phase="1"/>\`

## Phase 2: Dex Handoff

Create Dex epic, then tasks for each flow.
Use /complete <task-id> for each E2E test.

## File Naming

- \`*.e2e.page.ts\` - Page objects
- \`*.e2e.ts\` - Test files
EOF

# Output setup message
cat <<EOF
E2E test loop activated!

Phase: 1 - Flow Analysis
Test command: $TEST_COMMAND
E2E folder: $E2E_FOLDER/
$(if [[ -n "$CUSTOM_PROMPT" ]]; then echo "Custom: $CUSTOM_PROMPT"; fi)

Workflow:
1. Phase 1: Analyze user flows
2. Phase 2: Create Dex tasks
3. Use /complete for each task

To cancel: /cancel-e2e
EOF
