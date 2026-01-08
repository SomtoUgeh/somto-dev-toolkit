---
name: prd
description: Deep interview to build PRD for new features or enhancements
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

### Phase 2.5: Research (after Wave 1, before Wave 2)

After Wave 1 answers establish core problem/user context, **PAUSE interviewing** and run research. Store findings in `<research_findings>` for Phase 3.

**IMPORTANT: Spawn all 3 research agents IN PARALLEL using a single message with multiple Task tool calls.**

```
# In a SINGLE message, spawn all 3:

Task 1: Codebase Research
- subagent_type: "prd-codebase-researcher"
- prompt: "Research codebase for <feature_topic>. Find existing patterns, files to modify, models, services, test patterns. Check plans/ folder for existing specs."

Task 2: Git History Analysis
- subagent_type: "compound-engineering:research:git-history-analyzer"
- prompt: "Analyze git history for code related to <feature_topic>. Find: prior attempts, key contributors, why patterns evolved, past decisions/constraints."

Task 3: External Research
- subagent_type: "prd-external-researcher"
- prompt: "Research <feature_topic> using Exa. Find: best practices 2024-2025, code examples, documentation, pitfalls to avoid."
```

**Conditional research (spawn alongside above if applicable):**

- If UI/frontend mentioned → also spawn `subagent_type="general-purpose"` to apply frontend-design skill
- If auth/sensitive data mentioned → flag for Phase 3.5 security review

**After all agents return**, collect outputs into:

```
<research_findings>
  <codebase_patterns>...</codebase_patterns>
  <git_history>...</git_history>
  <exa_recommendations>...</exa_recommendations>
  <skill_insights>...</skill_insights>
</research_findings>
```

**Then continue to Wave 2** with research context. Use findings to ask informed questions (e.g., "I found a similar pattern in X, should we follow that?")

### Phase 3: Synthesize & Write Spec

After thorough interviewing (minimum 10-15 questions answered), write the spec.

**Incorporate `<research_findings>` from Phase 2.5:**
- `<codebase_patterns>` → add to "Implementation Notes"
- `<git_history>` → add to "Implementation Notes" (prior attempts, constraints, contributors to consult)
- `<exa_recommendations>` → add to "Technical Design" and "Non-Functional Requirements"
- `<existing_specs>` → reference in "References"
- `<skill_insights>` → apply to relevant sections

**Spec Structure:**

```markdown
# <feature_name> Specification

## Overview
<one_paragraph_summary>

## Problem Statement
<problem_and_audience>

## Success Criteria
<measurable_outcomes>

## User Stories
<user_stories_list>
As a X, I want Y, so that Z - one per line, these become PRD items

## Detailed Requirements

### Functional Requirements
<specific_behaviors_with_edge_cases>

### Non-Functional Requirements
<performance_security_accessibility>

### UI/UX Specifications
<flows_states_error_handling>

## Technical Design

### Data Models
<schema_changes_relationships>

### API Contracts
<endpoints_request_response_shapes>

### System Interactions
<services_systems_touched>

### Implementation Notes
<patterns_to_follow_files_to_reference>
(incorporate <codebase_patterns> from research)

## Edge Cases & Error Handling
<comprehensive_list_from_interview>

## Open Questions
<unresolved_items>

## Out of Scope
<explicitly_excluded>

## Review Findings
<phase_3_5_reviewer_feedback>
(populated from <review_feedback>)

## References
<related_files_docs_prior_art>
(incorporate <existing_specs> from research)
```

Write spec to file:
- If input was a file: overwrite it with complete spec
- If input was a folder: write to `<folder>/spec.md`
- If input was an idea: create `plans/<feature_name>/` folder, write to `plans/<feature_name>/spec.md`

### Phase 3.5: Spec Review (before PRD generation)

After writing spec, spawn review agents to catch issues before generating PRD.

**IMPORTANT: Spawn all 3 reviewers IN PARALLEL using a single message with multiple Task tool calls.**

