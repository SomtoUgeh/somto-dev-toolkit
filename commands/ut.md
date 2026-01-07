---
name: ut
description: "Start unit test coverage improvement loop"
argument-hint: PROMPT [--target N%] [--max-iterations N] [--test-command 'cmd'] [--completion-promise 'text']"
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-ut-loop.sh:*)
hide-from-slash-command-tool: "true"
hooks:
  Stop:
    - type: command
      command: "${CLAUDE_PLUGIN_ROOT}/hooks/stop_hook.sh"
      timeout: 30
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
6. **Commit** with message: `test(<file>): <describe behavior>`
7. **Log progress** to `.claude/ut-progress.txt`

## Critical Rules

- **ONE test per iteration** - focused, reviewable commits
- **User-facing behavior only** - test what users depend on, not implementation details
- **Quality over quantity** - a great test catches regressions users would notice
- **No coverage gaming** - if code isn't worth testing, use `/* v8 ignore */` instead
- **Log progress** - Make sure to log progress to `.claude/e2e-progress.txt` after each successful test run.
- **Ensure code quality** - Run lint, format, and typecheck before committing

## Completion

When the coverage target is reached (or you've covered all meaningful user-facing behavior), output:

```
<promise>COVERAGE COMPLETE</promise>
```

IMPORTANT: Only output this promise when it's genuinely true. Do not lie to exit the loop.
