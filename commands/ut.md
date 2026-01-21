---
name: ut
description: "Start unit test coverage improvement loop"
argument-hint: PROMPT [--target N%] [--max-iterations N] [--test-command 'cmd'] [--completion-promise 'text']"
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-ut-loop.sh:*)
hide-from-slash-command-tool: "true"
---

# Unit Test Loop

Execute the setup script to initialize the unit test loop:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-ut-loop.sh" $ARGUMENTS
```

You are now in a unit test coverage improvement loop.

Please work on the task. When you try to exit, the unit test loop will feed the same PROMPT back to you for the next iteration. You'll see your previous work in files and git history, allowing you to iterate and improve.

## Your Task

Each iteration, you must:

1. **Run coverage** to identify files with low coverage
2. **Find ONE important gap** - focus on user-facing features, not implementation details
3. **Write ONE meaningful test** that validates real user behavior
4. **Run lint, format, and typecheck** the equivalent command in the codebase to ensure code quality
5. **Run coverage again** to verify improvement
6. **[MANDATORY] Run code-simplifier** - ALWAYS use `pr-review-toolkit:code-simplifier` (max_turns: 15) to review changes. Address ALL suggestions.
7. **[MANDATORY] Run Kieran review** - ALWAYS run based on what you changed (all max_turns: 20):
   - TypeScript/JavaScript: `compound-engineering:review:kieran-typescript-reviewer`
   - Python: `compound-engineering:review:kieran-python-reviewer`
   - Rails/Ruby: `compound-engineering:review:kieran-rails-reviewer`
   - Database/migrations/data models: `compound-engineering:review:data-integrity-guardian`
8. **[MANDATORY] Output reviews marker** after addressing all findings:
   ```
   <reviews_complete/>
   ```
9. **Commit** with message: `test(<file>): <describe behavior>`
10. **Output iteration marker**:
    ```
    <iteration_complete test_file="path/to/test.ts"/>
    ```
11. **Log progress** to `.claude/ut-progress.txt`

⚠️ The stop hook ENFORCES steps 6-8. You cannot advance without `<reviews_complete/>` marker.

## Quality Expectations

Treat ALL code as production code. No shortcuts, no "good enough for now". Every line you write will be maintained, extended, and debugged by others. Fight entropy.

## React Testing Library Guidelines

> "The more your tests resemble the way your software is used, the more confidence they can give you."

### Query Priority (use in order)
1. `getByRole` - **default choice**, use `name` option: `getByRole('button', {name: /submit/i})`
2. `getByLabelText` - form fields
3. `getByPlaceholderText` - only if no label
4. `getByText` - non-interactive elements
5. `getByTestId` - **last resort only**

### Query Types
- `getBy`/`getAllBy` - element exists (throws if not found)
- `queryBy`/`queryAllBy` - **only** for asserting absence
- `findBy`/`findAllBy` - async elements (returns Promise)

### Best Practices
- **Use `screen`** - `screen.getByRole('button')` not destructuring render
- **Use `userEvent.setup()`** - more realistic than `fireEvent`
- **Use jest-dom matchers** - `toBeDisabled()` not `expect(el.disabled).toBe(true)`
- **Avoid `act()`** - RTL handles it; use `findBy` or `waitFor` for async
- **Test behavior, not implementation** - what users see/do, not internal state

## Critical Rules

- **ONE test per iteration** - focused, reviewable commits
- **User-facing behavior only** - test what users depend on, not implementation details
- **Quality over quantity** - a great test catches regressions users would notice
- **No coverage gaming** - if code isn't worth testing, use `/* v8 ignore */` instead
- **Log progress** - Make sure to log progress to `.claude/ut-progress.txt` after each successful test run.
- **Ensure code quality** - Run lint, format, and typecheck before committing

## Completion

When the coverage target is reached (or you've covered all meaningful user-facing behavior), output:

```
<promise>COVERAGE COMPLETE</promise>
```

IMPORTANT: Only output this promise when it's genuinely true. Do not lie to exit the loop.
