---
name: e2e
description: "Start Playwright E2E test development loop"
argument-hint: "PROMPT [--max-iterations N] [--test-command 'cmd'] [--completion-promise 'text']"
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-e2e-loop.sh:*)
hide-from-slash-command-tool: "true"
---

# E2E Test Loop

Execute the setup script to initialize the E2E test loop:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-e2e-loop.sh" $ARGUMENTS
```

You are now in a Playwright E2E test development loop.

Please work on the task. When you try to exit, the E2E test loop will feed the same PROMPT back to you for the next iteration. You'll see your previous work in files and git history, allowing you to iterate and improve.

## Your Task

Each iteration, you must:

1. **Identify a user flow** that lacks E2E coverage
2. **Create page object** (`*.e2e.page.ts`) if needed for that flow
3. **Write ONE E2E test** (`*.e2e.ts`) that validates the flow
4. **Run lint, format, and typecheck** the equivalent command in the codebase to ensure code quality
5. **Run tests** to verify the test passes
6. **Run code-simplifier** - use the `pr-review-toolkit:code-simplifier` agent to review and simplify your changes
7. **Run Kieran review** - based on what you changed:
   - TypeScript code: `compound-engineering:review:kieran-typescript-reviewer`
   - Database/migrations/data models: `compound-engineering:review:data-integrity-guardian`
8. **Commit** with message: `test(e2e): <describe the user flow>`
9. **Log progress** to `.claude/e2e-progress.txt`

## File Naming Convention

- `*.e2e.page.ts` - Page objects (locators, setup, actions)
- `*.e2e.ts` - Test files (concise tests using page objects)

## Quality Expectations

Treat ALL code as production code. No shortcuts, no "good enough for now". Every line you write will be maintained, extended, and debugged by others. Fight entropy.

## Critical Rules

- **ONE test per iteration** - focused, reviewable commits
- **Test user-visible behavior** - not implementation details
- **Tests must be independent** - no shared state between tests
- **Use semantic locators** - getByRole > getByLabel > getByText > getByTestId
- **Create page objects** - keep tests concise by extracting setup to page objects
- **Log progress** - Make sure to log progress to `.claude/e2e-progress.txt` after each successful test run.
- **Ensure code quality** - Run lint, format, and typecheck before committing

## Completion

When all critical user flows are covered with E2E tests, output:

```
<promise>E2E COMPLETE</promise>
```

IMPORTANT: If a completion promise is set, you may ONLY output it when the statement is completely and unequivocally TRUE. Do not output false promises to escape the loop, even if you think you're stuck or should exit for other reasons. The loop is designed to continue until genuine completion.
