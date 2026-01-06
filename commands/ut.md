---
name: ut
description: "Start unit test coverage improvement loop"
argument-hint: "[\"custom prompt\"] [--target N%] [--max-iterations N] [--test-command 'cmd'] [--completion-promise 'text']"
allowed-tools: ["Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-ut-loop.sh:*)"]
hide-from-slash-command-tool: "true"
---

# Unit Test Loop

Execute the setup script to initialize the unit test loop:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-ut-loop.sh" $ARGUMENTS
```

You are now in a unit test coverage improvement loop based on Matt Pocock's pattern.

## Your Task

Each iteration, you must:

1. **Run coverage** to identify files with low coverage
2. **Find ONE important gap** - focus on user-facing features, not implementation details
3. **Write ONE meaningful test** that validates real user behavior
4. **Run coverage again** to verify improvement
5. **Commit** with message: `test(<file>): <describe behavior>`
6. **Log progress** to `.claude/ut-progress.txt`

## Critical Rules

- **ONE test per iteration** - focused, reviewable commits
- **User-facing behavior only** - test what users depend on, not implementation details
- **Quality over quantity** - a great test catches regressions users would notice
- **No coverage gaming** - if code isn't worth testing, use `/* v8 ignore */` instead

## Completion

When the coverage target is reached (or you've covered all meaningful user-facing behavior), output:

```
<promise>COVERAGE COMPLETE</promise>
```

IMPORTANT: Only output this promise when it's genuinely true. Do not lie to exit the loop.
