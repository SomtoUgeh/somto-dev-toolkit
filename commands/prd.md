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

The hook uses **file existence as primary truth** (ralph-loop pattern). Markers are optional but recommended for explicit control, except Phase 3.5 which requires `<reviews_complete/>` and `<gate_decision>`. If you complete the work but forget the marker, the hook detects file existence and auto-advances (where allowed).

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
| 5 | Verify PRD | `<phase_complete phase="5"/>` | none | 5.5 |
| 5.5 | Complexity | `<max_iterations>` | integer N | 6 |
| 6 | Go Command | `<phase_complete phase="6"/>` | none | done |

### Detection Priority (File > Marker)

1. **File existence is truth** - If `plans/<feature>/spec.md` exists, phase 3 is considered complete
2. **Markers are explicit signals** - Still work and take precedence when present
3. **Last marker wins** - If docs/examples contain markers, only the LAST occurrence counts
4. **Auto-discovery** - Paths follow convention: `plans/<feature>/{spec.md,prd.json}`
5. **Continuous loop** - Never stops on missing markers; keeps prompting until work is done
6. **Phase 3.5 gate** - No file-based auto-advance; requires explicit `<gate_decision>`

### File-Based Auto-Advance

| Phase | Auto-Advances When |
|-------|-------------------|
| 3 | `plans/<feature>/spec.md` exists |
| 3.2 | spec.md contains "## Implementation Patterns" |
| 3.5 | No auto-advance (requires `<reviews_complete/>` + `<gate_decision>`) |
| 4 | `plans/<feature>/prd.json` exists and is valid JSON |
| 5 | `plans/<feature>/prd.json` has `log` array |
| 5.5 | `prd.json` contains `max_iterations` field (any positive integer) |
| 6 | All three files exist → **loop complete** |

### Marker Validation Rules (When Using Markers)

1. **phase attribute must match current phase** - `<phase_complete phase="3"/>` when in phase 2 is ignored
2. **next attribute validated** - Phase 1→only 2, Phase 2→only 2.5 or 3, Phase 2.5→only 2
3. **reviews marker required first** - Phase 3.5 must output `<reviews_complete/>` before `<gate_decision>`

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
<phase_complete phase="5"/>

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

#### Required Agent Output Formats

The SubagentStop hook validates each agent returns structured findings. Agents that return empty or unstructured output will be blocked and asked to retry.

**prd-codebase-researcher must return:**
```markdown
## Existing Patterns
- [description of patterns found in codebase]

## Files to Modify
- `path/to/file.ts` - [reason for modification]

## Models/Services Involved
- [relevant models, services, or modules]
```

**prd-external-researcher must return:**
```markdown
## Best Practices
- [industry recommendations]

## Code Examples
- [relevant snippets from documentation/repos]

## Pitfalls to Avoid
- [common mistakes, anti-patterns]
```

**git-history-analyzer must return:**
```markdown
## History
- [relevant commits and their context]

## Evolution
- [how the code evolved over time]

## Contributors
- [key contributors and their expertise areas]
```

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

#### Required Review Agent Output

The SubagentStop hook validates each reviewer returns actionable feedback. Reviews with empty output or no findings/recommendations will be blocked.

**All review agents must include at least one of:**
- Specific findings (issues, concerns, warnings)
- Recommendations or suggestions
- Explicit "no issues found" / "approved" statement

**Example review output structure:**
```markdown
## Findings
- **Critical**: [issue requiring immediate attention]
- **High**: [significant concern]
- **Medium**: [improvement opportunity]

## Recommendations
- [specific actionable suggestions]

## Approved Areas
- [aspects that look good]
```

**Output reviews marker first:** `<reviews_complete/>`

**Then output gate decision:** `<gate_decision>PROCEED</gate_decision>` or `<gate_decision>BLOCK</gate_decision>`

If BLOCK, address issues then re-output PROCEED.

### Phase 4: PRD JSON Generation

Generate `plans/<feature>/prd.json` with **atomic** stories.