Store the spec content from Phase 3 as `<spec_content>` to pass to each reviewer.

```
# In a SINGLE message, spawn all 3:

Task 1: Flow Analysis
- subagent_type: "compound-engineering:workflow:spec-flow-analyzer"
- prompt: "<spec_content>{spec}</spec_content> Analyze for user flows, edge cases, missing scenarios. Return: missing flows, edge cases not covered, flow gaps."

Task 2: Architecture Review
- subagent_type: "compound-engineering:review:architecture-strategist"
- prompt: "<spec_content>{spec}</spec_content> Review for architectural soundness. Return: component boundary issues, dependency concerns, design principle violations."

Task 3: Security Review
- subagent_type: "compound-engineering:review:security-sentinel"
- prompt: "<spec_content>{spec}</spec_content> Scan for security gaps. Return: auth issues, data exposure risks, input validation gaps, OWASP concerns."
```

**Conditional Reviewers (spawn alongside above if applicable):**
- If UI work detected → also spawn `subagent_type="compound-engineering:design:design-implementation-reviewer"`
- If touching existing code → also spawn `subagent_type="compound-engineering:review:pattern-recognition-specialist"`

**Synthesis:**

Store all review outputs in `<review_feedback>`:
```
<review_feedback>
  <flow_issues>...</flow_issues>
  <architecture_issues>...</architecture_issues>
  <security_issues>...</security_issues>
</review_feedback>
```

1. Add critical items to spec's "Review Findings" section
2. Update User Stories if reviewers found missing flows
3. Flag unresolved concerns in "Open Questions"

**Gate:**

If critical security/architecture issues found, use AskUserQuestion:
"Reviewers found <issues_summary>. Address now or proceed to PRD generation?"

Options:
- **Address issues** - Update spec with fixes
- **Proceed anyway** - Generate PRD with noted concerns

**Re-review clause (max 1 re-review):**

If addressing issues results in major spec changes (new user stories, architectural pivots, or scope changes), re-run the 3 required reviewers **once**. After 1 re-review, proceed to Phase 4 regardless. Minor fixes don't require re-review.

### Phase 4: Generate PRD JSON

Parse the User Stories section from the spec and create a PRD JSON file.

**Extract stories from:**
- Lines matching `As a X, I want Y, so that Z`
- Checkbox items like `- [ ] User can...`
- Numbered items in User Stories section

**For each story, generate:**
- `category`: Infer from story context (functional, ui, integration, edge-case, performance)
- `skill`: If category is `ui`, set to `"frontend-design"`. Omit for non-UI stories.
- `steps`: 3-7 explicit verification steps based on spec details and edge cases section
- `priority`: Assign based on risk and dependency order:
  1. Architectural decisions - foundations that everything else builds on
  2. Integration points - where modules connect, reveals incompatibilities early
  3. Unknown unknowns - risky spikes, fail fast rather than fail late
  4. Standard features - straightforward implementation
  5. Polish and cleanup - can be deferred or parallelized

**Story size rules (ENFORCE THESE):**
- Each story = ONE iteration of /go (aim for ~15-30 min of work)
- If a story has >7 verification steps, it's too big → break it down
- If a story touches >3 files, consider splitting by file/layer
- If a story has "and" in the title, it's probably 2 stories
- When in doubt, make stories smaller - small steps compound into big progress

**Write to `plans/<feature_name>/prd.json`:**

