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

---

## Branch Setup (Handled by Setup Script)

When starting on main/master, the setup script prompts:
1. "Create a feature branch?" [1/2]
2. If yes, prompts for branch name (default: `test/e2e-coverage`)
3. Creates branch before loop starts

This happens in bash before Claude starts working.

---

## Structured Output Control Flow

The stop hook parses your output for specific XML markers. **You MUST output the exact marker format** to advance. Missing markers block progression with guidance.

### Required Markers (in order)

| Step | Marker | When |
|------|--------|------|
| 1 | `<reviews_complete/>` | After running reviewers and addressing findings |
| 2 | `<iteration_complete test_file="..."/>` | After committing test |
| 3 | `<promise>TEXT</promise>` | When all flows covered (to exit loop) |

### Exact Marker Formats

```xml
<!-- After running reviewers -->
<reviews_complete/>

<!-- After committing (include actual test file path) -->
<iteration_complete test_file="e2e/checkout.e2e.ts"/>

<!-- When all critical flows covered -->
<promise>E2E COMPLETE</promise>
```

### Validation Rules

1. **reviews marker required first** - Cannot advance without `<reviews_complete/>`
2. **test_file attribute required** - Hook logs progress with this path
3. **Commit must exist** - Pattern: `test(...):` in recent commits
4. **Last marker wins** - If examples appear in docs, only LAST occurrence counts

---

## Your Task

Each iteration, you must:

1. **Identify a user flow** that lacks E2E coverage
2. **Create page object** (`*.e2e.page.ts`) if needed for that flow
3. **Write ONE E2E test** (`*.e2e.ts`) that validates the flow
4. **Run lint, format, and typecheck** the equivalent command in the codebase to ensure code quality
5. **Run tests** to verify the test passes
6. **[MANDATORY] Run reviewers IN PARALLEL** - In ONE message, spawn multiple Task calls:
   ```
   Task 1: subagent_type="pr-review-toolkit:code-simplifier" (max_turns: 15)
   Task 2: subagent_type="<kieran-reviewer-for-language>" (max_turns: 20)
   ```
   Kieran reviewers:
   - TypeScript/JavaScript: `compound-engineering:review:kieran-typescript-reviewer`
   - Python: `compound-engineering:review:kieran-python-reviewer`
   - Database/migrations: `compound-engineering:review:data-integrity-guardian`

   All run in parallel → results return together → address ALL findings.
7. **[MANDATORY] Output reviews marker** after addressing all findings:
   ```
   <reviews_complete/>
   ```
9. **Commit** with message: `test(e2e): <describe the user flow>`
10. **Output iteration marker**:
    ```
    <iteration_complete test_file="path/to/test.e2e.ts"/>
    ```
11. **Log progress** to `.claude/e2e-progress.txt`

⚠️ The stop hook ENFORCES steps 6-8. You cannot advance without `<reviews_complete/>` marker.

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
