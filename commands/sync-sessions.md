---
name: sync-sessions
description: Sync Claude Code sessions to qmd index
argument-hint: "[--full]"
---

# Sync Sessions

Update the qmd index with latest Claude Code sessions for fork detection.

## Workflow

### Step 1: Check Dependencies

```bash
command -v qmd &>/dev/null || echo "QMD_MISSING"
command -v jq &>/dev/null || echo "JQ_MISSING"
```

If missing, provide installation instructions:
- qmd: `bun install -g https://github.com/tobi/qmd`
- jq: `brew install jq`

### Step 2: Determine Mode

Check if this is first-time setup or update:

```bash
qmd status 2>/dev/null | grep -q "claude-sessions" && echo "UPDATE" || echo "SETUP"
```

- **SETUP**: Run full setup script
- **UPDATE**: Run sync + embed only

### Step 3: Execute Sync

**For first-time setup:**
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/setup-qmd-sessions.sh"
```

**For updates (default - incremental):**
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/sync-sessions-to-qmd.sh"
qmd embed
```

**For full rebuild (if `--full` argument provided):**
```bash
"${CLAUDE_PLUGIN_ROOT}/scripts/sync-sessions-to-qmd.sh" --full
qmd embed
```

### Step 4: Report Status

After sync completes, show:
```bash
qmd status
```

And count indexed sessions:
```bash
find ~/.claude/qmd-sessions -name "*.md" | wc -l
```

<format>
Example output:

```
✓ Session sync complete

  Sessions indexed: 127
  Collection: claude-sessions

Ready to use /fork-detect
```
</format>

## Success Criteria

- [ ] Dependencies checked before running
- [ ] Correct mode detected (setup vs update)
- [ ] Sync script executes successfully
- [ ] Embeddings regenerated
- [ ] Status displayed showing indexed session count
