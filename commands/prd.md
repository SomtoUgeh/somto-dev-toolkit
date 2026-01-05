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

### Phase 2.5: Research (after Wave 1, before Wave 2)

After Wave 1 answers establish core problem/user context, **PAUSE interviewing** and run research. Store findings in `<research_findings>` for Phase 3.

**Step 1: Codebase Research**

Use Task tool with subagent_type="Explore":
```
<task_prompt>
Search codebase for existing implementations related to <feature_topic>.
Find: existing patterns, similar features, models touched, services involved.
Return: file paths, code snippets, patterns to follow.
</task_prompt>
```

Also check `plans/` folder for existing specs:
```bash
ls plans/
```

**Step 2: External Research (Exa)**

Use Task tool with subagent_type="general-purpose":
```
<task_prompt>
Use Exa MCP tools to research <feature_topic>:
1. mcp__exa__get_code_context_exa - find code examples for <technology> <feature_type>
2. mcp__exa__web_search_exa - find best practices 2025
Return: code snippets, key recommendations, links.
</task_prompt>
```

**Step 3: Skill Application (conditional)**

- If UI/frontend mentioned → use Task with subagent_type="general-purpose" to apply frontend-design skill
- If API/data models mentioned → note architecture patterns for spec
- If auth/sensitive data mentioned → flag for Phase 3.5 security review

**Step 4: Store findings**

Collect all research outputs into:
```
<research_findings>
  <codebase_patterns>...</codebase_patterns>
  <existing_specs>...</existing_specs>
  <exa_recommendations>...</exa_recommendations>
  <skill_insights>...</skill_insights>
</research_findings>
```

**Then continue to Wave 2** with research context. Use findings to ask informed questions (e.g., "I found a similar pattern in X, should we follow that?")

### Phase 3: Synthesize & Write Spec

After thorough interviewing (minimum 10-15 questions answered), write the spec.

**Incorporate `<research_findings>` from Phase 2.5:**
- `<codebase_patterns>` → add to "Implementation Notes"
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

**Required Reviewers (spawn all 3 using Task tool in single message):**

Use Task tool with subagent_type for each:

Use the spec content written in Phase 3 (store as `<spec_content>` variable).

```
<reviewer_1>
subagent_type: "compound-engineering:workflow:spec-flow-analyzer"
<task_prompt>
<spec_content>{spec written in Phase 3}</spec_content>
Analyze for user flows, edge cases, missing scenarios.
Return: missing flows, edge cases not covered, flow gaps.
</task_prompt>
</reviewer_1>

<reviewer_2>
subagent_type: "compound-engineering:review:architecture-strategist"
<task_prompt>
<spec_content>{spec written in Phase 3}</spec_content>
Review for architectural soundness.
Return: component boundary issues, dependency concerns, design principle violations.
</task_prompt>
</reviewer_2>

<reviewer_3>
subagent_type: "compound-engineering:review:security-sentinel"
<task_prompt>
<spec_content>{spec written in Phase 3}</spec_content>
Scan for security gaps.
Return: auth issues, data exposure risks, input validation gaps, OWASP concerns.
</task_prompt>
</reviewer_3>
```

**Conditional Reviewers:**
- If UI work detected → also spawn with subagent_type="compound-engineering:design:design-implementation-reviewer"
- If touching existing code → also spawn with subagent_type="compound-engineering:review:pattern-recognition-specialist"

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

**Write to `plans/<feature_name>/prd.json`:**

```json
{
  "title": "<feature_name>",
  "stories": [
    {"id": 1, "title": "User can create account", "passes": false, "priority": 1},
    {"id": 2, "title": "User can login", "passes": false, "priority": 2}
  ],
  "created_at": "<iso8601_timestamp>",
  "source_spec": "plans/<feature_name>/spec.md"
}
```

All stories start with `passes: false`. Priority is order of appearance (1 = first).

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

Before generating Ralph command, estimate implementation complexity using **actual research, not just reasoning**.

Use Task tool with subagent_type="general-purpose":

```
<task_prompt>
Estimate implementation complexity for this PRD. You MUST use tools to research, not just reason.

<prd_json>{PRD JSON written in Phase 4}</prd_json>
<spec_content>{spec written in Phase 3}</spec_content>

**Required research steps:**

1. **Codebase analysis** - Use Glob/Grep to find:
   - Similar existing implementations
   - Files that will likely need modification
   - Existing patterns to follow

2. **Dependency check** - For each external dep:
   - Check if already in package.json
   - Verify compatibility with project

3. **Test coverage scan** - Use Glob to find:
   - Existing test patterns
   - Test file locations

**Then estimate for each story:**
- Files touched (actual count from research)
- New vs modify (based on what exists)
- Integration complexity (based on deps found)
- Test complexity (based on existing test patterns)

Return:
<complexity_estimate>
  <research_summary>What you found in codebase</research_summary>
  <per_story_scores>story_id: score (1-5) with justification</per_story_scores>
  <total_iterations>sum of scores × 2</total_iterations>
  <risk_factors>blocking dependencies, unknowns found</risk_factors>
  <recommended_max_iterations>total + 20% buffer, minimum 20</recommended_max_iterations>
</complexity_estimate>
</task_prompt>
```

Store `<recommended_max_iterations>` value for Phase 6.

### Phase 6: Generate Ralph Command

Build the ralph-loop command with correct file paths:

```
/ralph-wiggum:ralph-loop "Execute PRD at plans/<feature_name>/prd.json

1. Read plans/<feature_name>/spec.md
2. Read plans/<feature_name>/prd.json
3. Read plans/<feature_name>/progress.txt for context

Read all files in their entirety.

For each story where passes=false (in priority order):
  a. Implement the story
  b. Write/update tests
  c. Run format, lint, tests, and types
  d. If tests pass:
     - Update PRD: set story.passes = true
     - Append to progress.txt: {\"ts\":\"<now>\",\"story_id\":<id>,\"status\":\"PASSED\",\"notes\":\"<summary>\"}
  e. If tests fail:
     - Append to progress.txt: {\"ts\":\"<now>\",\"story_id\":<id>,\"status\":\"FAILED\",\"notes\":\"<error>\"}
     - Fix and retry

Commit after each story. Keep CI green (format, lint, tests + types must pass).

Output <promise>All stories pass</promise> when ALL stories have passes=true" --completion-promise "All stories pass" --max-iterations <recommended_max_iterations>
```

**Copy command to clipboard using Bash:**
```bash
echo '<command>' | pbcopy
```

**Then use AskUserQuestion:**
"PRD ready! Files created:
- `plans/<feature_name>/spec.md`
- `plans/<feature_name>/prd.json`
- `plans/<feature_name>/progress.txt`

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
