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

This happens in bash before Claude starts working.

---

## Structured Output Control Flow

The hook parses your output for specific XML markers. **You MUST output the exact marker format** for your current phase to advance. Invalid or missing markers trigger retry with guidance.

### Phase Transition Table

| Phase | Name | Required Marker | Attributes | Next Phase |
|-------|------|-----------------|------------|------------|
| 1 | Input Classification | `<phase_complete phase="1"/>` | `feature_name` (required) | 2 |
| 2 | Interview | `<phase_complete phase="2"/>` | `next` (required: "2.5" or "3") | 2.5 or 3 |
| 2.5 | Research | `<phase_complete phase="2.5"/>` | `next` (required: "2") | 2 |
| 3 | Spec Write | `<phase_complete phase="3"/>` | `spec_path` (required) | 3.2 |
| 3.2 | Skill Enrichment | `<phase_complete phase="3.2"/>` | none | 3.5 |
| 3.5 | Review Gate | `<reviews_complete/>` then `<gate_decision>` | PROCEED or BLOCK | 4 (if PROCEED) |
| 4 | PRD Generation | `<phase_complete phase="4"/>` | `prd_path` (required) | 5 |
| 5 | Progress File | `<phase_complete phase="5"/>` | `progress_path` (required) | 5.5 |
| 5.5 | Complexity | `<max_iterations>` | integer N | 6 |
| 6 | Go Command | `<phase_complete phase="6"/>` | none | done |

### Marker Validation Rules

1. **phase attribute must match current phase** - `<phase_complete phase="3"/>` when in phase 2 is ignored
2. **Last marker wins** - If docs/examples contain markers, only the LAST occurrence counts
3. **next attribute validated** - Phase 1→only 2, Phase 2→only 2.5 or 3, Phase 2.5→only 2
4. **reviews marker required first** - Phase 3.5 must output `<reviews_complete/>` before `<gate_decision>`
5. **Retry on invalid** - Wrong marker increments `retry_count`, max 3 retries before asking for help

### Exact Marker Formats

```xml
<!-- Phase 1 -->
<phase_complete phase="1" feature_name="auth-feature"/>

<!-- Phase 2 (after Wave 1, trigger research) -->
<phase_complete phase="2" next="2.5"/>

<!-- Phase 2 (after all waves, go to spec) -->
<phase_complete phase="2" next="3"/>

<!-- Phase 2.5 (return to interview) -->
<phase_complete phase="2.5" next="2"/>

<!-- Phase 3 -->
<phase_complete phase="3" spec_path="plans/auth-feature/spec.md"/>

<!-- Phase 3.2 -->
<phase_complete phase="3.2"/>

<!-- Phase 3.5 -->
<reviews_complete/>
<gate_decision>PROCEED</gate_decision>
<!-- or -->
<gate_decision>BLOCK</gate_decision>

<!-- Phase 4 -->
<phase_complete phase="4" prd_path="plans/auth-feature/prd.json"/>

<!-- Phase 5 -->
<phase_complete phase="5" progress_path="plans/auth-feature/progress.txt"/>

<!-- Phase 5.5 (MUST use agent's value, not guess) -->
<max_iterations>25</max_iterations>

<!-- Phase 6 -->
<phase_complete phase="6"/>
```

---

## Phase Details

### Phase 1: Input Classification

Classify input type (empty/file/folder/idea) and extract feature context.

**Output:** `<phase_complete phase="1" feature_name="SLUG"/>` where SLUG is lowercase-hyphenated.

### Phase 2: Deep Interview

Conduct thorough interview using AskUserQuestion. Interview in waves:

- **Wave 1** (3-4 questions): Core problem, success criteria, MVP scope
- **After Wave 1**: Output `<phase_complete phase="2" next="2.5"/>` to trigger research
- **Waves 2-5** (after research): Technical, UX, edge cases, tradeoffs
- **After 8-10+ questions**: Output `<phase_complete phase="2" next="3"/>` to advance to spec

### Phase 2.5: Research

Spawn ALL research agents IN PARALLEL (single message, multiple Task calls):

```
Task 1: subagent_type="somto-dev-toolkit:prd-codebase-researcher" (max_turns: 30)
Task 2: subagent_type="compound-engineering:research:git-history-analyzer" (max_turns: 30)
Task 3: subagent_type="somto-dev-toolkit:prd-external-researcher" (max_turns: 15)
```

**Optional: agent-browser** for UI/competitor analysis:
```bash
agent-browser open https://competitor.com/feature
agent-browser snapshot -i --json
agent-browser screenshot --full competitor.png
```

**Output:** `<phase_complete phase="2.5" next="2"/>` to return to interview with research context.

### Phase 3: Spec Write

Write comprehensive spec to `plans/<feature>/spec.md`. Include:
- Overview, Problem Statement, Success Criteria
- User Stories (As a X, I want Y, so that Z)
- Functional/Non-Functional Requirements
- Technical Design (Data Models, API Contracts, Implementation Notes)
- Edge Cases, Open Questions, Out of Scope
- Review Findings (populated in Phase 3.5)

**Output:** `<phase_complete phase="3" spec_path="plans/<feature>/spec.md"/>`

### Phase 3.2: Skill Discovery & Enrichment

Discover relevant skills and extract implementation patterns:

