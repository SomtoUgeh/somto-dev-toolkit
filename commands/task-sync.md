---
name: task-sync
description: "Sync active loop state to Claude's Task system for visibility"
allowed-tools: ["TaskCreate", "TaskUpdate", "TaskList", "Read", "Glob", "Bash(ls .claude/*-loop-*.local.md:*)", "Bash(jq *)"]
context: fork
agent: general-purpose
---

# /task-sync - Sync Loop State to Tasks

Sync your active loop (go, ut, e2e) work items to Claude's Task system for Ctrl+T visibility.

**Session:** `${CLAUDE_SESSION_ID}`

## Current Loop State

Active state files:
!`ls .claude/*-loop-*.local.md 2>/dev/null || echo "NONE"`

## Your Task

1. **If no state file above (shows "NONE"):** Say "No active loop found. Start a loop with /go, /ut, or /e2e first."

3. **Parse loop type from frontmatter** (between first two `---` lines):
   - Read `loop_type:` field
   - Read `task_list_synced:` field

4. **If task_list_synced: true:** Say "Tasks already synced for this loop. Use Ctrl+T to view."

5. **Based on loop type, sync work items:**

### go (PRD mode)
- Read `prd_path:` from state file
- Load prd.json, get stories array
- For each story with `passes: false`:
  ```
  TaskCreate({
    subject: "Story {id}: {title}",
    description: "Steps:\n- {step1}\n- {step2}...",
    activeForm: "Implementing story {id}",
    metadata: { loop: "go", prd_path: "{path}", story_id: {id} }
  })
  ```
- Set `blockedBy` based on priority (lower priority blocks higher)
- **Update state file:** Edit frontmatter to set:
  - `task_list_synced: true`
  - `story_tasks: '{"1": "task-id-1", "2": "task-id-2", ...}'`

### ut (unit test loop)
- Read `state_json:` from state file
- For coverage analysis: Call `TaskCreate` for each file with gap
- **Update state file:** Set `task_list_synced: true` and `file_tasks: '{...}'`

### e2e (E2E test loop)
- Read `state_json:` from state file
- For flow identification: Call `TaskCreate` for each flow
- Set `blockedBy` for dependent flows
- **Update state file:** Set `task_list_synced: true` and `flow_tasks: '{...}'`

6. **Output marker:** `<tasks_synced/>`

7. **Report:** "Synced {N} tasks. Use Ctrl+T to view progress."

## Important Notes

- Domain state (prd.json) is always authoritative
- Tasks are a view layer, not source of truth
- If tasks and domain state diverge, re-sync from domain state
- The hook will include task_id in prompts once story_tasks is populated
