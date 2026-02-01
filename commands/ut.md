---
name: ut
description: "Unit test coverage improvement with Dex tracking"
argument-hint: "PROMPT [--target N%]"
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-ut-loop.sh:*)
hide-from-slash-command-tool: "true"
---

# Unit Test Loop

Execute the setup script to initialize:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-ut-loop.sh" $ARGUMENTS
```

You are now in a 2-phase unit test workflow. The stop hook advances you through phases.

---

## Branch Setup (Handled by Setup Script)

When starting on main/master, the setup script prompts:
1. "Create a feature branch?" [1/2]
2. If yes, prompts for branch name (default: `test/unit-coverage`)
3. Creates branch before loop starts

---

## Structured Output Control Flow

| Phase | Name | Required Marker | Next Phase |
|-------|------|-----------------|------------|
| 1 | Coverage Analysis | `<phase_complete phase="1"/>` | 2 |
| 2 | Dex Handoff | `<phase_complete phase="2"/>` | done |

---

## Phase 1: Coverage Analysis

**Goal:** Identify files with low coverage and create prioritized test tasks.

1. **Run coverage** command to see current state
2. **Identify gaps** - Focus on:
   - Files with <80% coverage (or target from args)
   - User-facing behavior, not implementation details
   - Code paths that could break user workflows

3. **Create prioritized list** of 3-7 test tasks, each covering ONE specific behavior

**Output:** `<phase_complete phase="1"/>`

---

## Phase 2: Dex Handoff

Create Dex epic with target, then individual tasks.

**Steps:**

1. Create epic with target in description:
```bash
dex create "Unit Test Coverage" -d "Target: N% coverage for [scope]

Current: X%
Goal: Y%"
```

2. For each identified gap, create a task:
```bash
dex create "Test: [specific behavior]" --parent <epic-id> -d "
File: path/to/file.ts
Current coverage: X%

Test should verify:
- [ ] Specific behavior 1
- [ ] Edge case handling

Query: RTL getByRole, test user-visible behavior
"
```

3. Set dependencies if needed:
```bash
dex edit <task2-id> --add-blocker <task1-id>
```

4. Confirm:
```bash
dex list
```

5. Use AskUserQuestion:
"Coverage tasks created:
- Epic: Unit Test Coverage (target: N%)
- <N> tasks ready

What next?"

Options:
- **Start first task** - Begin implementation
- **Done** - Review tasks first

**Output:** `<phase_complete phase="2"/>` or `<promise>UT SETUP COMPLETE</promise>`

---

## Working on Tasks

Use Dex + /complete workflow:

```bash
dex list --pending      # See what's ready
dex start <id>          # Start working
/complete <id>          # Run reviewers and complete
```

Each task iteration:
1. Write ONE meaningful test
2. Run lint, format, typecheck
3. Run coverage to verify improvement
4. `/complete <id>` runs reviewers, commits, marks done

---

## React Testing Library Guidelines

> "The more your tests resemble the way your software is used, the more confidence they can give you."

### Query Priority (use in order)
1. `getByRole` - **default choice**, use `name` option: `getByRole('button', {name: /submit/i})`
2. `getByLabelText` - form fields
3. `getByPlaceholderText` - only if no label
4. `getByText` - non-interactive elements
5. `getByTestId` - **last resort only**

### Best Practices
- **Use `screen`** - `screen.getByRole('button')` not destructuring render
- **Use `userEvent.setup()`** - more realistic than `fireEvent`
- **Use jest-dom matchers** - `toBeDisabled()` not `expect(el.disabled).toBe(true)`
- **Test behavior, not implementation** - what users see/do, not internal state

---

## Quality Expectations

- **ONE test per task** - focused, reviewable commits
- **User-facing behavior only** - test what users depend on
- **Quality over quantity** - great tests catch regressions users would notice
- **No coverage gaming** - if code isn't worth testing, use `/* v8 ignore */`

---

## Cancellation

To cancel: `/cancel-ut` or `rm .claude/ut-loop-*.local.md`
