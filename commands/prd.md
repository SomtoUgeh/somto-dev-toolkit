---
name: prd
description: Deep interview to build PRD for new features or enhancements
argument-hint: "<file|folder|idea description>"
allowed-tools:
  - Bash(${CLAUDE_PLUGIN_ROOT}/scripts/setup-prd.sh:*)
hide-from-slash-command-tool: "true"
---

# PRD Loop

Execute the setup script to initialize the PRD loop:

```!
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-prd.sh" $ARGUMENTS
```

You are now in a phased PRD workflow. The stop hook advances you through phases based on **structured output markers**.

---

## Branch Setup (Handled by Setup Script)

When starting on main/master, the setup script prompts:
1. "Create a feature branch?" [1/2]
2. If yes, prompts for branch name (default: `feat/<feature-name>`)
3. Creates branch before loop starts

---

## Structured Output Control Flow

The hook uses **file existence as primary truth** (ralph-loop pattern). Markers are for explicit control. If you complete the work but forget the marker, the hook detects file existence and auto-advances (where allowed).

### Phase Transition Table

| Phase | Name | Required Marker | Attributes | Next Phase |
|-------|------|-----------------|------------|------------|
| 1 | Input Classification | `<phase_complete phase="1"/>` | `feature_name` (required) | 2 |
| 2 | Interview + Exploration | `<phase_complete phase="2"/>` | none | 3 |
| 3 | Spec Write | `<phase_complete phase="3"/>` | `spec_path` (required) | 4 |
| 4 | Dex Handoff | `<phase_complete phase="4"/>` | none | done |

### Detection Priority (File > Marker)

1. **File existence is truth** - If `plans/<feature>/spec.md` exists, phase 3 is considered complete
2. **Markers are explicit signals** - Still work and take precedence when present
3. **Last marker wins** - If docs/examples contain markers, only the LAST occurrence counts
4. **Auto-discovery** - Paths follow convention: `plans/<feature>/spec.md`

### File-Based Auto-Advance

| Phase | Auto-Advances When |
|-------|-------------------|
| 3 | `plans/<feature>/spec.md` exists with stories section |
| 4 | Dex tasks created for all stories |

### Exact Marker Formats

```xml
<!-- Phase 1 -->
<phase_complete phase="1" feature_name="auth-feature"/>

<!-- Phase 2 -->
<phase_complete phase="2"/>

<!-- Phase 3 -->
<phase_complete phase="3" spec_path="plans/auth-feature/spec.md"/>

<!-- Phase 4 -->
<phase_complete phase="4"/>
```

---

## Phase Details

### Phase 1: Input Classification

Classify input type (empty/file/folder/idea) and extract feature context.

**Output:** `<phase_complete phase="1" feature_name="SLUG"/>` where SLUG is lowercase-hyphenated.

### Phase 2: Interview + Exploration

**Commitment:** "I will ask 8-10+ questions covering: core problem, success criteria, MVP scope, technical constraints, UX flows, edge cases, error states, and tradeoffs. I will spawn ALL research and expert agents after Wave 1."

Conduct thorough interview using AskUserQuestion tool. Interview in waves while research runs in background:

#### Wave 1 (3-4 questions): Core problem, success criteria, MVP scope

After Wave 1, spawn ALL agents IN PARALLEL with `run_in_background: true` (single message, multiple Task calls):

**Research Agents:**
```
Task 1: subagent_type="somto-dev-toolkit:prd-codebase-researcher" (max_turns: 30, run_in_background: true)
Task 2: subagent_type="compound-engineering:research:git-history-analyzer" (max_turns: 30, run_in_background: true)
Task 3: subagent_type="somto-dev-toolkit:prd-external-researcher" (max_turns: 15, run_in_background: true)
```

**Expert Agents (inform spec early):**
```
Task 4: subagent_type="compound-engineering:review:architecture-strategist" (max_turns: 20, run_in_background: true)
Task 5: subagent_type="compound-engineering:review:security-sentinel" (max_turns: 20, run_in_background: true)
Task 6: subagent_type="compound-engineering:workflow:spec-flow-analyzer" (max_turns: 20, run_in_background: true)
Task 7: subagent_type="compound-engineering:review:pattern-recognition-specialist" (max_turns: 20, run_in_background: true)
```

