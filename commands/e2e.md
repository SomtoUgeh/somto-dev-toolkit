---
description: "Start Playwright E2E test development loop"
argument-hint: "[\"custom prompt\"] [--max-iterations N] [--test-command 'cmd'] [--completion-promise 'text']"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-e2e-loop.sh:*)"]
hide-from-slash-command-tool: "true"
---

# E2E Test Loop

Execute the setup script to initialize the E2E test loop:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-e2e-loop.sh" $ARGUMENTS
```

You are now in a Playwright E2E test development loop.

## Your Task

Each iteration, you must:

1. **Identify a user flow** that lacks E2E coverage
2. **Create page object** (`*.e2e.page.ts`) if needed for that flow
3. **Write ONE E2E test** (`*.e2e.ts`) that validates the flow
4. **Run tests** to verify the test passes
5. **Commit** with message: `test(e2e): <describe the user flow>`
6. **Log progress** to `.claude/e2e-progress.txt`

## File Naming Convention

- `*.e2e.page.ts` - Page objects (locators, setup, actions)
- `*.e2e.ts` - Test files (concise tests using page objects)

## Critical Rules

- **ONE test per iteration** - focused, reviewable commits
- **Test user-visible behavior** - not implementation details
- **Tests must be independent** - no shared state between tests
- **Use semantic locators** - getByRole > getByLabel > getByText > getByTestId
- **Create page objects** - keep tests concise by extracting setup to page objects

## Completion

When all critical user flows are covered with E2E tests, output:

```
<promise>E2E COMPLETE</promise>
```

IMPORTANT: Only output this promise when E2E coverage is genuinely complete.
