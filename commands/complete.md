---
name: complete
description: Run reviewers and mark Dex task complete
argument-hint: "<task-id>"
---

# Complete Task Workflow

This command runs the standard review workflow then marks a Dex task complete.

## Usage

```bash
/complete <task-id>
```

## Workflow

1. **Get task details and mark in-progress**:
```bash
dex show <task-id> --full
dex start <task-id>
```

2. **Run reviewers in parallel** (single message, multiple Task calls):

```
Task 1: subagent_type="pr-review-toolkit:code-simplifier" (max_turns: 15)
Task 2: subagent_type="<kieran-reviewer>" (max_turns: 20)
```

**Kieran reviewer by language:**
- TypeScript/JavaScript: `compound-engineering:review:kieran-typescript-reviewer`

**Add if applicable:**
- Database/migrations: `compound-engineering:review:data-integrity-guardian`
- Frontend races: `compound-engineering:review:julik-frontend-races-reviewer`

3. **Address ALL findings** from reviewers

4. **Commit** with task reference:
```bash
git commit -m "feat(<scope>): <task-id> - <title>"
```

5. **Mark task complete with verified result**:
```bash
dex complete <task-id> --result "What changed: <implementation summary>. Verification: <N> tests passing, build success, lint clean. Reviewers: code-simplifier and kieran findings addressed."
```

**Result must include verification, not claims:**
- ✅ "Added login endpoint. 24 tests passing. Build success."
- ❌ "Should work now" or "Made the changes"

6. **Show next ready task**:
```bash
dex list --ready
```

## Example

```bash
/complete abc123
```

Runs reviewers, addresses findings, commits, then:
```bash
dex complete abc123 --result "Implemented login form. Verification: 5 tests passing, build success. Reviewers addressed."
```

## Quality Gates

All must pass before marking complete:
- [ ] All acceptance criteria verified
- [ ] Tests pass
- [ ] Lint/typecheck pass
- [ ] Reviewers ran and findings addressed
- [ ] Committed with task reference

## Notes

- If `<task-id>` not provided, check `dex list --in-progress` for current task
- Use `dex list --ready` to see unblocked tasks
- Skills from task metadata should already be loaded (load with `/<skill-name>` if not)
