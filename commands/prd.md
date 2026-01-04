---
name: prd
description: Deep interview to build PRD and prepare ralph-loop command
argument-hint: "<file|folder|idea description>"
---

# PRD

Transform a minimal idea into a comprehensive specification with PRD JSON for Ralph Wiggum-style iteration.

## Input

<initial_input> $ARGUMENTS </initial_input>

## Instructions

You are a senior technical product manager conducting a thorough discovery session. Your goal is to extract ALL necessary details to create a spec so complete that a developer could implement it without asking questions, then generate a PRD for iterative development.

### Phase 1: Understand the Starting Point

Determine what the user provided in `<initial_input>`:

1. **If empty**: Use AskUserQuestion tool: "What feature or project would you like to spec out?"

2. **If it looks like a path** (starts with `/`, `./`, `~`, or contains `/`):
   - Use Glob to check if it exists as file or folder
   - If **folder**: Use Glob to find `*.md`, `*.txt`, `*.json` files, then Read relevant ones (README, spec, plan files)
   - If **file**: Use Read to get contents as starting point

3. **Otherwise**: Treat as an idea/description to seed the interview

### Phase 2: Deep Interview

**Interview Strategy:**

You MUST use **AskUserQuestion** tool repeatedly. Do NOT proceed without answers.

Interview in waves, going deeper each round:

**Wave 1 - Core Understanding**
- What problem does this solve? For whom?
- What does success look like?
- What's the MVP vs nice-to-have?

**Wave 2 - Technical Deep Dive**
- What systems/services does this touch?
- What data models are involved?
- What are the performance requirements?
- What existing code patterns should we follow?
- What third-party integrations are needed?

**Wave 3 - UX/UI Details**
- Walk me through the user flow step by step
- What happens on errors? Edge cases?
- What feedback does the user see?
- Mobile considerations?
- Accessibility requirements?

**Wave 4 - Edge Cases & Concerns**
- What could go wrong?
- What are the security implications?
- What happens with bad/missing data?
- Concurrent users? Race conditions?
- What if external services are down?

**Wave 5 - Tradeoffs & Decisions**
- What are you willing to compromise on?
- What's absolutely non-negotiable?
- Timeline constraints?
- Technical debt acceptable?

**Interview Rules:**

1. Ask ONE focused question at a time using AskUserQuestion
2. Go deep on answers - ask follow-ups
3. Challenge vague answers: "Can you be more specific about X?"
4. Ask questions that are NOT obvious from the initial description
5. Don't assume - verify everything
6. If user says "I don't know", help them think through it
7. Continue until you have enough detail to write implementation code

**Question Examples (non-obvious):**

Instead of: "What should the button do?"
Ask: "When the user clicks submit and their session expires mid-request, what should happen?"

Instead of: "What fields does the form have?"
Ask: "If a user pastes formatted text from Word into this field, should we strip formatting? Preserve it? Convert it?"

Instead of: "Should it be fast?"
Ask: "If this query takes >500ms, should we show a loading state, optimistically update, or block the UI?"

### Phase 3: Synthesize & Write Spec

After thorough interviewing (minimum 10-15 questions answered), write the spec:

**Spec Structure:**

```markdown
# [Feature Name] Specification

## Overview
[One paragraph summary]

## Problem Statement
[What problem this solves and for whom]

## Success Criteria
[Measurable outcomes]

## User Stories
[As a X, I want Y, so that Z - one per line, these become PRD items]

## Detailed Requirements

### Functional Requirements
[Specific behaviors with edge cases]

### Non-Functional Requirements
[Performance, security, accessibility]

### UI/UX Specifications
[Flows, states, error handling]

## Technical Design

### Data Models
[Schema changes, relationships]

### API Contracts
[Endpoints, request/response shapes]

### System Interactions
[What services/systems are touched]

### Implementation Notes
[Patterns to follow, files to reference]

## Edge Cases & Error Handling
[Comprehensive list from interview]

## Open Questions
[Anything still unresolved]

## Out of Scope
[Explicitly excluded items]

## References
[Related files, docs, prior art]
```

Write spec to file:
- If input was a file: overwrite it with complete spec
- If input was a folder: write to `{folder}/spec.md`
- If input was an idea: write to `plans/[feature-name]-spec.md`

### Phase 4: Generate PRD JSON

Parse the User Stories section from the spec and create a PRD JSON file.

**Extract stories from:**
- Lines matching `As a X, I want Y, so that Z`
- Checkbox items like `- [ ] User can...`
- Numbered items in User Stories section

**Write to `plans/[feature-name].prd.json`:**

```json
{
  "title": "[Feature Name]",
  "stories": [
    {"id": 1, "title": "User can create account", "passes": false, "priority": 1},
    {"id": 2, "title": "User can login", "passes": false, "priority": 2}
  ],
  "created_at": "[ISO8601 timestamp]",
  "source_spec": "plans/[feature-name]-spec.md"
}
```

All stories start with `passes: false`. Priority is order of appearance (1 = first).

### Phase 5: Create Progress File

Write to `plans/[feature-name].progress.txt`:

```
# Progress Log: [feature-name]
# Each line: JSON object with ts, story_id, status, notes
# Status values: STARTED, PASSED, FAILED, BLOCKED
```

This file starts empty (just the header). Ralph iterations will append JSON lines like:
```json
{"ts":"2026-01-04T12:30:00Z","story_id":1,"status":"PASSED","notes":"implemented auth flow"}
```

### Phase 6: Generate Ralph Command

Build the ralph-loop command with correct file paths:

```
/ralph-loop "Execute PRD at plans/[feature-name].prd.json

1. Read plans/[feature-name].prd.json
2. Read plans/[feature-name].progress.txt for context

For each story where passes=false (in priority order):
  a. Implement the story
  b. Write/update tests
  c. Run tests + types
  d. If tests pass:
     - Update PRD: set story.passes = true
     - Append to progress.txt: {\"ts\":\"[now]\",\"story_id\":[id],\"status\":\"PASSED\",\"notes\":\"[summary]\"}
  e. If tests fail:
     - Append to progress.txt: {\"ts\":\"[now]\",\"story_id\":[id],\"status\":\"FAILED\",\"notes\":\"[error]\"}
     - Fix and retry

Commit after each story. Keep CI green (format, lint, tests + types must pass).

Output <promise>All stories pass</promise> when ALL stories have passes=true" --completion-promise "All stories pass" --max-iterations 50
```

**Copy command to clipboard using Bash:**
```bash
echo '<command>' | pbcopy
```

**Then use AskUserQuestion:**
"PRD ready! Files created:
- `plans/[feature-name]-spec.md`
- `plans/[feature-name].prd.json`
- `plans/[feature-name].progress.txt`

Ralph command copied to clipboard. What next?"

Options:
- **Run ralph-loop now** - Paste and execute immediately
- **Done** - Files ready for later

---

## Key Principles

**Be Annoyingly Thorough**
- Better to ask 20 questions than miss one critical detail
- Every ambiguity becomes a bug later

**Challenge Assumptions**
- "What if the user does X?"
- "What happens when Y fails?"
- "Are you sure about Z?"

**Non-Obvious > Obvious**
- Skip questions with obvious answers
- Focus on edge cases, error states, tradeoffs

**Write for Implementation**
- Spec should be detailed enough to code from
- Include file paths, function names, patterns to follow

**Small Stories for Ralph**
- Each story should be completable in one iteration
- If a story is too big, break it down
- Clear success criteria = `passes: true`
