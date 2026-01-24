#!/bin/bash

# Unit Test Loop Setup Script
# Creates state file for in-session unit test loop

set -euo pipefail

# Source shared helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/loop-helpers.sh
source "$SCRIPT_DIR/lib/loop-helpers.sh"

# Defaults
TARGET_COVERAGE=0
MAX_ITERATIONS=0
TEST_COMMAND=""
COMPLETION_PROMISE="COVERAGE COMPLETE"
CUSTOM_PROMPT_PARTS=()

show_help() {
  cat << 'HELP_EOF'
Unit Test Loop - Iterative unit test coverage improvement (Matt Pocock pattern)

USAGE:
  /ut [OPTIONS] [CUSTOM PROMPT...]

OPTIONS:
  --target <N%>                 Target coverage percentage (exits when reached)
  --max-iterations <n>          Maximum iterations before auto-stop (default: unlimited)
  --test-command '<cmd>'        Override auto-detected coverage command
  --completion-promise '<text>' Custom promise phrase (default: COVERAGE COMPLETE)
  -h, --help                    Show this help message

CUSTOM PROMPT:
  Optional positional arguments to customize the task. Multi-word works without quotes:
    /ut focus on error handling paths --target 80%
    /ut refactor existing tests to follow AAA pattern

DESCRIPTION:
  Starts a unit test coverage improvement loop. Each iteration:
  1. Runs coverage to find gaps
  2. Writes ONE meaningful test for user-facing behavior
  3. Commits with descriptive message
  4. Repeats until target or max iterations

  To signal completion, output: <promise>YOUR_PHRASE</promise>

EXAMPLES:
  /ut --target 80% --max-iterations 20
  /ut --test-command "bun test:coverage"
  /ut --completion-promise "ALL TESTS PASS" --max-iterations 10
  /ut rewrite tests to follow AAA pattern

AUTO-DETECTION:
  Detects coverage tool: vitest > jest > c8 > nyc > package.json script
  Detects package manager: pnpm > bun > yarn > npm

STOPPING:
  - Reach --target coverage percentage
  - Reach --max-iterations
  - Output <promise>COVERAGE COMPLETE</promise>
  - Run /cancel-ut
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
    # Check for c8 in devDependencies
    if grep -q '"c8"' package.json 2>/dev/null; then
      echo "npx c8 ${pm} test"
      return
    fi

    # Check for nyc in devDependencies
    if grep -q '"nyc"' package.json 2>/dev/null; then
      echo "npx nyc ${pm} test"
      return
    fi

    # Check for coverage script
    if grep -q '"coverage"' package.json 2>/dev/null; then
      echo "${pm} run coverage"
      return
    fi

    # Check for test:coverage script
    if grep -q '"test:coverage"' package.json 2>/dev/null; then
      echo "${pm} run test:coverage"
      return
    fi
  fi

  # No coverage tool detected
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
        echo "" >&2
        echo "  Valid examples:" >&2
        echo "    --target 80%" >&2
        echo "    --target 90" >&2
        echo "    --target 75.5%" >&2
        echo "" >&2
        echo "  You provided: --target (with no percentage)" >&2
        exit 1
      fi
      # Strip % if present
      TARGET_COVERAGE="${2%\%}"
      if ! [[ "$TARGET_COVERAGE" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        echo "Error: --target must be a number, got: $2" >&2
        echo "" >&2
        echo "  Valid examples:" >&2
        echo "    --target 80%" >&2
        echo "    --target 90" >&2
        echo "" >&2
        echo "  Invalid: text, negative numbers" >&2
        exit 1
      fi
      shift 2
      ;;
    --max-iterations)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --max-iterations requires a number argument" >&2
        echo "" >&2
        echo "  Valid examples:" >&2
        echo "    --max-iterations 10" >&2
        echo "    --max-iterations 50" >&2
        echo "    --max-iterations 100" >&2
        echo "" >&2
        echo "  You provided: --max-iterations (with no number)" >&2
        exit 1
      fi
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "Error: --max-iterations must be a positive integer, got: $2" >&2
        echo "" >&2
        echo "  Valid examples:" >&2
        echo "    --max-iterations 10" >&2
        echo "    --max-iterations 50" >&2
        echo "" >&2
        echo "  Invalid: decimals (10.5), negative numbers (-5), text" >&2
        exit 1
      fi
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    --test-command)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --test-command requires a command string" >&2
        echo "" >&2
        echo "  Valid examples:" >&2
        echo "    --test-command 'pnpm run coverage'" >&2
        echo "    --test-command 'bun test:coverage'" >&2
        echo "    --test-command 'npm run test -- --coverage'" >&2
        echo "" >&2
        echo "  You provided: --test-command (with no command)" >&2
        exit 1
      fi
      TEST_COMMAND="$2"
      shift 2
      ;;
    --completion-promise)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --completion-promise requires a text argument" >&2
        echo "" >&2
        echo "  Valid examples:" >&2
        echo "    --completion-promise 'DONE'" >&2
        echo "    --completion-promise 'COVERAGE COMPLETE'" >&2
        echo "    --completion-promise 'All tests passing'" >&2
        echo "" >&2
        echo "  You provided: --completion-promise (with no text)" >&2
        echo "" >&2
        echo "  Note: Multi-word promises must be quoted!" >&2
        exit 1
      fi
      COMPLETION_PROMISE="$2"
      shift 2
      ;;
    -*)
      echo "Error: Unknown option: $1" >&2
      echo "" >&2
      echo "  Valid options:" >&2
      echo "    --target <N%>               Target coverage percentage" >&2
      echo "    --max-iterations <n>        Safety limit" >&2
      echo "    --test-command '<cmd>'      Coverage command" >&2
      echo "    --completion-promise <text> Promise phrase" >&2
      echo "    -h, --help                  Show help" >&2
      echo "" >&2
      echo "  Use --help for full usage information" >&2
      exit 1
      ;;
    *)
      # Positional argument = custom prompt part
      CUSTOM_PROMPT_PARTS+=("$1")
      shift
      ;;
  esac
