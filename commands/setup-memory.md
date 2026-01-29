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

## Do You Need This?

**If the plugin is already enabled**: The memory hooks are already active via the plugin's `hooks.json`. You only need this setup for:
1. Setting up **qmd** (required for memory to work)
2. Running **initial sync** of your sessions
3. Setting up **scheduled sync** (every 30 min)

**If you want hooks without the plugin**: This installs hooks to `~/.claude/settings.json` so they work independently.

## Installation Scope

The user wants to install at: **$ARGUMENTS** scope (default: user)

- **user**: Installs hooks to `~/.claude/` - works without plugin loaded (recommended for persistence)
- **plugin-only**: Skip hook installation, just setup qmd + sync (hooks stay in plugin)

## Prerequisites Check

### Step 1a: Check qmd installation

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

### Step 1b: Install YAKE for better keyword extraction

YAKE improves session search by extracting meaningful keywords. Auto-install (best effort):

```bash
# Check if already installed
if python3 -c "import yake" 2>/dev/null; then
    echo "YAKE already installed ✓"
elif ! command -v pip3 &>/dev/null; then
    echo "pip3 not found. Install with:"
    echo "  Ubuntu/Debian: sudo apt install python3-pip"
    echo "  macOS: brew install python3"
    echo ""
    echo "Skipping YAKE (fallback mode will be used)"
else
    # Try --user first (works most places), then --break-system-packages if needed
    pip3 install --user yake 2>/dev/null || \
    pip3 install --user --break-system-packages yake 2>/dev/null || \
    echo "YAKE install failed (fallback mode will be used)"
fi
```

Verify installation:
```bash
python3 -c "import yake; print('YAKE installed ✓')" 2>/dev/null || echo "YAKE not installed (fallback mode will be used)"
```

**Note**: If installation fails, hooks still work using simple word extraction as fallback.

## Installation Steps

### Step 2: Create directories

```bash
mkdir -p ~/.claude/hooks
mkdir -p ~/.claude/qmd-sessions
```

### Step 3: Copy hook scripts

Copy the keyword extractor (shared):
```bash
cp "${CLAUDE_PLUGIN_ROOT}/hooks/keyword_extractor.py" ~/.claude/hooks/keyword_extractor.py
chmod +x ~/.claude/hooks/keyword_extractor.py
```

Copy the memory injection hook:
```bash
cp "${CLAUDE_PLUGIN_ROOT}/hooks/memory_injection.py" ~/.claude/hooks/memory_injection.py
chmod +x ~/.claude/hooks/memory_injection.py
```

Copy the prompt context hook (fork suggestions + memory):
```bash
cp "${CLAUDE_PLUGIN_ROOT}/hooks/prompt_context.py" ~/.claude/hooks/prompt_context.py
chmod +x ~/.claude/hooks/prompt_context.py
```

### Step 4: Configure hooks in settings.json

**Important**: The plugin's hooks are already active if the plugin is enabled. This step is for users who want hooks to work **without the plugin loaded**.

Read existing `~/.claude/settings.json`, then **MERGE** (not replace) the hook config.

**Hook entries to ADD (append to existing arrays):**

For `hooks.PreToolUse` array, append:
```json
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
```

For `hooks.UserPromptSubmit` array, append:
```json
{
  "hooks": [
    {
      "type": "command",
      "command": "python3 ~/.claude/hooks/prompt_context.py",
      "timeout": 10
    }
  ]
}
```

**Merge rules:**
1. Read existing `~/.claude/settings.json` first
2. If `hooks` key doesn't exist, create it
3. If `hooks.PreToolUse` exists, **append** the new entry to the array
4. If `hooks.UserPromptSubmit` exists, **append** the new entry to the array
5. **Never delete or replace** existing hook entries
6. Preserve all other settings (permissions, model, statusLine, etc.)

**Example merge** - if user already has:
```json
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"command": "python3 ~/.claude/hooks/git_guard.py"}]}
    ]
  }
}
```

After merge should be:
```json
{
  "hooks": {
    "PreToolUse": [
      {"matcher": "Bash", "hooks": [{"command": "python3 ~/.claude/hooks/git_guard.py"}]},
      {"matcher": "Read|Edit|Write|Glob|Grep", "hooks": [{"command": "python3 ~/.claude/hooks/memory_injection.py", "timeout": 10}]}
    ]
  }
}
```

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

Run these verification commands one at a time:

```bash
ls -la ~/.claude/hooks/memory_injection.py
```

```bash
ls -la ~/.claude/hooks/prompt_context.py
```

```bash
qmd status | grep claude-sessions
```

```bash
launchctl list 2>/dev/null | grep claude.session-sync
```

(On Linux/WSL, use `crontab -l | grep session-sync` instead)

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
- Test: `echo '{"prompt":"fix timeout issue with API"}' | python3 ~/.claude/hooks/prompt_context.py`

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
rm ~/.claude/hooks/prompt_context.py

# Optionally remove indexed sessions
rm -rf ~/.claude/qmd-sessions/

# Optionally remove qmd collection
qmd collection remove claude-sessions
```
