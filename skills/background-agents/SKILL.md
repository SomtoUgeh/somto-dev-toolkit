---
name: background-agents
description: |
  This skill should be used when launching subagents, running parallel tasks, or when
  the user asks about "background agents", "async agents", "parallel research",
  "non-blocking tasks", "run in background", "continue while agents work", or
  discusses agent orchestration patterns. Covers the run_in_background parameter,
  checking progress, retrieving results, and when to use background vs foreground.
version: 1.0.0
---

# Background Agent Patterns

**The unlock:** Background agents return control to you immediately. Continue discussing,
refine questions, kick off more work while agents run in parallel.

## Launching Background Agents

Add `run_in_background: true` to Task calls for non-blocking execution:

```python
Task(
  subagent_type="compound-engineering:review:security-sentinel",
  prompt="Review spec for security concerns",
  max_turns=20,
  run_in_background=True
)
```

**Result:** Tool returns immediately with `task_id` and `output_file` path.

## Checking Progress

| Method | When to Use |
|--------|-------------|
| `/tasks` | List all background tasks with status |
| `Ctrl+T` | Toggle task list view (up to 10 tasks) |
| `TaskOutput(task_id, block=False)` | Non-blocking check on specific agent |

## Retrieving Results

**Option 1: Wait for completion**
```python
TaskOutput(task_id="abc123", block=True)  # Blocks until agent finishes
```

**Option 2: Read output file**
```python
Read(output_file)  # Path returned when launching background agent
```

**Option 3: Poll periodically**
```python
TaskOutput(task_id="abc123", block=False)  # Check without blocking
```

## Parallel Launch Pattern

Launch multiple agents in ONE message for true parallelism:

```python
# Single message with multiple Task calls
Task(subagent_type="research-agent-1", run_in_background=True)
Task(subagent_type="research-agent-2", run_in_background=True)
Task(subagent_type="research-agent-3", run_in_background=True)
```

**Critical:** Must be in the same message. Sequential messages = sequential execution.

## When to Background

**Use background for:**
- Research agents (Phase 2.5 in PRD workflow)
- Review agents (Phase 3.5 in PRD workflow, pre-commit reviews)
- Any long-running agent (>30 seconds expected)
- Independent investigations that don't gate next step

**Use foreground for:**
- Agents whose output is needed immediately for next step
- Complexity estimator (result determines iteration count)
- When you need to ask follow-up questions based on result

## Workflow Examples

### PRD Research Phase (2.5)

```python
# Launch all research agents in background
Task(subagent_type="prd-codebase-researcher", max_turns=30, run_in_background=True)
Task(subagent_type="git-history-analyzer", max_turns=30, run_in_background=True)
Task(subagent_type="prd-external-researcher", max_turns=15, run_in_background=True)

# While agents run:
# - Prepare Wave 2 interview questions
# - Review spec outline with user
# - Discuss priorities and scope

# When ready, check progress:
/tasks  # or Ctrl+T

# Retrieve results:
TaskOutput(task_id="...", block=True)
```

### Pre-Commit Reviews

```python
# Launch reviewers in background
Task(subagent_type="pr-review-toolkit:code-simplifier", max_turns=15, run_in_background=True)
Task(subagent_type="kieran-typescript-reviewer", max_turns=20, run_in_background=True)

# While reviews run:
# - Polish commit message
# - Run final manual check
# - Prepare for next story

# Retrieve and address findings:
TaskOutput(task_id="...", block=True)
```

## Key Characteristics

| Aspect | Background | Foreground |
|--------|------------|------------|
| Blocks main agent | No | Yes |
| Can ask clarifying questions | No (auto-deny) | Yes |
| MCP tools available | No | Yes |
| Failure handling | Doesn't interrupt main | Surfaces immediately |
| Permission prompts | Auto-inherit approved only | Can request new |

## Common Mistakes

**Mistake 1:** Forgetting `run_in_background=True`
- Agent blocks until complete, losing the parallelism benefit

**Mistake 2:** Sequential Task calls across messages
- Each message waits for previous agents to complete
- Must be in single message for true parallelism

**Mistake 3:** Backgrounding agents that gate next step
- Complexity estimator needs result immediately
- Don't background if you can't proceed without the answer

**Mistake 4:** Not checking results before proceeding
- Background agents may find critical issues
- Always retrieve and address findings before committing
