#!/bin/bash

# E2E Test Loop Setup Script
# Creates state file for in-session Playwright E2E test loop

set -euo pipefail

# Source shared helpers
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/loop-helpers.sh
source "$SCRIPT_DIR/lib/loop-helpers.sh"

# Defaults
MAX_ITERATIONS=0
TEST_COMMAND=""
COMPLETION_PROMISE="E2E COMPLETE"
CUSTOM_PROMPT_PARTS=()

show_help() {
  cat << 'HELP_EOF'
E2E Test Loop - Iterative Playwright E2E test development

USAGE:
  /e2e [OPTIONS] ["custom prompt"]

OPTIONS:
  --max-iterations <n>          Maximum iterations before auto-stop (default: unlimited)
  --test-command '<cmd>'        Override default test command (default: npx playwright test)
  --completion-promise '<text>' Custom promise phrase (default: E2E COMPLETE)
  -h, --help                    Show this help message

DESCRIPTION:
  Starts an E2E test development loop. Each iteration:
  1. Identifies missing E2E coverage for user flows
  2. Creates page object if needed (*.e2e.page.ts)
  3. Writes ONE E2E test (*.e2e.ts)
  4. Runs tests to verify
  5. Commits with descriptive message
  6. Repeats until complete

  To signal completion, output: <promise>YOUR_PHRASE</promise>

CUSTOM PROMPT:
  Optional positional argument to customize the task. Added to the default E2E instructions.
  Example: /e2e "review existing tests and refactor to follow page object pattern"
  Example: /e2e "focus on auth flows" --max-iterations 10

EXAMPLES:
  /e2e --max-iterations 15
  /e2e --test-command "pnpm test:e2e"
  /e2e --completion-promise "ALL FLOWS TESTED" --max-iterations 20
  /e2e "rewrite tests to use page object pattern"

FILE NAMING CONVENTION:
  *.e2e.page.ts - Page objects (locators, setup, actions)
  *.e2e.ts      - Test files (concise tests using page objects)

STOPPING:
  - Reach --max-iterations
  - Output <promise>E2E COMPLETE</promise>
  - Run /cancel-e2e
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
  # Check for playwright config
  if [[ -f "playwright.config.ts" ]] || [[ -f "playwright.config.js" ]]; then
    return 0
  fi
  # Check package.json for playwright
  if [[ -f "package.json" ]] && grep -q '"@playwright/test"' package.json 2>/dev/null; then
    return 0
  fi
  return 1
}

