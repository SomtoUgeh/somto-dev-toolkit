---
name: fork-detect
description: Search past sessions semantically and select one to fork from
argument-hint: "<what you want to do>"
context: fork
agent: general-purpose
---

# Fork Detection

Find relevant past Claude Code sessions to fork from based on semantic similarity to your intent.

## Workflow

### Step 1: Validate Setup

First, check if qmd and the claude-sessions collection are available:

```bash
qmd status 2>/dev/null | grep -q "claude-sessions" || echo "SETUP_NEEDED"
```

If `SETUP_NEEDED`, inform the user:
> The session index hasn't been set up yet. Run `/sync-sessions` first to index your sessions.

### Step 2: Search Sessions

Run qmd semantic search with the user's intent:

```bash
qmd query "$ARGUMENTS" --json -n 5 --min-score 0.3 -c claude-sessions
```

<constraints>
- Use `--json` for structured output
- Limit to 5 results (`-n 5`)
- Filter low relevance (`--min-score 0.3`)
- Search only session collection (`-c claude-sessions`)
</constraints>

### Step 3: Parse Results and Present Selection

Parse the JSON output. For each result:

1. Extract the `score` field (0-1, display as percentage)
2. Extract `title` (the firstPrompt/session heading)
3. Read the markdown file's frontmatter to get:
   - `project_name`
   - `branch`
   - `created`
   - `messages`
   - `full_path`

### Step 4: Let User Select Session

Use AskUserQuestion to present the sessions as selectable options:

```
options:
  - label: "[92%] Add Google OAuth to the API"
    description: "my-api (main) | 2026-01-15 | 24 messages"
  - label: "[78%] Fix authentication middleware"
    description: "my-api (feature/auth) | 2026-01-10 | 12 messages"
  - label: "[65%] Implement JWT token refresh"
    description: "auth-service (main) | 2025-12-20 | 8 messages"
  - label: "None - start fresh"
    description: "Don't fork, continue without prior context"
```

<constraints>
- Max 4 options (top 3 results + "None" option)
- Header: "Fork from"
- Question: "Which session should we continue from?"
- Track which `full_path` corresponds to each option
</constraints>

### Step 5: Execute Fork or Continue

Based on user selection:

**If user selects a session:**
Extract the session ID (UUID) from the `full_path`. The session ID is the filename without `.jsonl` extension.

Example: `/Users/somto/.claude/projects/-Users-somto-code-myproject/75297972-8b57-4a71-8c73-a6fe71354dc9.jsonl`
→ Session ID: `75297972-8b57-4a71-8c73-a6fe71354dc9`

Output the fork command for them to run in a new terminal:
```
To fork this session, run in a new terminal:

claude --resume <session-id> --fork-session
```

Note: Claude Code cannot fork itself mid-session. The user must start a new session with the fork flag.

**If user selects "None":**
```
Starting fresh. What would you like to work on?
```

### Step 6: Handle Edge Cases

**No arguments provided:**
Ask the user what they want to search for.

**No results found:**
```
No relevant sessions found for: "$ARGUMENTS"

Try:
- Using different keywords
- Running /sync-sessions to update the index
- Starting a fresh session instead
```

**qmd not installed:**
```
qmd is not installed. Install with:
  bun install -g https://github.com/tobi/qmd

Then run /sync-sessions to set up the index.
```

**Only 1-2 results:**
Still use AskUserQuestion but with fewer options (always include "None" option).

## Success Criteria

- [ ] qmd query executes without error
- [ ] Results parsed correctly from JSON
- [ ] AskUserQuestion presents top sessions as selectable options
- [ ] Each option shows score, title, project context
- [ ] Selected session's fork command is displayed clearly
- [ ] "None" option allows starting fresh
