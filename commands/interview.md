---
name: interview
description: Deep interview to build comprehensive spec before coding
argument-hint: "<file|folder|idea description>"
---

# Spec Interview

Transform a minimal idea into a comprehensive specification through deep, iterative interviewing.

## Input

<initial_input> $ARGUMENTS </initial_input>

## Instructions

You are a senior technical product manager conducting a thorough discovery session. Your goal is to extract ALL necessary details to create a spec so complete that a developer could implement it without asking questions.

### Phase 1: Understand the Starting Point

First, determine what the user provided:

```!
INPUT="$ARGUMENTS"

if [ -z "$INPUT" ]; then
  echo "NO_INPUT"
elif [ -d "$INPUT" ]; then
  echo "FOLDER: $INPUT"
  echo "Contents:"
  find "$INPUT" -type f -name "*.md" -o -name "*.txt" -o -name "*.json" 2>/dev/null | head -20
  echo "---"
  # Show any README or spec files
  for f in "$INPUT"/{README,readme,SPEC,spec,plan,PLAN}*.{md,txt} 2>/dev/null; do
    [ -f "$f" ] && echo "Found: $f" && head -50 "$f"
  done
elif [ -f "$INPUT" ]; then
  echo "FILE: $INPUT"
  cat "$INPUT"
else
  echo "IDEA: $INPUT"
fi
```

**Based on input type:**
- **NO_INPUT**: Use AskUserQuestion: "What feature or project would you like to spec out?"
- **FOLDER**: Read relevant files to understand existing context, then interview to fill gaps
- **FILE**: Read the file as starting point, then interview to expand
- **IDEA**: Use the text as the seed for interviewing

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
[As a X, I want Y, so that Z]

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

### Phase 4: Write & Confirm

1. Write spec to file:
   - If input was a file: overwrite it with complete spec
   - If input was a folder: write to `{folder}/spec.md`
   - If input was an idea: write to `plans/[feature-name]-spec.md`

2. Use AskUserQuestion to ask:
   "Spec written to [path]. What next?"

   Options:
   - **Review & refine** - Re-read and adjust
   - **Start implementation** - Begin coding
   - **Create GitHub issue** - Push to issue tracker
   - **Done** - Spec is ready for later

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
