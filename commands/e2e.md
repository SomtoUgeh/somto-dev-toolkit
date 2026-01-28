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

The stop hook uses **markers as signals, with git-based fallback detection**. If you complete the work but forget a marker, the hook can detect test commits and auto-advance.

### Marker Summary

| Step | Marker | Status | Fallback |
|------|--------|--------|----------|
| 1 | `<reviews_complete/>` | Required | **None** (quality gate) |
| 2 | `<iteration_complete test_file="..."/>` | Optional | Auto-detects from git log if e2e/test commit exists |
| 3 | `<promise>TEXT</promise>` | Required | None (explicit exit signal) |

**State Management**: State is stored in `.claude/e2e-state-{session}.json` (single source of truth). Progress log is embedded - no separate progress.txt.

### Exact Marker Formats

```xml
<!-- After running reviewers (REQUIRED - no fallback) -->
<reviews_complete/>

<!-- After committing (include actual test file path) -->
<iteration_complete test_file="e2e/checkout.e2e.ts"/>

<!-- When all critical flows covered -->
<promise>E2E COMPLETE</promise>
```

### Detection Priority

1. **Markers are explicit signals** - Take precedence when present
2. **Git fallback for iteration** - If `test(` or `e2e(` commit exists but marker missing, auto-advances
3. **Reviews always required** - No fallback (quality gate)
4. **Last marker wins** - If examples appear in docs, only LAST occurrence counts

---

## Your Task

Each iteration, you must:

1. **Identify a user flow** that lacks E2E coverage
2. **Create page object** (`*.e2e.page.ts`) if needed for that flow
3. **Write ONE E2E test** (`*.e2e.ts`) that validates the flow
4. **Run lint, format, and typecheck** the equivalent command in the codebase to ensure code quality
5. **Run tests** to verify the test passes
6. **[MANDATORY] Run reviewers IN PARALLEL (background optional)** - In ONE message, spawn multiple Task calls with `run_in_background: true`:
   ```
   Task 1: subagent_type="pr-review-toolkit:code-simplifier" (max_turns: 15, run_in_background: true)
   Task 2: subagent_type="<kieran-reviewer-for-language>" (max_turns: 20, run_in_background: true)
   ```
   Kieran reviewers:
   - TypeScript/JavaScript: `compound-engineering:review:kieran-typescript-reviewer`
   - Python: `compound-engineering:review:kieran-python-reviewer`
   - Database/migrations: `compound-engineering:review:data-integrity-guardian`

   Check progress: `/tasks` or `Ctrl+T`. Retrieve with `TaskOutput` → address ALL findings.
7. **[MANDATORY] Output reviews marker** after addressing all findings:
   ```
   <reviews_complete/>
   ```
9. **Commit** with message: `test(e2e): <describe the user flow>`
10. **Output iteration marker** (optional - hook auto-detects from git):
    ```
    <iteration_complete test_file="path/to/test.e2e.ts"/>
    ```

**Hook handles automatically:** Logs to state.json (don't touch it)

⚠️ The stop hook ENFORCES steps 6-8. You cannot advance without `<reviews_complete/>` marker.

## File Naming Convention

- `*.e2e.page.ts` - Page objects (locators, setup, actions)
- `*.e2e.ts` - Test files (concise tests using page objects)

## Commitment Protocol

**Before each iteration, declare your completion criteria:**

```
"This iteration is complete when:
- ONE E2E test written that validates [specific user flow]
- Page object created/updated if needed
- Test passes
- Lint/typecheck pass
- Reviewers addressed
- Committed with test(e2e): message"
```

**Work until ALL declared criteria are verified.** Do not emit `<iteration_complete>` until you've checked each criterion.

## Quality Expectations

Treat ALL code as production code. No shortcuts, no "good enough for now". Every line you write will be maintained, extended, and debugged by others. Fight entropy.

## Critical Rules

- **ONE test per iteration** - focused, reviewable commits
- **Test user-visible behavior** - not implementation details
- **Tests must be independent** - no shared state between tests
- **Use semantic locators** - getByRole > getByLabel > getByText > getByTestId
- **Create page objects** - keep tests concise by extracting setup to page objects
- **Ensure code quality** - Run lint, format, and typecheck before committing

## Completion

When all critical user flows are covered with E2E tests, output:

```
<promise>E2E COMPLETE</promise>
```

IMPORTANT: If a completion promise is set, you may ONLY output it when the statement is completely and unequivocally TRUE. Do not output false promises to escape the loop, even if you think you're stuck or should exit for other reasons. The loop is designed to continue until genuine completion.