**Story size rules (ENFORCE):**
- Each story = ONE iteration (~15-30 min)
- If >7 verification steps → too big, split
- If >3 files touched → consider splitting
- If "and" in title → probably 2 stories

**prd.json schema (single source of truth):**
```json
{
  "title": "feature-name",
  "spec_path": "plans/<feature>/spec.md",
  "created_at": "ISO8601",
  "stories": [
    {
      "id": 1,
      "title": "User can create account",
      "category": "functional|ui|integration|edge-case|performance",
      "skills": ["skill-name-1", "skill-name-2"],
      "steps": ["Step 1", "Step 2", "..."],
      "passes": false,
      "priority": 1,
      "completed_at": null,
      "commit": null
    }
  ],
  "log": []
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

### Phase 5: Verify PRD Structure

Verify prd.json has required structure:
- `log` array exists (initialized empty, hook appends)
- All stories have `completed_at: null` and `commit: null`

The /go loop will append log entries like:
```json
{"ts":"2026-01-21T12:30:00Z","event":"story_started","story_id":1}
{"ts":"2026-01-21T12:45:00Z","event":"story_complete","story_id":1,"commit":"abc123"}
```

**NOTE:** No separate progress.txt - log is embedded in prd.json.

**Output:** `<phase_complete phase="5"/>`

### Phase 5.5: Complexity Estimation

**MANDATORY**: Spawn the complexity estimator agent. Do NOT skip. Do NOT guess values.

```
Task: subagent_type="somto-dev-toolkit:prd-complexity-estimator" (max_turns: 20)
prompt: "Estimate complexity for this PRD. <prd_json>{read PRD}</prd_json> <spec_content>{read spec}</spec_content>"
```

Wait for agent to return, then output with agent's recommended value.

**Complexity estimator must return:**
```xml
<max_iterations>N</max_iterations>
```
Where N is the value from the agent (recommended range: 5-100).

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

**Output (any of these work):**
- `<phase_complete phase="6"/>` - explicit marker
- `<promise>PRD COMPLETE</promise>` - completion promise (immediate exit)
- If all files exist, loop auto-completes

---

## SubagentStop Quality Gates

The PRD workflow uses SubagentStop hooks to validate agent output quality before they complete. This prevents:
- Research agents returning empty or unstructured findings
- Review agents providing no actionable feedback
- Complexity estimator failing silently

**How it works:**
1. When a subagent (Task tool) finishes, SubagentStop hook fires
2. Hook validates output against expected format for that agent type
3. If invalid: agent is blocked with guidance, must retry
4. If valid: agent completes normally

**Validated agent types:**
| Agent | Required Output |
|-------|----------------|
| prd-codebase-researcher | `## Existing Patterns`, `## Files to Modify`, or `## Models` |
| prd-external-researcher | `## Best Practices`, `## Code Examples`, or `## Pitfalls` |
| git-history-analyzer | `## History`, `## Evolution`, or `## Contributors` |
| prd-complexity-estimator | `<max_iterations>N</max_iterations>` (positive integer) |
| All review agents | Findings, recommendations, or explicit "no issues" |

---

## Continuous Loop Behavior

Unlike retry-based loops, the PRD workflow **never stops on missing markers**:
- Hook increments `phase_iteration` and continues prompting
- File-based detection handles most cases automatically
- No max retries - just keeps working until files exist

**Completion signals:**
1. Phase 6 marker: `<phase_complete phase="6"/>`
2. File detection: spec.md and prd.json exist in `plans/<feature>/`
3. Explicit promise: `<promise>PRD COMPLETE</promise>` (immediate exit)

---

## Key Principles

**Production Quality Always** - Every line will be maintained by others.

**Be Annoyingly Thorough** - Better 20 questions than one missed detail.

**Non-Obvious > Obvious** - Focus on edge cases, error states, tradeoffs.

**Atomic Stories** - Each story = ONE thing, ONE iteration. Independently testable, cleanly revertible.

---

## Cancellation

To cancel: `/cancel-prd` or `rm .claude/prd-loop-*.local.md`
