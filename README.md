# somto-dev-toolkit

Personal collection of Claude Code tools and skills.

## Installation

```
/plugin marketplace add SomtoUgeh/somto-dev-toolkit
/plugin install somto-dev-toolkit@somto-dev-toolkit
```

## Commands (15)

### Loop Commands

| Command | Description |
|---------|-------------|
| `/go` | Iterative task loop (generic or PRD-aware) |
| `/prd` | Deep interview to build PRD for features |
| `/ut` | Unit test coverage improvement loop |
| `/e2e` | Playwright E2E test development loop |

### Control Commands

| Command | Description |
|---------|-------------|
| `/cancel-go` | Cancel active go loop |
| `/cancel-prd` | Cancel active PRD loop |
| `/cancel-ut` | Cancel active unit test loop |
| `/cancel-e2e` | Cancel active E2E test loop |

### Help Commands

| Command | Description |
|---------|-------------|
| `/go-help` | Help for the go loop command |
| `/ut-help` | Explain the unit test loop technique |
| `/e2e-help` | Explain the E2E test loop technique |

### Session & Utility Commands

| Command | Description |
|---------|-------------|
| `/fork-detect` | Search past sessions semantically and fork |
| `/sync-sessions` | Sync Claude Code sessions to qmd index |
| `/deslop` | Remove AI-generated code slop from branch |
| `/setup-git-guard` | Install git safety guard hook |

## Agents (3)

| Agent | Description |
|-------|-------------|
| `prd-codebase-researcher` | Research codebase patterns for PRD development |
| `prd-external-researcher` | Research external best practices using Exa |
| `prd-complexity-estimator` | Estimate iteration counts for /go loops |

## Skills (3)

| Skill | Description |
|-------|-------------|
| `blog-post-writer` | Transform brain dumps into polished blog posts |
| `technical-svg-diagrams` | Generate clean, minimal SVG diagrams |
| `biome-gritql` | GritQL patterns for Biome linting |

## Hooks (4)

| Event | Purpose |
|-------|---------|
| `SessionStart` | Initialize session state |
| `Stop` | Enforce iterative workflows (go/ut/e2e/prd loops) |
| `SubagentStop` | Validate research agent outputs |
| `PreToolUse` | Git safety guard (blocks destructive commands) |

## Usage Examples

### PRD-based Development
```
/prd "add user authentication"
# Interview process generates spec + PRD
# Then run the go loop:
/go plans/auth/prd.json
```

### Unit Test Coverage
```
/ut "improve coverage for auth module" --target 80%
```

### E2E Testing
```
/e2e "add checkout flow tests"
```

### Git Safety Guard
```
/setup-git-guard project  # or 'user' for global
```

## Updating

```
/plugin marketplace update
/plugin update somto-dev-toolkit@somto-dev-toolkit
```

## License

MIT
