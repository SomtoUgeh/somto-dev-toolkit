---
name: e2e
description: "Playwright E2E test development with Dex tracking"
argument-hint: "PROMPT"
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-e2e-loop.sh:*)
hide-from-slash-command-tool: "true"
---

# E2E Test Loop

Execute the setup script to initialize:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-e2e-loop.sh" $ARGUMENTS
```

You are now in a 2-phase E2E test workflow. The stop hook advances you through phases.

---

## Branch Setup (Handled by Setup Script)

When starting on main/master, the setup script prompts:
1. "Create a feature branch?" [1/2]
2. If yes, prompts for branch name (default: `test/e2e-coverage`)
3. Creates branch before loop starts

---

## Structured Output Control Flow

| Phase | Name | Required Marker | Next Phase |
|-------|------|-----------------|------------|
| 1 | Flow Analysis | `<phase_complete phase="1"/>` | 2 |
| 2 | Dex Handoff | `<phase_complete phase="2"/>` | done |

---

## Phase 1: Flow Analysis

**Goal:** Identify critical user flows that need E2E coverage.

1. **Analyze the application** - routes, features, user journeys
2. **Identify critical flows** - Focus on:
   - Happy paths users depend on
   - Payment/auth/data submission flows
   - Flows that broke in production before

3. **Create prioritized list** of 3-7 E2E tasks, each covering ONE user flow

**Output:** `<phase_complete phase="1"/>`

---

## Phase 2: Dex Handoff

Create Dex epic, then individual tasks per flow.

**Steps:**

1. Create epic:
```bash
dex create "E2E Test Coverage" -d "Critical user flow coverage for [scope]

Flows to cover:
- Flow 1
- Flow 2
- ..."
```

2. For each identified flow, create a task:
```bash
dex create "E2E: [flow name]" --parent <epic-id> -d "
Flow: [describe the user journey]

Steps:
1. User does X
2. System shows Y
3. User completes Z

Files:
- e2e/[flow].e2e.page.ts (page object)
- e2e/[flow].e2e.ts (test)

Acceptance:
- [ ] Page object with semantic locators
- [ ] Test covers happy path
- [ ] Test runs independently
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
"E2E tasks created:
- Epic: E2E Test Coverage
- <N> flows to cover

What next?"

Options:
- **Start first task** - Begin implementation
- **Done** - Review tasks first

**Output:** `<phase_complete phase="2"/>` or `<promise>E2E SETUP COMPLETE</promise>`

---

## Working on Tasks

Use Dex + /complete workflow:

```bash
dex list --pending      # See what's ready
dex start <id>          # Start working
/complete <id>          # Run reviewers and complete
```

Each task iteration:
1. Create page object (`*.e2e.page.ts`) if needed
2. Write ONE E2E test (`*.e2e.ts`)
3. Run lint, format, typecheck
4. Run test to verify it passes
5. `/complete <id>` runs reviewers, commits, marks done

---

## File Naming Convention

- `*.e2e.page.ts` - Page objects (locators, setup, actions)
- `*.e2e.ts` - Test files (concise tests using page objects)

---

## Quality Expectations

- **ONE flow per task** - focused, reviewable commits
- **Test user-visible behavior** - not implementation details
- **Tests must be independent** - no shared state between tests
- **Use semantic locators** - getByRole > getByLabel > getByText > getByTestId
- **Create page objects** - keep tests concise

---

## Cancellation

To cancel: `/cancel-e2e` or `rm .claude/e2e-loop-*.local.md`
