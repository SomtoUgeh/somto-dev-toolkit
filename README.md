# somto-dev-toolkit

Personal collection of Claude Code tools and skills.

## Installation

```
/plugin marketplace add SomtoUgeh/somto-dev-toolkit
/plugin install somto-dev-toolkit@somto-dev-toolkit
```

## Commands (13)

### Loop Commands

| Command | Description |
|---------|-------------|
| `/prd` | Deep interview to build PRD for features (4 phases, Dex integration) |
| `/complete` | Run reviewers and mark Dex task complete |
| `/ut` | Unit test coverage (2 phases, Dex integration) |
| `/e2e` | Playwright E2E tests (2 phases, Dex integration) |

### Control Commands

| Command | Description |
|---------|-------------|
| `/cancel-prd` | Cancel active PRD loop |
| `/cancel-ut` | Cancel active unit test loop |
| `/cancel-e2e` | Cancel active E2E test loop |

### Help Commands

| Command | Description |
|---------|-------------|
| `/ut-help` | Explain the unit test loop technique |
| `/e2e-help` | Explain the E2E test loop technique |

### Session & Utility Commands

| Command | Description |
|---------|-------------|
| `/setup-memory` | Setup smart session memory system |
| `/deslop` | Remove AI-generated code slop from branch |
| `/setup-git-guard` | Install git safety guard hook |
| `/gwt` | Manage git worktrees using sibling directories |
| `/setup-gwt` | Install the gwt script |

## Agents (2)

| Agent | Description |
|-------|-------------|
| `prd-codebase-researcher` | Research codebase patterns for PRD development |
| `prd-external-researcher` | Research external best practices using Exa |

## Skills (9)

| Skill | Description |
|-------|-------------|
| `dex-workflow` | Task-based feature implementation with Dex |
| `prd-workflow` | PRD generation with 4-phase workflow |
| `unit-test-loop` | Unit test coverage with Dex tracking |
| `e2e-test-loop` | Playwright E2E tests with Dex tracking |
| `blog-post-writer` | Transform brain dumps into polished blog posts |
| `technical-svg-diagrams` | Generate clean, minimal SVG diagrams |
| `biome-gritql` | GritQL patterns for Biome linting |
| `gwt` | Git worktree management using sibling directories |
| `background-agents` | Patterns for parallel background agents |

## Hooks (6)

| Event | Purpose |
|-------|---------|
| `SessionStart` | Initialize session state |
| `Stop` | Enforce iterative workflows (ut/e2e/prd loops) |
| `SubagentStop` | Validate research agent outputs |
| `PreToolUse` | Git safety guard + memory injection (requires qmd) |
| `UserPromptSubmit` | Fork suggestion for similar past sessions (requires qmd) |

## Usage Examples

### PRD-based Development
```
/prd "add user authentication"
# Interview process generates spec with Implementation Stories
# Phase 4 creates Dex tasks automatically

# Work on tasks:
dex list --pending
/complete <task-id>
```

### Unit Test Coverage
```
/ut "improve coverage for auth module" --target 80%
# Phase 1: Coverage analysis, identify gaps
# Phase 2: Create Dex tasks for each gap
# Work on tasks:
dex list --pending
/complete <task-id>
```

### E2E Testing
```
/e2e "add checkout flow tests"
# Phase 1: Flow analysis, identify critical paths
# Phase 2: Create Dex tasks per flow
# Work on tasks:
dex list --pending
/complete <task-id>
```

### Git Safety Guard
```
/setup-git-guard project  # or 'user' for global
```

### Session Memory (requires qmd)
```
# One-time setup
/setup-memory

# Or manually:
brew install qmd  # macOS
cargo install qmd  # Linux/WSL

qmd init -c claude-sessions ~/.claude/qmd-sessions
./scripts/setup-scheduled-sync.sh
```

Once configured:
- **PreToolUse**: Injects relevant past session context when using Read/Edit/Write/Glob/Grep
- **UserPromptSubmit**: Suggests forking when starting similar work

## Updating

```
/plugin marketplace update
/plugin update somto-dev-toolkit@somto-dev-toolkit
```

## Platform Support

| Platform | Status | Notes |
|----------|--------|-------|
| macOS | Full | launchd for scheduling |
| Linux | Full | cron for scheduling |
| WSL | Full | cron (ensure `sudo service cron start`) |

## License

MIT
