---
name: ut-help
description: "Explain the unit test loop technique"
---

# Unit Test Loop Help

Explain the following to the user:

## What is the Unit Test Loop?

It creates an iterative loop where Claude:
1. Runs coverage to find gaps
2. Writes ONE meaningful test per iteration
3. Commits with descriptive message
4. Repeats until target coverage reached

The key insight: **ONE test per iteration** forces focused, reviewable commits and prevents test spam.

## Philosophy

From Matt Pocock's approach:

> A great test covers behavior users depend on. It tests a feature that, if broken, would frustrate or block users. It validates real workflows - not implementation details.

**Do NOT** write tests just to increase coverage numbers. Use coverage as a guide to find UNTESTED USER-FACING BEHAVIOR.

If uncovered code isn't worth testing (boilerplate, unreachable branches, internal plumbing), use `/* v8 ignore */` comments instead.

## Commands

### `/ut [OPTIONS]`

Start a coverage improvement loop.

**Options:**
- `--target N%` - Target coverage percentage (exits when reached)
- `--max-iterations N` - Max iterations before auto-stop
- `--test-command "cmd"` - Override auto-detected coverage command
- `--completion-promise "text"` - Custom promise phrase (default: COVERAGE COMPLETE)

**Examples:**
```
/ut --target 80% --max-iterations 20
/ut --test-command "bun test:coverage"
/ut --completion-promise "ALL TESTS PASS" --max-iterations 10
```

### `/cancel-ut`

Stop an active loop and remove the state file.

## Auto-Detection

The loop automatically detects:

**Coverage tools (in order):**
1. `vitest.config.*` → `vitest run --coverage`
2. `jest.config.*` → `jest --coverage`
3. `c8` in package.json → `npx c8 <pm> test`
4. `nyc` in package.json → `npx nyc <pm> test`
5. `coverage` script → `<pm> run coverage`
6. `test:coverage` script → `<pm> run test:coverage`

**Package managers (by lockfile):**
1. `pnpm-lock.yaml` → pnpm
2. `bun.lockb` → bun
3. `yarn.lock` → yarn
4. default → npm

## Process Per Iteration

1. Run coverage command
2. Find files with low coverage
3. Read uncovered lines
4. Identify ONE important user-facing feature
5. Write ONE test for that feature
6. Run coverage again
7. Commit: `test(<file>): <describe behavior>`
8. Log to `.claude/ut-progress.txt`

## Stopping the Loop

The loop stops when:
- `<promise>YOUR_PROMISE</promise>` is output (default: COVERAGE COMPLETE)
- `--max-iterations` is reached
- `/cancel-ut` is run

## Files Created

- `.claude/ut-loop.local.md` - State file (iteration, config, prompt)
- `.claude/ut-progress.txt` - Progress log (JSONL format)