done

# Join all custom prompt parts with spaces
CUSTOM_PROMPT="${CUSTOM_PROMPT_PARTS[*]:-}"

# Auto-detect test command if not provided
if [[ -z "$TEST_COMMAND" ]]; then
  TEST_COMMAND=$(detect_coverage_tool)
  if [[ -z "$TEST_COMMAND" ]]; then
    echo "Error: Could not detect coverage tool" >&2
    echo "" >&2
    echo "  No vitest.config.*, jest.config.*, c8, nyc, or coverage script found." >&2
    echo "" >&2
    echo "  Please specify manually:" >&2
    echo "    /ut --test-command 'pnpm run coverage'" >&2
    echo "    /ut --test-command 'bun test:coverage'" >&2
    echo "    /ut --test-command 'npm run test -- --coverage'" >&2
    exit 1
  fi
fi

# Create .claude directory if needed
mkdir -p .claude

# Read session_id from SessionStart hook (with fallback for edge cases)
SESSION_ID=$(cat .claude/.current_session 2>/dev/null || echo "default")

# Branch setup - prompt user if on main/master
prompt_feature_branch "test/unit-coverage"

# Quote completion promise for YAML
COMPLETION_PROMISE_YAML="\"$COMPLETION_PROMISE\""

# Create state JSON file (single source of truth - no separate progress.txt)
STATE_JSON=".claude/ut-state-${SESSION_ID}.json"
cat > "$STATE_JSON" <<EOF
{
  "type": "ut",
  "target_coverage": $TARGET_COVERAGE,
  "test_command": "$TEST_COMMAND",
  "completion_promise": "$COMPLETION_PROMISE",
  "custom_prompt": "$CUSTOM_PROMPT",
  "max_iterations": $MAX_ITERATIONS,
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "task_list_synced": false,
  "file_tasks": {},
  "iterations": [],
  "log": [
    {"ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)", "event": "loop_started", "target_coverage": $TARGET_COVERAGE}
  ]
}
EOF

# Create minimal state file for hook routing (points to state.json)
STATE_FILE=".claude/ut-loop-${SESSION_ID}.local.md"
cat > "$STATE_FILE" <<EOF
---
loop_type: "ut"
active: true
state_json: "$STATE_JSON"
iteration: 1
max_iterations: $MAX_ITERATIONS
target_coverage: $TARGET_COVERAGE
test_command: "$TEST_COMMAND"
completion_promise: $COMPLETION_PROMISE_YAML
custom_prompt: "$CUSTOM_PROMPT"
working_branch: "$WORKING_BRANCH"
branch_setup_done: true
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
task_list_synced: false
file_tasks: '{}'
---

# Test Coverage Improvement Loop

