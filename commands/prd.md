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

You are now in a phased PRD workflow. The stop hook will advance you through phases based on structured output markers.

## Phases

| Phase | Name | Your Output | Next |
|-------|------|-------------|------|
| 1 | Input Classification | `<phase_complete phase="1" feature_name="NAME"/>` | 2 |
| 2 | Interview (waves) | `<phase_complete phase="2" next="2.5"/>` or `next="3"` | 2.5 or 3 |
| 2.5 | Research | `<phase_complete phase="2.5" next="2"/>` | 2 (continue) |
| 3 | Spec Write | `<phase_complete phase="3" spec_path="..."/>` | 3.2 |
| 3.2 | Skill Enrichment | `<phase_complete phase="3.2"/>` | 3.5 |
| 3.5 | Review Gate | `<gate_decision>PROCEED</gate_decision>` | 4 |
| 4 | PRD Gen | `<phase_complete phase="4" prd_path="..."/>` | 5 |
| 5 | Progress File | `<phase_complete phase="5" progress_path="..."/>` | 5.5 |
| 5.5 | Complexity | `<max_iterations>N</max_iterations>` | 6 |
| 6 | Go Command | `<phase_complete phase="6"/>` | done |

## Your Task

Read the state file (path shown in setup output) for your current phase prompt.
Complete the phase task and output the appropriate marker.

## Phase Details

### Phase 1: Input Classification
Classify the input (empty/file/folder/idea) and extract feature context.

### Phase 2: Deep Interview
Conduct thorough interview using AskUserQuestion. After Wave 1 (3-4 questions), trigger research phase with `next="2.5"`. After all waves complete (8-10+ questions), advance to spec with `next="3"`.

### Phase 2.5: Research
Spawn 3+ research agents IN PARALLEL (with max_turns):
- somto-dev-toolkit:prd-codebase-researcher (max_turns: 30)
- compound-engineering:research:git-history-analyzer (max_turns: 30)
- somto-dev-toolkit:prd-external-researcher (max_turns: 15)

**Optional: agent-browser** for UI/UX features or competitor analysis:
```bash
agent-browser open https://competitor.com/feature
agent-browser snapshot -i --json    # Get interactive elements with refs
agent-browser screenshot --full competitor.png
```
Use when you need visual examples, competitor implementations, or live docs extraction.

### Phase 3: Spec Write
Synthesize interview + research into comprehensive spec at `plans/<feature>/spec.md`.

### Phase 3.2: Skill Enrichment
Discover relevant skills (dhh-rails-style, frontend-design, agent-native-architecture, etc.) and spawn sub-agents to extract implementation patterns. Add "Implementation Patterns" section to spec.

### Phase 3.5: Review Gate (Multi-Dimensional)
Spawn 6-8 reviewers IN PARALLEL (all max_turns: 15-20):

**Core (always run):**
- spec-flow-analyzer, architecture-strategist, security-sentinel
- performance-oracle, code-simplicity-reviewer, pattern-recognition-specialist

**Domain-specific (if applicable):**
- data-integrity-guardian (data models), agent-native-reviewer (AI features)

Add findings to spec. Output `<gate_decision>PROCEED</gate_decision>` or `BLOCK`.

### Phase 4: PRD JSON
Generate `plans/<feature>/prd.json` with atomic stories. Each story must be: single responsibility, independently testable, no partial state, cleanly revertible.

### Phase 5: Progress File
Create `plans/<feature>/progress.txt` header.

### Phase 5.5: Complexity
**MANDATORY**: Spawn somto-dev-toolkit:prd-complexity-estimator (max_turns: 20) using Task tool. Do NOT skip. Do NOT guess values. Wait for agent, then output `<max_iterations>N</max_iterations>` with agent's value.

### Phase 6: Go Command
Copy go command to clipboard, ask user what to do next.

## Key Principles

**Production Quality Always** - Every line will be maintained by others.

**Be Annoyingly Thorough** - Better 20 questions than one missed detail.

**Non-Obvious > Obvious** - Focus on edge cases, error states, tradeoffs.

**Atomic Stories** - Each story = ONE thing, ONE iteration (~15-30 min). Must be independently testable and cleanly revertible. If "and" in title, split it.

## Cancellation

To cancel: `/cancel-prd` or remove `.claude/prd-loop-*.local.md`
