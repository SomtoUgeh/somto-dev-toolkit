---
name: go-help
description: Help for the go loop command
---

# Go Loop Help

The `/go` command provides iterative task execution in two modes.

## Generic Mode

Like ralph-wiggum - loop on any task until completion.

```bash
/go "Your task description" --completion-promise "DONE" --max-iterations 30
```

**How it works:**
1. Creates state file with your prompt
2. You work on the task
3. When done, output `<promise>DONE</promise>`
4. If you try to exit without the promise, the hook feeds the prompt back
5. Loop continues until promise detected or max iterations reached

**Options:**
- `--completion-promise TEXT` (required): The exact text to output when done
- `--max-iterations N` (default: 50): Safety limit
- `--once`: Single iteration, then stop (HITL mode)

## PRD Mode

For structured development with PRD files from `/prd`.

```bash
/go plans/feature/prd.json
/go --prd plans/feature/prd.json
```

**How it works:**
1. Reads prd.json, finds first incomplete story
2. You implement the story, run tests, update prd.json
3. **Run parallel reviews** (code-simplifier + Kieran reviewer in single message)
4. Commit with story reference
5. Hook verifies: story passes, reviews done, commit exists
6. Automatically advances to next story
7. Completes when all stories pass

**Features:**
- Auto-detects `.json` files
- Strict commit verification before advancing
- Auto-logs to progress.txt
- Shows story progress in system messages

## HITL Mode (--once)

Single iteration for learning, debugging, or risky tasks.

```bash
/go plans/auth/prd.json --once
/go "Fix the bug" --completion-promise "FIXED" --once
```

**How it works:**
1. Runs ONE iteration
2. After completion, stops for your review
3. Run `/go` again to continue (with or without `--once`)

**Use cases:**
- Learning how the loop works
- Testing/debugging prompts before going AFK
- Risky tasks (auth, payments, migrations) where you want to approve each step
- Building trust before switching to full loop

## Commands

- `/go` - Start a go loop
- `/cancel-go` - Stop active loop
- `/go-help` - This help

## Branch Setup

When starting on main/master, setup prompts to create a feature branch. This happens before Claude starts working.

## State File

Both modes use `.claude/go-loop-<session>.local.md` which contains:
- YAML frontmatter with mode, iteration, settings, working_branch
- Current prompt/task below the frontmatter

## Examples

**Generic - Build a feature:**
```
/go "Implement user authentication with JWT tokens" --completion-promise "AUTH COMPLETE"
```

**PRD - Execute a spec:**
```
/go plans/auth/prd.json
```

**With custom iteration limit:**
```
/go "Refactor the database layer" --completion-promise "REFACTOR DONE" --max-iterations 100
```

**HITL mode - one story at a time:**
```
/go plans/auth/prd.json --once
```
