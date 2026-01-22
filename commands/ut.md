---
name: ut
description: "Start unit test coverage improvement loop"
argument-hint: "PROMPT [--target N%] [--max-iterations N] [--test-command 'cmd'] [--completion-promise 'text']"
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

---

## Branch Setup (Handled by Setup Script)

When starting on main/master, the setup script prompts:
1. "Create a feature branch?" [1/2]
2. If yes, prompts for branch name (default: `test/unit-coverage`)
3. Creates branch before loop starts

This happens in bash before Claude starts working.

---

## Structured Output Control Flow

The stop hook uses **markers as signals, with git-based fallback detection**. If you complete the work but forget a marker, the hook can detect test commits and auto-advance.

### Required Markers (in order)

| Step | Marker | Fallback |
|------|--------|----------|
| 1 | `<reviews_complete/>` | **None** (quality gate, always required) |
| 2 | `<iteration_complete test_file="..."/>` | Auto-detects from git log if test commit exists |
| 3 | `<promise>TEXT</promise>` | None (explicit exit signal) |

### Exact Marker Formats

```xml
<!-- After running reviewers (REQUIRED - no fallback) -->
<reviews_complete/>

<!-- After committing (include actual test file path) -->
<iteration_complete test_file="src/components/Button.test.tsx"/>

<!-- When coverage target reached -->
<promise>COVERAGE COMPLETE</promise>
```

### Detection Priority

1. **Markers are explicit signals** - Take precedence when present
2. **Git fallback for iteration** - If `test(` commit exists but marker missing, auto-advances
3. **Reviews always required** - No fallback (quality gate)
4. **Last marker wins** - If examples appear in docs, only LAST occurrence counts

---

## Your Task

Each iteration, you must:

1. **Run coverage** to identify files with low coverage
2. **Find ONE important gap** - focus on user-facing features, not implementation details
3. **Write ONE meaningful test** that validates real user behavior
4. **Run lint, format, and typecheck** the equivalent command in the codebase to ensure code quality
5. **Run coverage again** to verify improvement
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