**Coverage command:** \`$TEST_COMMAND\`
**Target:** $(if awk "BEGIN {exit !($TARGET_COVERAGE > 0)}" 2>/dev/null; then echo "${TARGET_COVERAGE}%"; else echo "none (use promise)"; fi)
**Max iterations:** $(if [[ $MAX_ITERATIONS -gt 0 ]]; then echo "$MAX_ITERATIONS"; else echo "unlimited"; fi)
$(if [[ -n "$CUSTOM_PROMPT" ]]; then echo -e "\n## Custom Instructions\n\n$CUSTOM_PROMPT"; fi)

## What Makes a Great Test

A great test covers behavior users depend on. It should:
- Test a feature that, if broken, would frustrate or block users
- Validate real workflows, not implementation details
- Catch regressions before users do
- Be resilient to refactoring

Do NOT write tests just to increase coverage numbers. Use coverage as a guide to find UNTESTED USER-FACING BEHAVIOR.

## FORBIDDEN

**Do NOT abuse \`/* v8 ignore */\` comments.** These should be rare exceptions, not a way to skip writing tests. Valid uses:
- Truly unreachable error branches (e.g., exhaustive switch default)
- Framework boilerplate you don't control
- Debug-only code paths

Invalid uses (write a test instead):
- "This is hard to test" - find a way
- "This is internal code" - internal code breaks too
- Anything user-facing or that could regress

**NEVER modify coverage config to exclude files/folders.** This is cheating. The goal is to write tests, not to game metrics by hiding untested code. If you find yourself wanting to exclude something, either:
1. Write a test for it
2. Use inline ignore comments for specific lines that genuinely don't need tests

## Test Colocation

**Tests should live next to the code they test:**
- \`src/utils/parse.ts\` → \`src/utils/parse.test.ts\`
- \`src/components/Button.tsx\` → \`src/components/Button.test.tsx\`
- Shared test utilities can live in \`src/test/\` or \`__tests__/helpers/\`

**Why colocation matters:**
- Easy to find tests for a file
- Tests get updated when code changes
- Dead code detection (no tests = suspicious)

## Code Style

- **MINIMAL COMMENTS** - code should be self-documenting
- Only add comments for non-obvious "why", never "what"
- Test names should describe the behavior being tested

## Process (ONE test per iteration)

1. Run \`$TEST_COMMAND\` to see which files have low coverage
2. Read the uncovered lines and identify the most important USER-FACING FEATURE that lacks tests
   - Prioritize: error handling users will hit, CLI commands, API endpoints, file parsing
   - Deprioritize: internal utilities, edge cases users won't encounter, boilerplate
3. Write ONE meaningful test that validates the feature works correctly for users
   - Place the test file next to the source file (colocation)
4. Run \`$TEST_COMMAND\` again - coverage should increase as a side effect of testing real behavior
5. **Lint & format** - run project's lint/format commands, fix any errors
6. Commit with message: \`test(<file>): <describe the user behavior being tested>\`
7. **Signal iteration complete** with structured output (see below)

## Iteration Complete Signal

After committing, output this marker so the hook can verify and advance:

\`\`\`
<iteration_complete test_file="path/to/file.test.ts"/>
\`\`\`

The hook will:
- Verify your commit exists
- Log to embedded state.json (don't touch it)
- Advance to next iteration

**Marker is optional** - hook auto-detects from git if test commit exists.

## Completion

ONLY WRITE ONE TEST PER ITERATION.

$(if awk "BEGIN {exit !($TARGET_COVERAGE > 0)}" 2>/dev/null; then echo "When coverage reaches ${TARGET_COVERAGE}% or higher, output:"; else echo "When you believe coverage is complete, output:"; fi)

\`\`\`
<promise>$COMPLETION_PROMISE</promise>
\`\`\`

CRITICAL: Only output this promise when coverage goal is genuinely achieved. Do not lie to exit the loop.
EOF

# Output setup message
cat <<EOF
Unit test loop activated!

Iteration: 1
Target: $(if awk "BEGIN {exit !($TARGET_COVERAGE > 0)}" 2>/dev/null; then echo "${TARGET_COVERAGE}%"; else echo "none"; fi)
Max iterations: $(if [[ $MAX_ITERATIONS -gt 0 ]]; then echo "$MAX_ITERATIONS"; else echo "unlimited"; fi)
Test command: $TEST_COMMAND
Completion promise: $COMPLETION_PROMISE
$(if [[ -n "$CUSTOM_PROMPT" ]]; then echo "Custom prompt: $CUSTOM_PROMPT"; fi)

The stop hook is now active. When you try to exit, the same prompt will be
fed back for the next iteration until the target is reached.

To cancel: /cancel-ut
EOF

# Display completion promise requirements
echo ""
echo "========================================================================"
echo "CRITICAL - Unit Test Loop Completion Promise"
echo "========================================================================"
echo ""
echo "To complete this loop, output this EXACT text:"
echo "  <promise>$COMPLETION_PROMISE</promise>"
echo ""
echo "STRICT REQUIREMENTS:"
echo "  - Use <promise> XML tags EXACTLY as shown above"
echo "  - The statement MUST be completely and unequivocally TRUE"
echo "  - Do NOT output false statements to exit the loop"
echo "  - Do NOT lie even if you think you should exit"
echo ""
echo "If you believe you're stuck or coverage target is unreachable, keep trying."
echo "The loop continues until the promise is GENUINELY TRUE."
echo "========================================================================"

# NOTE: Log entry already added when creating state.json above