#### Waves 2-5: Continue interview, incorporate agent findings as they complete

**Check progress:** `/tasks` or `Ctrl+T` to see status. Use `TaskOutput` to retrieve results when ready.

Continue asking questions across:
- **Wave 2** - Technical deep dive (systems, data models, patterns)
- **Wave 3** - UX/UI details (flows, error states)
- **Wave 4** - Edge cases & concerns (failures, security)
- **Wave 5** - Tradeoffs & decisions (compromises, priorities)

Incorporate agent findings into your questions. Architecture concerns? Ask about them. Security issues? Clarify with user.

**After 8-10+ questions and agent findings incorporated:**

**Output:** `<phase_complete phase="2"/>`

### Phase 3: Spec Write

Write comprehensive spec to `plans/<feature>/spec.md`. Include a structured stories section for Dex parsing.

**Spec Structure:**
```markdown
# <Feature> Specification

## Overview
## Problem Statement
## Success Criteria
## User Stories (As a X, I want Y, so that Z)
## Detailed Requirements
### Functional Requirements
### Non-Functional Requirements
### UI/UX Specifications
## Technical Design
### Data Models
### API Contracts
### System Interactions
### Implementation Notes
## Edge Cases & Error Handling
## Open Questions
## Out of Scope

## Implementation Stories

### Story 1: <Title>
**Category:** functional|ui|integration|edge-case|performance
**Skills:** <skill-name>, <skill-name>
**Blocked by:** none
**Acceptance Criteria:**
- [ ] Criterion 1
- [ ] Criterion 2
- [ ] Criterion 3

### Story 2: <Title>
**Category:** <category>
**Skills:** <skills or none>
**Blocked by:** Story 1
**Acceptance Criteria:**
- [ ] ...

## Research Findings
## Expert Review Findings
## References
```

**Story Size Rules:**
- Each story = ONE task (~15-30 min work)
- Max 7 acceptance criteria - if more, split
- Max 3 files touched - if more, consider splitting
- No "and" in title - "User can X and Y" = two stories
- Independently testable, cleanly revertible

**Skill Assignment (for ui/frontend stories):**
- `emil-design-engineering` - Forms, inputs, buttons, touch, a11y, polish
- `web-animation-design` - Animations, transitions, easing, springs
- `vercel-react-best-practices` - React performance, hooks, rendering

**Output:** `<phase_complete phase="3" spec_path="plans/<feature>/spec.md"/>`

### Phase 4: Dex Handoff

Use `dex plan` to automatically create tasks from the spec's Implementation Stories section.

**Steps:**

1. Create tasks from spec using `dex plan`:
```bash
dex plan plans/<feature>/spec.md
```

This automatically:
- Creates parent task from spec title
- Analyzes Implementation Stories section
- Generates subtasks with proper hierarchy
- Sets blocked-by relationships from "Blocked by:" lines

2. Verify tasks created:
```bash
dex status
dex list
```

3. Use AskUserQuestion:
"PRD complete! Dex tasks created from spec:
- `plans/<feature>/spec.md`
- <N> tasks ready for implementation

What next?"

Options:
- **Start first task** - Begin implementation
- **Done** - Review PRD first, implement later

**Output:** `<phase_complete phase="4"/>` or `<promise>PRD COMPLETE</promise>`

---

## Key Principles

**Production Quality Always** - Every line will be maintained by others.

**Be Annoyingly Thorough** - Better 20 questions than one missed detail.

**Non-Obvious > Obvious** - Focus on edge cases, error states, tradeoffs.

**Expert Input Early** - Run reviewers during exploration, not after spec is done.

**Atomic Stories** - Each story = ONE thing, ONE task. Independently testable, cleanly revertible.

---

## Cancellation

To cancel: `/cancel-prd` or `rm .claude/prd-loop-*.local.md`