1. Search for skills: `~/.claude/skills/**/*.md`, `.claude/skills/**/*.md`
2. Match skills to spec technologies (UI→frontend-design, Rails→dhh-rails-style, etc.)
3. Spawn sub-agents to extract patterns from each skill
4. Add "Implementation Patterns" section to spec

**Output:** `<phase_complete phase="3.2"/>`

### Phase 3.5: Review Gate

Spawn ALL reviewers IN PARALLEL (single message, multiple Task calls):

**Core reviewers (always run):**
```
subagent_type="compound-engineering:workflow:spec-flow-analyzer" (max_turns: 20)
subagent_type="compound-engineering:review:architecture-strategist" (max_turns: 20)
subagent_type="compound-engineering:review:security-sentinel" (max_turns: 20)
subagent_type="compound-engineering:review:performance-oracle" (max_turns: 20)
subagent_type="compound-engineering:review:code-simplicity-reviewer" (max_turns: 15)
subagent_type="compound-engineering:review:pattern-recognition-specialist" (max_turns: 20)
```

**Domain-specific (if applicable):**
```
subagent_type="compound-engineering:review:data-integrity-guardian" (data models)
subagent_type="compound-engineering:review:agent-native-reviewer" (AI features)
```

Add critical findings to spec's "Review Findings" section.

**Output reviews marker first:** `<reviews_complete/>`

**Then output gate decision:** `<gate_decision>PROCEED</gate_decision>` or `<gate_decision>BLOCK</gate_decision>`

If BLOCK, address issues then re-output PROCEED.

### Phase 4: PRD JSON Generation

Generate `plans/<feature>/prd.json` with atomic stories.

**Story size rules (ENFORCE):**
- Each story = ONE iteration (~15-30 min)
- If >7 verification steps → too big, split
- If >3 files touched → consider splitting
- If "and" in title → probably 2 stories

**prd.json schema:**
```json
{
  "title": "feature-name",
  "stories": [
    {
      "id": 1,
      "title": "User can create account",
      "category": "functional|ui|integration|edge-case|performance",
      "skills": ["skill-name-1", "skill-name-2"],
      "steps": ["Step 1", "Step 2", "..."],
      "passes": false,
      "priority": 1
    }
  ],
  "created_at": "ISO8601",
  "source_spec": "plans/<feature>/spec.md"
}
```

**Fields:**
- `id`: Stable reference for progress tracking
- `category`: `functional`, `ui`, `integration`, `edge-case`, `performance`
- `skills`: Array of skill names (required for `ui` category, optional otherwise)
- `steps`: 3-7 explicit verification steps
- `passes`: Starts `false`, set `true` when verified
- `priority`: 1=first (riskier/foundational), higher=later (polish)

**Output:** `<phase_complete phase="4" prd_path="plans/<feature>/prd.json"/>`

### Phase 5: Progress File

Create `plans/<feature>/progress.txt`:

```
# Progress Log: <feature_name>
# Each line: JSON object with ts, story_id, status, notes
# Status values: STARTED, PASSED, FAILED, BLOCKED
```

The /go loop appends JSON lines:
```json
{"ts":"2026-01-21T12:30:00Z","story_id":1,"status":"STARTED","notes":"Beginning story #1"}
{"ts":"2026-01-21T12:45:00Z","story_id":1,"status":"PASSED","notes":"Story #1 complete"}
```

**Output:** `<phase_complete phase="5" progress_path="plans/<feature>/progress.txt"/>`

### Phase 5.5: Complexity Estimation

**MANDATORY**: Spawn the complexity estimator agent. Do NOT skip. Do NOT guess values.

```
Task: subagent_type="somto-dev-toolkit:prd-complexity-estimator" (max_turns: 20)
prompt: "Estimate complexity for this PRD. <prd_json>{read PRD}</prd_json> <spec_content>{read spec}</spec_content>"
```

Wait for agent to return, then output with agent's recommended value:

**Output:** `<max_iterations>N</max_iterations>` where N is from the agent

### Phase 6: Go Command

1. Copy command to clipboard:
```bash
cmd='/go plans/<feature>/prd.json --max-iterations N'
case "$(uname -s)" in
  Darwin) echo "$cmd" | pbcopy ;;
  Linux) echo "$cmd" | xclip -selection clipboard 2>/dev/null || echo "$cmd" | xsel --clipboard 2>/dev/null ;;
  MINGW*|MSYS*|CYGWIN*) echo "$cmd" | clip.exe ;;
esac
```

2. Use AskUserQuestion with options: "Run /go now", "Run /go --once", "Done"

**Output:** `<phase_complete phase="6"/>`

---

## Error Recovery

If you output an invalid marker:
- Hook increments `retry_count` and records `last_error`
- You get the same phase prompt with a note about the expected marker
- After 3 retries, hook pauses for user intervention

Check state file for `retry_count` and `last_error` if stuck.

---

## Key Principles

**Production Quality Always** - Every line will be maintained by others.

**Be Annoyingly Thorough** - Better 20 questions than one missed detail.

**Non-Obvious > Obvious** - Focus on edge cases, error states, tradeoffs.

**Atomic Stories** - Each story = ONE thing, ONE iteration. Independently testable, cleanly revertible.

---

## Cancellation

To cancel: `/cancel-prd` or `rm .claude/prd-loop-*.local.md`
