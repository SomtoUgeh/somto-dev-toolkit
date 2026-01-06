#!/bin/bash

# Unit Test Loop Setup Script
# Creates state file for in-session unit test loop

set -euo pipefail

# Defaults
TARGET_COVERAGE=0
MAX_ITERATIONS=0
TEST_COMMAND=""
COMPLETION_PROMISE="COVERAGE COMPLETE"
CUSTOM_PROMPT=""

show_help() {
  cat << 'HELP_EOF'
Unit Test Loop - Iterative unit test coverage improvement (Matt Pocock pattern)

USAGE:
  /ut [OPTIONS] ["custom prompt"]

OPTIONS:
  --target <N%>                 Target coverage percentage (exits when reached)
  --max-iterations <n>          Maximum iterations before auto-stop (default: unlimited)
  --test-command '<cmd>'        Override auto-detected coverage command
  --completion-promise '<text>' Custom promise phrase (default: COVERAGE COMPLETE)
  -h, --help                    Show this help message

CUSTOM PROMPT:
  Optional positional argument to customize the task. Added to the default instructions.
  Example: /ut "refactor existing tests to follow AAA pattern"
  Example: /ut "focus on error handling" --target 80%

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
  /ut "rewrite tests to follow AAA pattern"

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
        echo "Error: --target requires a percentage (e.g., --target 80%)" >&2
        exit 1
      fi
      # Strip % if present
      TARGET_COVERAGE="${2%\%}"
      if ! [[ "$TARGET_COVERAGE" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        echo "Error: --target must be a number, got: $2" >&2
        exit 1
      fi
      shift 2
      ;;
    --max-iterations)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --max-iterations requires a number" >&2
        exit 1
      fi
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "Error: --max-iterations must be a positive integer, got: $2" >&2
        exit 1
      fi
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    --test-command)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --test-command requires a command string" >&2
        exit 1
      fi
      TEST_COMMAND="$2"
      shift 2
      ;;
    --completion-promise)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --completion-promise requires a text argument" >&2
        exit 1
      fi
      COMPLETION_PROMISE="$2"
      shift 2
      ;;
    -*)
      echo "Unknown option: $1" >&2
      echo "Use --help for usage information" >&2
      exit 1
      ;;
    *)
      # Positional argument = custom prompt
      if [[ -n "$CUSTOM_PROMPT" ]]; then
        CUSTOM_PROMPT="$CUSTOM_PROMPT $1"
      else
        CUSTOM_PROMPT="$1"
      fi
      shift
      ;;
  esac
done

# Auto-detect test command if not provided
if [[ -z "$TEST_COMMAND" ]]; then
  TEST_COMMAND=$(detect_coverage_tool)
  if [[ -z "$TEST_COMMAND" ]]; then
    echo "Error: Could not detect coverage tool." >&2
    echo "" >&2
    echo "No vitest.config.*, jest.config.*, c8, nyc, or coverage script found." >&2
    echo "" >&2
    echo "Please specify manually:" >&2
    echo "  /ut --test-command 'pnpm run coverage'" >&2
    echo "  /ut --test-command 'bun test:coverage'" >&2
    exit 1
  fi
fi

# Create .claude directory if needed
mkdir -p .claude

# Create progress file if it doesn't exist
PROGRESS_FILE=".claude/ut-progress.txt"
if [[ ! -f "$PROGRESS_FILE" ]]; then
  echo "# Test Coverage Progress Log" > "$PROGRESS_FILE"
  echo "# Format: JSONL - one entry per iteration" >> "$PROGRESS_FILE"
  echo "" >> "$PROGRESS_FILE"
fi

# Create state file
STATE_FILE=".claude/ut-loop.local.md"
cat > "$STATE_FILE" <<EOF
---
active: true
iteration: 1
max_iterations: $MAX_ITERATIONS
target_coverage: $TARGET_COVERAGE
test_command: "$TEST_COMMAND"
completion_promise: "$COMPLETION_PROMISE"
custom_prompt: "$CUSTOM_PROMPT"
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
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

If uncovered code is not worth testing (boilerplate, unreachable error branches, internal plumbing), add \`/* v8 ignore next */\` or \`/* v8 ignore start */\` comments instead of writing low-value tests.

## FORBIDDEN

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
7. Append progress to \`.claude/ut-progress.txt\`:
   \`\`\`json
   {"ts":"$(date -u +%Y-%m-%dT%H:%M:%SZ)","iteration":1,"file":"<file>","notes":"<what you tested>"}
   \`\`\`

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

To complete: output <promise>$COMPLETION_PROMISE</promise>
To cancel: /cancel-ut
EOF