```json
{
  "title": "<feature_name>",
  "stories": [
    {
      "id": 1,
      "title": "User can create account",
      "category": "functional",
      "steps": [
        "Navigate to signup page",
        "Fill required fields (email, password)",
        "Submit registration form",
        "Verify user record created in database",
        "Verify redirect to dashboard"
      ],
      "passes": false,
      "priority": 1
    },
    {
      "id": 2,
      "title": "User can login",
      "category": "functional",
      "steps": [
        "Navigate to login page",
        "Enter valid credentials",
        "Submit login form",
        "Verify session created",
        "Verify redirect to dashboard"
      ],
      "passes": false,
      "priority": 2
    },
    {
      "id": 3,
      "title": "Design login page with branded styling",
      "category": "ui",
      "skill": "frontend-design",
      "steps": [
        "Apply brand colors and typography",
        "Add logo and visual hierarchy",
        "Implement responsive layout",
        "Add micro-interactions and hover states",
        "Verify visual consistency with design system"
      ],
      "passes": false,
      "priority": 3
    }
  ],
  "created_at": "<iso8601_timestamp>",
  "source_spec": "plans/<feature_name>/spec.md"
}
```

**Story fields:**
- `id`: Stable reference for progress.txt
- `title`: Brief description
- `category`: `functional`, `ui`, `integration`, `edge-case`, `performance`
- `steps`: Explicit verification steps (agent knows when done)
- `passes`: Starts `false`, set `true` when all steps verified
- `priority`: Processing order (1 = first). Lower = riskier/foundational, higher = safer/polish

### Phase 5: Create Progress File

Write to `plans/<feature_name>/progress.txt`:

```
# Progress Log: <feature_name>
# Each line: JSON object with ts, story_id, status, notes
# Status values: STARTED, PASSED, FAILED, BLOCKED
```

This file starts empty (just the header). Ralph iterations will append JSON lines like:
```json
{"ts":"2026-01-04T12:30:00Z","story_id":1,"status":"PASSED","notes":"implemented auth flow"}
```

### Phase 5.5: Complexity Estimation

Before generating go command, estimate implementation complexity using **actual research, not just reasoning**.

Use the dedicated complexity estimator agent:

```
Task: Complexity Estimation
- subagent_type: "prd-complexity-estimator"
- prompt: |
    Estimate implementation complexity for this PRD.

    <prd_json>{PRD JSON written in Phase 4}</prd_json>
    <spec_content>{spec written in Phase 3}</spec_content>

    Research the codebase to find similar implementations, count files to modify,
    check dependencies, and analyze test requirements. Return per-story scores
    and recommended max_iterations.
```

Store `<recommended_max_iterations>` value for Phase 6.

### Phase 6: Generate Go Command

Build the go command with the PRD path:

```
/go plans/<feature_name>/prd.json --max-iterations <recommended_max_iterations>
```

**Copy command to clipboard using Bash (cross-platform):**
```bash
# Detect OS and copy to clipboard
cmd='/go plans/<feature_name>/prd.json --max-iterations <recommended_max_iterations>'
case "$(uname -s)" in
  Darwin) echo "$cmd" | pbcopy ;;
  Linux) echo "$cmd" | xclip -selection clipboard 2>/dev/null || echo "$cmd" | xsel --clipboard 2>/dev/null ;;
  MINGW*|MSYS*|CYGWIN*) echo "$cmd" | clip.exe ;;
esac
```

**Then use AskUserQuestion:**
"PRD ready! Files created:
- `plans/<feature_name>/spec.md`
- `plans/<feature_name>/prd.json`
- `plans/<feature_name>/progress.txt`

Go command copied to clipboard. What next?"

Options:
- **Run /go now** - Full loop, let it run
- **Run /go --once** - HITL mode, review each story before continuing (recommended for auth, payments, migrations, or first-time PRDs)
- **Done** - Files ready for later

---

## Key Principles

**Production Quality Always**
- Treat ALL code as production code. No shortcuts, no "good enough for now"
- Every line will be maintained, extended, and debugged by others
- Fight entropy

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

**Code Style Guidelines**
- MINIMAL COMMENTS - code should be self-documenting
- Only comment the non-obvious "why", never the "what"
- Tests should live next to the code they test (colocation)

**Small Stories for /go**
- Each story = ONE iteration (~15-30 min of work)
- If >7 steps or >3 files or "and" in title → break it down
- Clear success criteria = `passes: true`
- Small steps compound into big progress
- A story that takes multiple iterations is a failed story
