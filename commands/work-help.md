---
name: work-help
description: Help for the work loop command
---

# Work Loop Help

The `/work` command provides iterative task execution in two modes.

## Generic Mode

Like ralph-wiggum - loop on any task until completion.

```bash
/work "Your task description" --completion-promise "DONE" --max-iterations 30
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

## PRD Mode

For structured development with PRD files from `/prd`.

```bash
/work plans/feature/prd.json
/work --prd plans/feature/prd.json
```

**How it works:**
1. Reads prd.json, finds first incomplete story
2. You implement the story, run tests, update prd.json, commit
3. Hook verifies: story passes, commit exists
4. Automatically advances to next story
5. Completes when all stories pass

**Features:**
- Auto-detects `.json` files
- Strict commit verification before advancing
- Auto-logs to progress.txt
- Shows story progress in system messages

## Commands

- `/work` - Start a work loop
- `/cancel-work` - Stop active loop
- `/work-help` - This help

## State File

Both modes use `.claude/work-loop.local.md` which contains:
- YAML frontmatter with mode, iteration, settings
- Current prompt/task below the frontmatter

## Examples

**Generic - Build a feature:**
```
/work "Implement user authentication with JWT tokens" --completion-promise "AUTH COMPLETE"
```

**PRD - Execute a spec:**
```
/work plans/auth/prd.json
```

**With custom iteration limit:**
```
/work "Refactor the database layer" --completion-promise "REFACTOR DONE" --max-iterations 100
```