detect_e2e_folder() {
  # Common E2E folder locations
  for folder in "e2e" "tests/e2e" "test/e2e" "tests" "__tests__/e2e"; do
    if [[ -d "$folder" ]]; then
      echo "$folder"
      return
    fi
  done
  echo "e2e"  # Default
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      show_help
      exit 0
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
        echo "    --test-command 'pnpm test:e2e'" >&2
        echo "    --test-command 'npx playwright test'" >&2
        echo "    --test-command 'bun run test:e2e'" >&2
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
        echo "    --completion-promise 'E2E COMPLETE'" >&2
        echo "    --completion-promise 'All flows tested'" >&2
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
      echo "    --max-iterations <n>        Safety limit" >&2
      echo "    --test-command '<cmd>'      E2E test command" >&2
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

# Detect package manager early for messages
PM=$(detect_package_manager)

# Check for Playwright
if ! detect_playwright; then
  echo "Warning: No playwright.config.ts/js found." >&2
  if [[ "$PM" == "bun" ]]; then
    echo "Make sure Playwright is installed: bun create playwright" >&2
  elif [[ "$PM" == "yarn" ]]; then
    echo "Make sure Playwright is installed: yarn create playwright" >&2
  elif [[ "$PM" == "pnpm" ]]; then
    echo "Make sure Playwright is installed: pnpm create playwright" >&2
  else
    echo "Make sure Playwright is installed: npm init playwright@latest" >&2
  fi
fi

# Set default test command
if [[ -z "$TEST_COMMAND" ]]; then
  TEST_COMMAND="npx playwright test"
fi

# Detect E2E folder
E2E_FOLDER=$(detect_e2e_folder)

# Create .claude directory if needed
mkdir -p .claude

# Read session_id from SessionStart hook (with fallback for edge cases)
SESSION_ID=$(cat .claude/.current_session 2>/dev/null || echo "default")

# Branch setup - prompt user if on main/master
prompt_feature_branch "test/e2e-coverage"

# Create progress file if it doesn't exist
PROGRESS_FILE=".claude/e2e-progress.txt"
if [[ ! -f "$PROGRESS_FILE" ]]; then
  echo "# E2E Test Progress Log" > "$PROGRESS_FILE"
  echo "# Format: JSONL - one entry per iteration" >> "$PROGRESS_FILE"
  echo "" >> "$PROGRESS_FILE"
fi

# Quote completion promise for YAML
COMPLETION_PROMISE_YAML="\"$COMPLETION_PROMISE\""

# Create state file (session-scoped to prevent cross-instance interference)
STATE_FILE=".claude/e2e-loop-${SESSION_ID}.local.md"
cat > "$STATE_FILE" <<EOF
---
loop_type: "e2e"
active: true
iteration: 1
max_iterations: $MAX_ITERATIONS
test_command: "$TEST_COMMAND"
completion_promise: $COMPLETION_PROMISE_YAML
progress_path: "$PROGRESS_FILE"
e2e_folder: "$E2E_FOLDER"
custom_prompt: "$CUSTOM_PROMPT"
working_branch: "$WORKING_BRANCH"
branch_setup_done: true
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---

# E2E Test Development Loop

**Test command:** \`$TEST_COMMAND\`
**E2E folder:** \`$E2E_FOLDER/\`
**Max iterations:** $(if [[ $MAX_ITERATIONS -gt 0 ]]; then echo "$MAX_ITERATIONS"; else echo "unlimited"; fi)
$(if [[ -n "$CUSTOM_PROMPT" ]]; then echo -e "\n## Custom Instructions\n\n$CUSTOM_PROMPT"; fi)

## What Belongs in E2E Tests (vs Unit Tests)

**E2E tests are for STATE TRANSITIONS and USER FLOWS:**
- Login → Dashboard → Logout (auth flow)
- Browse → Add to Cart → Checkout → Confirmation (purchase flow)
- Signup → Email verification → Onboarding → First action
- Multi-page navigation that crosses system boundaries
- Flows where real browser interaction matters

**Prioritize tests that verify:**
1. User can move from state A to state B (e.g., logged out → logged in)
2. Navigation between pages works correctly
3. Data persists across page loads/refreshes
4. Authentication gates work (protected routes redirect)
5. Critical business flows that generate revenue

**Leave to unit tests:**
- Individual function logic and edge cases
- Data transformation and validation rules
- Component rendering in isolation
- Business logic calculations
- API response parsing

**Rule of thumb:** E2E = state transitions across pages. Unit = logic within a component.
E2E tests are expensive (slow, flaky) - reserve them for flows where the *transition* matters.

## FORBIDDEN

**NEVER modify test config to exclude files/folders from coverage or test runs.** This is cheating. The goal is to write tests, not to game metrics by hiding untested code.

## File Naming Convention

- \`*.e2e.page.ts\` - Page objects (locators, setup, actions)
- \`*.e2e.ts\` - Test files (concise tests using page objects)

Example structure:
\`\`\`
$E2E_FOLDER/
├── login.e2e.page.ts       # Page object
├── login.e2e.ts            # Tests
├── checkout.e2e.page.ts
├── checkout.e2e.ts
├── base.e2e.page.ts        # Base page object
\`\`\`

## Page Object Pattern (*.e2e.page.ts)

Page objects encapsulate setup and interactions:

\`\`\`typescript
// login.e2e.page.ts
import { Page } from '@playwright/test';

export class LoginPage {
  constructor(private page: Page) {}

  // Locators (use semantic selectors)
  emailInput = () => this.page.getByLabel('Email');
  passwordInput = () => this.page.getByLabel('Password');
  submitButton = () => this.page.getByRole('button', { name: 'Sign in' });

  // Navigation
  async goto() {
    await this.page.goto('/login');
  }

  // Actions
  async login(email: string, password: string) {
    await this.emailInput().fill(email);
    await this.passwordInput().fill(password);
    await this.submitButton().click();
  }
}
\`\`\`

## Test File Pattern (*.e2e.ts)

Tests should be concise, using page objects:

\`\`\`typescript
// login.e2e.ts
import { test, expect } from '@playwright/test';
import { LoginPage } from './login.e2e.page';

test('user can login with valid credentials', async ({ page }) => {
  const loginPage = new LoginPage(page);
  await loginPage.goto();
  await loginPage.login('user@example.com', 'password');
  await expect(page).toHaveURL('/dashboard');
});
\`\`\`

## Locator Priority (Use in Order)

1. \`getByRole()\` - buttons, links, headings (most resilient)
2. \`getByLabel()\` - form inputs
3. \`getByText()\` - static text content
4. \`getByTestId()\` - when semantic locators don't work
5. **Avoid**: CSS selectors, XPath

## Authentication Pattern

For authenticated tests, use setup project:

\`\`\`typescript
// auth.setup.ts
import { test as setup } from '@playwright/test';

setup('authenticate', async ({ page }) => {
  await page.goto('/login');
  await page.getByLabel('Email').fill('user@example.com');
  await page.getByLabel('Password').fill('password');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.context().storageState({ path: 'playwright/.auth/user.json' });
});
\`\`\`

Then in playwright.config.ts:
\`\`\`typescript
projects: [
  { name: 'setup', testMatch: /.*\.setup\.ts/ },
  { name: 'chromium', dependencies: ['setup'], use: { storageState: 'playwright/.auth/user.json' } },
]
\`\`\`

## Process (ONE test per iteration)

1. Identify a user flow that lacks E2E coverage
2. Create or update the page object (\`*.e2e.page.ts\`) if needed
3. Write ONE focused E2E test (\`*.e2e.ts\`)
4. Run \`$TEST_COMMAND\` to verify the test passes
5. **Lint & format** - run project's lint/format commands, fix any errors
6. Commit with message: \`test(e2e): <describe the user flow tested>\`
7. **Signal iteration complete** with structured output (see below)

## Iteration Complete Signal

After committing, output this marker so the hook can verify and advance:

\`\`\`
<iteration_complete test_file="path/to/flow.e2e.ts"/>
\`\`\`

The hook will:
- Verify your commit exists
- Log progress
- Advance to next iteration

**If you don't output this marker, the iteration won't advance.**

## Test Best Practices

- **Test user-visible behavior** - not implementation details
- **One flow per test** - keep tests focused
- **Tests must be independent** - no shared state between tests
- **Use web-first assertions** - \`expect(locator).toBeVisible()\` auto-waits
- **Mock external APIs** - use \`page.route()\` for third-party services
- **MINIMAL COMMENTS** - code should be self-documenting; only add comments for non-obvious "why"

## Test Colocation

**Tests should live close to the code they test:**
- E2E tests in \`$E2E_FOLDER/\` organized by feature/flow
- Shared setup (auth, fixtures) can live in \`$E2E_FOLDER/setup/\` or \`$E2E_FOLDER/fixtures/\`
- Page objects next to their tests: \`login.e2e.page.ts\` + \`login.e2e.ts\`

**Why colocation matters:**
- Easy to find tests for a feature
- Tests get updated when code changes
- Dead code detection (no tests = suspicious)

## Completion

ONLY WRITE ONE TEST PER ITERATION.

When all critical user flows are covered, output:

\`\`\`
<promise>$COMPLETION_PROMISE</promise>
\`\`\`

CRITICAL: Only output this promise when E2E coverage is genuinely complete. Do not lie to exit the loop.
EOF

# Output setup message
cat <<EOF
E2E test loop activated!

Iteration: 1
Max iterations: $(if [[ $MAX_ITERATIONS -gt 0 ]]; then echo "$MAX_ITERATIONS"; else echo "unlimited"; fi)
Test command: $TEST_COMMAND
E2E folder: $E2E_FOLDER/
Completion promise: $COMPLETION_PROMISE
$(if [[ -n "$CUSTOM_PROMPT" ]]; then echo "Custom prompt: $CUSTOM_PROMPT"; fi)

File naming convention:
  *.e2e.page.ts - Page objects (locators, setup, actions)
  *.e2e.ts      - Test files (concise, use page objects)

The stop hook is now active. When you try to exit, the same prompt will be
fed back for the next iteration until E2E coverage is complete.

To cancel: /cancel-e2e
EOF

# Display completion promise requirements
echo ""
echo "========================================================================"
echo "CRITICAL - E2E Test Loop Completion Promise"
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
echo "If you believe you're stuck or E2E coverage is unreachable, keep trying."
echo "The loop continues until the promise is GENUINELY TRUE."
echo "========================================================================"

# Log STARTED to progress file
echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"STARTED\",\"e2e_folder\":\"$E2E_FOLDER\",\"notes\":\"E2E test loop started\"}" >> "$PROGRESS_FILE"
