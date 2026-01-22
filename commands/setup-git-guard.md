---
name: setup-git-guard
description: Install git safety guard hook at project or user scope
argument-hint: "[project|user]"
---

# Git Safety Guard Setup

You are helping the user install the git safety guard hook. This hook blocks destructive git commands like `git reset --hard`, `git checkout --`, `rm -rf`, etc.

## Installation Scope

The user wants to install at: **$ARGUMENTS** scope

- **project**: Installs to `.claude/settings.json` - applies to this project only, can be shared via git
- **user**: Installs to `~/.claude/settings.json` - applies to ALL Claude Code sessions

## Steps

1. First, check if the guard script exists in the plugin:
   - Plugin location: `${CLAUDE_PLUGIN_ROOT}/hooks/git_guard.py`

2. Based on scope, do the following:

### For PROJECT scope:

a. Create `.claude` directory if it doesn't exist:
```bash
mkdir -p .claude
```

b. Copy the guard script to `.claude/hooks/`:
```bash
mkdir -p .claude/hooks
cp "${CLAUDE_PLUGIN_ROOT}/hooks/git_guard.py" .claude/hooks/git_guard.py
chmod +x .claude/hooks/git_guard.py
```

c. Read existing `.claude/settings.json` if it exists, then merge the hook config:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "python3 .claude/hooks/git_guard.py",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

d. Add `.claude/hooks/` to `.gitignore` OR commit it (ask user preference)

### For USER scope:

a. Copy the guard script to `~/.claude/hooks/`:
```bash
mkdir -p ~/.claude/hooks
cp "${CLAUDE_PLUGIN_ROOT}/hooks/git_guard.py" ~/.claude/hooks/git_guard.py
chmod +x ~/.claude/hooks/git_guard.py
```

b. Read existing `~/.claude/settings.json` if it exists, then merge the hook config:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "python3 ~/.claude/hooks/git_guard.py",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

## After Installation

Tell the user:
- The git guard is now active for $ARGUMENTS scope
- It blocks: `git reset --hard`, `git checkout --`, `git clean -f`, `rm -rf`, force pushes, stash drops
- Safe operations are allowed: `git checkout -b`, `rm -rf node_modules`, `git restore --staged`
- To disable: remove the PreToolUse hook from the settings file

## Important

- Always preserve existing settings when merging
- If hooks.PreToolUse already exists, append to the array don't replace
- Validate JSON before writing
