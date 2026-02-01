---
name: gwt
description: |
  Manage git worktrees using sibling directories. Use for parallel development,
  PR reviews, or isolated work.
author: Somto Odera
version: 1.0.0
date: 2026-02-01
---

# Git Worktree Manager (gwt)

## Problem

Nested worktree directories (`.worktrees/`) cause Next.js Turbopack to detect multiple lockfiles, IDE file watchers to get confused, and build tools to traverse into nested worktrees.

## Solution

Use **sibling directories** instead of nested ones to completely isolate worktrees from the main repo.

## Directory Structure

```
~/code/
├── my-project/                    # main repo
├── my-project--feat-auth/         # worktree (sibling)
└── my-project--fix-bug/           # worktree (sibling)
```

Naming: `{repo-name}--{branch-name}` (double dash separator, slashes become dashes)

## Installation

The `gwt` script must be installed in your PATH:

```bash
# From plugin directory
cp scripts/gwt ~/.local/bin/gwt
chmod +x ~/.local/bin/gwt

# Or via curl
curl -o ~/.local/bin/gwt https://raw.githubusercontent.com/SomtoUgeh/somto-dev-toolkit/main/scripts/gwt
chmod +x ~/.local/bin/gwt

# Add to PATH (if not already)
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

## When to Use

- **Reviewing PRs** in isolation without switching branches
- **Parallel development** on multiple features
- **Testing changes** without affecting main branch state
- **Overnight/long-running** work that shouldn't block other work

## Commands

```bash
gwt new <branch> [from]   # Create worktree (copies .env files)
gwt ls                    # List worktrees for current repo
gwt go <branch>           # Output path (use: cd $(gwt go feat))
gwt rm <branch>           # Remove worktree + delete branch
gwt here                  # Show current worktree info
gwt path <branch>         # Alias for 'go'
```

### Flags

- `--json` - Machine-readable output
- `--no-env` - Skip .env file copying
- `--keep-branch` - Don't delete branch on rm

## Agent Usage

### Creating a worktree

```bash
# Create worktree
gwt new feat/my-feature

# Switch to it
cd $(gwt go my-feature)

# Install dependencies (always do this after creating)
bun install

# Start dev server
bun run dev
```

### Programmatic access

```bash
# Get JSON list of worktrees
gwt ls --json

# Get current worktree info as JSON
gwt here --json
```

### Cleanup

```bash
# Remove worktree and branch
gwt rm my-feature

# Keep the branch, just remove worktree
gwt rm my-feature --keep-branch
```

## Notes

- `.env` files are automatically copied from main repo on creation
- Fuzzy matching works: `gwt go auth` matches `feat-auth`
- Branch slashes become dashes: `feat/auth` → `repo--feat-auth`
- Always run `bun install` after creating a worktree
