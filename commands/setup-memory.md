---
name: setup-memory
description: Setup smart session memory system with qmd integration
argument-hint: "[user]"
context: fork
---

# Smart Session Memory Setup

You are helping the user install the Smart Session Memory system. This enables:
- Automatic injection of relevant past session context during tool use
- Fork suggestions when starting sessions similar to past work
- Background indexing of sessions every 30 minutes

## Installation Scope

The user wants to install at: **$ARGUMENTS** scope (default: user)

- **user**: Installs to `~/.claude/` - applies to ALL Claude Code sessions (recommended)
- **plugin**: Hooks stay in plugin only - requires plugin to be installed

## Prerequisites Check

### Step 1: Check qmd installation

```bash
qmd --version
```

If qmd not found, tell user:

```
qmd is required for session memory. Install with:

  bun install -g https://github.com/tobi/qmd

Requires Bun 1.0+. macOS users also need: brew install sqlite

Run /setup-memory again after installing qmd.
```

Then STOP and wait for them to install.

## Installation Steps

### Step 2: Create directories

```bash
mkdir -p ~/.claude/hooks
mkdir -p ~/.claude/qmd-sessions
```

### Step 3: Copy hook scripts

Copy the memory injection hook:
```bash
cp "${CLAUDE_PLUGIN_ROOT}/hooks/memory_injection.py" ~/.claude/hooks/memory_injection.py
chmod +x ~/.claude/hooks/memory_injection.py
```

Copy the fork suggestion hook:
```bash
cp "${CLAUDE_PLUGIN_ROOT}/hooks/fork_suggest_hook.sh" ~/.claude/hooks/fork_suggest_hook.sh
chmod +x ~/.claude/hooks/fork_suggest_hook.sh
```

### Step 4: Configure hooks in settings.json

Read existing `~/.claude/settings.json` if it exists, then merge the hook config.

The hooks to add:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Read|Edit|Write|Glob|Grep",
        "hooks": [
          {
            "type": "command",
            "command": "python3 ~/.claude/hooks/memory_injection.py",
            "timeout": 10
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/hooks/fork_suggest_hook.sh",
            "timeout": 8
          }
        ]
      }
    ]
  }
}
```

**Important:**
- If hooks.PreToolUse already exists, append to the array don't replace
- If hooks.UserPromptSubmit already exists, append to the array don't replace
- Preserve all existing settings

### Step 5: Run initial session sync

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/sync-sessions-to-qmd.sh"
```

### Step 6: Create qmd collection

```bash
qmd collection add "$HOME/.claude/qmd-sessions" --name claude-sessions --mask "**/*.md"
```

(OK if collection already exists - will show error but that's fine)

### Step 7: Add context description

```bash
qmd context add qmd://claude-sessions "Claude Code session transcripts - coding conversations, debugging sessions, feature implementations, and project discussions"
```

### Step 8: Build embeddings

```bash
qmd embed
```

Note: First run downloads embedding model (~1 min). After that, search is instant.

### Step 9: Setup scheduled sync

Ask user if they want background sync (recommended - syncs every 30 min):

```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-scheduled-sync.sh"
```

### Step 10: Verify installation

```bash
echo "=== Checking installation ===" && \
ls -la ~/.claude/hooks/memory_injection.py && \
ls -la ~/.claude/hooks/fork_suggest_hook.sh && \
qmd status | grep claude-sessions && \
(launchctl list 2>/dev/null | grep claude.session-sync || crontab -l 2>/dev/null | grep session-sync || echo "Scheduler: not installed")
```

## After Installation

Tell the user:

**The session memory system is now active!**

- **Memory injection**: When you use Read/Edit/Write/Glob/Grep, relevant past session context is automatically injected
- **Fork suggestions**: When you start a session similar to past work, you'll see a fork command
- **Background sync**: Sessions are indexed every 30 minutes
- **Stop hook**: Each session is indexed immediately on exit

**Test it:**
```bash
# Search your past sessions
qmd search "your topic here" -c claude-sessions

# Check scheduler is running
launchctl list | grep claude  # macOS
crontab -l | grep session     # Linux
```

## Troubleshooting

**No context injected?**
- Check qmd has the collection: `qmd status`
- Check sessions synced: `ls ~/.claude/qmd-sessions/`
- Re-sync: `~/.claude/plugins/somto-dev-toolkit/scripts/sync-sessions-to-qmd.sh --full`

**Fork suggestion not appearing?**
- Only shows for prompts >20 chars with similar past sessions
- Test: `echo '{"prompt":"fix timeout issue with API"}' | ~/.claude/hooks/fork_suggest_hook.sh`

**Scheduler not running?**
- macOS: `launchctl list | grep claude`
- Linux/WSL: `crontab -l`
- WSL: Ensure cron running: `sudo service cron start`
- Logs: `tail ~/.claude/session-sync.log`

## Uninstall

```bash
# Remove scheduler
"${CLAUDE_PLUGIN_ROOT}/scripts/uninstall-scheduled-sync.sh"

# Remove hooks (edit ~/.claude/settings.json and remove the PreToolUse/UserPromptSubmit entries for memory)

# Remove hook scripts
rm ~/.claude/hooks/memory_injection.py
rm ~/.claude/hooks/fork_suggest_hook.sh

# Optionally remove indexed sessions
rm -rf ~/.claude/qmd-sessions/

# Optionally remove qmd collection
qmd collection remove claude-sessions
```
