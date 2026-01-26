# Running Claude Code in Docker Containers

Complete setup guide for running Claude Code in Docker sandboxes, with an AFK (away from keyboard) loop script.

---

## Prerequisites

- **Docker Desktop 4.50+** (required for sandbox feature)
- **macOS OrbStack users**: Docker sandbox is NOT available - use direct execution instead
- **Claude Code CLI** installed via `curl -fsSL https://claude.ai/install.sh | bash`
- **jq** for streaming output parsing:
  - macOS: `brew install jq`
  - WSL/Linux: `sudo apt install jq`

---

## Quick Start

### 1. One-time sandbox authentication

```bash
# macOS
/Applications/Docker.app/Contents/Resources/bin/docker sandbox run --credentials host claude

# WSL/Windows
docker.exe sandbox run --credentials host claude

# Inside sandbox, run:
/login

# Follow browser auth flow - credentials persist in docker volume
```

### 2. Install the ralph script

Create `~/bin/ralph`:

```bash
mkdir -p ~/bin
cat > ~/bin/ralph << 'SCRIPT'
#!/bin/bash
# Ralph - AFK Loop for Claude Code in Docker Sandbox
# Based on Matt Pocock's ralph pattern (aihero.dev)

set -euo pipefail

# =============================================================================
# Platform Detection
# =============================================================================

get_docker_desktop() {
  case "$(uname -s)" in
    Darwin)
      echo "/Applications/Docker.app/Contents/Resources/bin/docker"
      ;;
    Linux)
      if grep -qi microsoft /proc/version 2>/dev/null; then
        command -v docker.exe &>/dev/null && echo "docker.exe" || echo "/mnt/c/Program Files/Docker/Docker/resources/bin/docker.exe"
      else
        echo "docker"
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      echo "docker.exe"
      ;;
    *)
      echo "docker"
      ;;
  esac
}

notify() {
  local title="$1"
  local message="$2"
  case "$(uname -s)" in
    Darwin)
      osascript -e "display notification \"$message\" with title \"$title\"" 2>/dev/null || true
      ;;
    Linux)
      if grep -qi microsoft /proc/version 2>/dev/null; then
        powershell.exe -Command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show('$message', '$title')" </dev/null >/dev/null 2>&1 &
      else
        notify-send "$title" "$message" 2>/dev/null || true
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      powershell.exe -Command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show('$message', '$title')" </dev/null >/dev/null 2>&1 &
      ;;
  esac
}

# =============================================================================
# Configuration
# =============================================================================

DOCKER="$(get_docker_desktop)"
MAX_ITERATIONS="${MAX_ITERATIONS:-50}"
PROMPT=""
COMPLETION_PROMISE="TASK COMPLETE"
STREAMING=true
SANDBOX=true

# jq filters from Matt Pocock's article
stream_text='select(.type == "assistant").message.content[]? | select(.type == "text").text // empty'
final_result='select(.type == "result").result // empty'

# =============================================================================
# Usage
# =============================================================================

show_help() {
  cat << 'HELP'
Ralph - AFK Loop for Claude Code in Docker Sandbox

USAGE:
  ralph "your task description" [OPTIONS]
  ralph --prompt "task" --promise "DONE" [OPTIONS]

OPTIONS:
  --prompt <text>       Task description (or pass as first positional arg)
  --promise <text>      Completion marker (default: "TASK COMPLETE")
  --max <n>             Max iterations (default: 50, or set MAX_ITERATIONS env)
  --no-stream           Disable streaming output
  --no-sandbox          Run without Docker sandbox
  -h, --help            Show this help

EXAMPLES:
  ralph "Build a CSV parser that handles quoted fields"
  ralph "Fix the auth bug" --max 10
  ralph --prompt "Add tests" --promise "ALL TESTS PASS" --max 20

COMPLETION:
  Claude should output <promise>YOUR_PROMISE</promise> when done.
  The loop detects this and stops automatically.

ENVIRONMENT:
  MAX_ITERATIONS    Default max iterations (default: 50)
HELP
}

# =============================================================================
# Argument Parsing
# =============================================================================

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      show_help
      exit 0
      ;;
    --prompt)
      PROMPT="$2"
      shift 2
      ;;
    --promise)
      COMPLETION_PROMISE="$2"
      shift 2
      ;;
    --max)
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    --no-stream)
      STREAMING=false
      shift
      ;;
    --no-sandbox)
      SANDBOX=false
      shift
      ;;
    -*)
      echo "Unknown option: $1" >&2
      echo "Use --help for usage" >&2
      exit 1
      ;;
    *)
      # First positional arg is the prompt
      if [[ -z "$PROMPT" ]]; then
        PROMPT="$1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$PROMPT" ]]; then
  echo "Error: No prompt provided" >&2
  echo "Usage: ralph \"your task\" [--max N]" >&2
  exit 1
fi

# =============================================================================
# Preflight Checks
# =============================================================================

if [[ "$SANDBOX" == "true" ]]; then
  if ! "$DOCKER" sandbox --help &>/dev/null 2>&1; then
    echo "ERROR: docker sandbox not available."
    echo ""
    echo "Options:"
    echo "  1. Install Docker Desktop 4.50+"
    echo "  2. Use --no-sandbox to run directly"
    exit 1
  fi
fi

if [[ "$STREAMING" == "true" ]] && ! command -v jq &>/dev/null; then
  echo "ERROR: jq required for streaming. Install with: brew install jq (or apt install jq)"
  exit 1
fi

# =============================================================================
# Execution
# =============================================================================

run_claude() {
  local prompt="$1"

  if [[ "$SANDBOX" == "true" ]]; then
    if [[ "$STREAMING" == "true" ]]; then
      "$DOCKER" sandbox run --credentials host claude \
        --dangerously-skip-permissions \
        --output-format stream-json \
        --verbose \
        --print \
        "$prompt"
    else
      "$DOCKER" sandbox run --credentials host claude \
        --dangerously-skip-permissions \
        --print \
        "$prompt"
    fi
  else
    if [[ "$STREAMING" == "true" ]]; then
      claude \
        --dangerously-skip-permissions \
        --output-format stream-json \
        --verbose \
        --print \
        "$prompt"
    else
      claude \
        --dangerously-skip-permissions \
        --print \
        "$prompt"
    fi
  fi
}

run_iteration() {
  local prompt="$1"
  local tmpfile
  tmpfile=$(mktemp)

  if [[ "$STREAMING" == "true" ]]; then
    run_claude "$prompt" 2>&1 \
      | grep --line-buffered '^{' \
      | tee "$tmpfile" \
      | jq --unbuffered -rj "$stream_text" 2>/dev/null || true

    local result
    result=$(jq -rs "$final_result" "$tmpfile" 2>/dev/null || cat "$tmpfile")
    rm -f "$tmpfile"
    printf '%s' "$result"
  else
    run_claude "$prompt" 2>&1
  fi
}

build_prompt() {
  cat << PROMPT
# AFK Loop Task

You are in an AFK (away from keyboard) loop. Work autonomously without asking questions.

## Task

$PROMPT

## Instructions

1. Work on the task iteratively
2. Make incremental progress
3. Run tests/verification as needed
4. Commit meaningful changes

## Completion

When the task is GENUINELY complete, output exactly:

<promise>$COMPLETION_PROMISE</promise>

CRITICAL: Only output this when truly finished. Do not output false promises.
PROMPT
}

# =============================================================================
# Main Loop
# =============================================================================

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Ralph - AFK Loop"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Task:       ${PROMPT:0:50}..."
echo "  Promise:    $COMPLETION_PROMISE"
echo "  Max:        $MAX_ITERATIONS iterations"
echo "  Sandbox:    $SANDBOX"
echo "  Streaming:  $STREAMING"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

START_TIME=$(date +%s)
FULL_PROMPT=$(build_prompt)

for ((i=1; i<=MAX_ITERATIONS; i++)); do
  echo ""
  echo "┌─────────────────────────────────────────────────────────────┐"
  echo "│  Iteration $i of $MAX_ITERATIONS"
  echo "└─────────────────────────────────────────────────────────────┘"
  echo ""

  result=$(run_iteration "$FULL_PROMPT") || true

  if [[ "$result" == *"<promise>$COMPLETION_PROMISE</promise>"* ]]; then
    echo ""
    echo "✅ Task complete! Promise fulfilled: $COMPLETION_PROMISE"
    notify "Ralph Complete" "Task finished after $i iterations"

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    echo "Duration: $((DURATION / 60))m $((DURATION % 60))s"
    exit 0
  fi

  sleep 2
done

echo ""
echo "⚠️  Max iterations ($MAX_ITERATIONS) reached"
notify "Ralph Stopped" "Max iterations reached"
exit 1
SCRIPT

chmod +x ~/bin/ralph
```

### 3. Add ~/bin to PATH

Add to your shell config (`.zshrc` or `.bashrc`):

```bash
export PATH="$HOME/bin:$PATH"
```

Reload: `source ~/.zshrc` (or `source ~/.bashrc`)

### 4. Add shell aliases

```bash
# macOS (.zshrc)
alias docker-desktop='/Applications/Docker.app/Contents/Resources/bin/docker'
alias docker-sandbox='/Applications/Docker.app/Contents/Resources/bin/docker sandbox'
alias dc='docker-sandbox run --credentials host claude'

# WSL (.bashrc or .zshrc)
alias docker-desktop='docker.exe'
alias docker-sandbox='docker.exe sandbox'
alias dc='docker-sandbox run --credentials host claude'

# Claude Code environment (both platforms)
export ENABLE_BACKGROUND_TASKS=1
export CLAUDE_BASH_MAINTAIN_PROJECT_WORKING_DIR=1
```

---

## Using Ralph

```bash
# Basic usage
ralph "Build a CSV parser that handles quoted fields"

# With iteration limit
ralph "Fix the authentication bug" --max 10

# Custom completion promise
ralph --prompt "Add unit tests" --promise "ALL TESTS PASS" --max 20

# Without sandbox (faster, less isolated)
ralph "Quick refactor" --no-sandbox

# Without streaming (quieter output)
ralph "Background task" --no-stream
```

### How It Works

1. External bash loop runs `claude --print "prompt"` repeatedly
2. Each iteration is a fresh Claude session (no context rot)
3. Claude outputs `<promise>TASK COMPLETE</promise>` when done
4. Script detects promise and stops loop
5. Desktop notification on completion

---

## Platform-Specific Paths

| Platform | Docker Desktop Path |
|----------|---------------------|
| macOS | `/Applications/Docker.app/Contents/Resources/bin/docker` |
| WSL/Windows | `docker.exe` (via WSL integration) |
| Linux | `docker` (sandbox may not be available) |

The ralph script auto-detects your platform.

---

## OrbStack + Docker Desktop Coexistence (macOS only)

When both are installed, `docker` points to OrbStack which lacks sandbox:

```bash
which docker
# /opt/homebrew/bin/docker  <- OrbStack (no sandbox)

# Docker Desktop (has sandbox)
/Applications/Docker.app/Contents/Resources/bin/docker
```

**Solution**: Use the aliases above, or `ralph --no-sandbox`.

---

## Troubleshooting

### Iterations complete in 5-10 seconds (should be minutes)

**Cause**: Missing sandbox authentication

**Fix**: Run `/login` inside a sandbox session once:
```bash
dc  # opens sandbox
/login  # inside sandbox
```

### "Invalid API key" errors

**Cause**: Sandbox has separate credential store

**Fix**: Run `/login` inside sandbox session

### "docker: unknown command: docker sandbox"

**Cause**: OrbStack, old Docker Desktop (< 4.50), or native Linux

**Fix**: Use `ralph --no-sandbox` or upgrade Docker Desktop

### "the input device is not a TTY"

**Cause**: Running from CI/CD, cron, or another Claude session

**Fix**: Use `ralph --no-sandbox` for non-TTY contexts

### WSL: "Cannot connect to Docker daemon"

**Fix**:
1. Docker Desktop > Settings > Resources > WSL Integration
2. Enable for your distro
3. `wsl --shutdown` then reopen terminal

---

## Decision Matrix

| Scenario | Command |
|----------|---------|
| AFK with isolation | `ralph "task"` |
| AFK without sandbox | `ralph "task" --no-sandbox` |
| Quick iteration | `ralph "task" --max 5 --no-sandbox` |
| CI/CD pipeline | `ralph "task" --no-sandbox --no-stream` |
| OrbStack users | `ralph "task" --no-sandbox` |

---

## Sandbox Characteristics

| Aspect | Value |
|--------|-------|
| Filesystem | Isolated (no ~/.ssh, ~/.aws, ~/Documents) |
| Working directory | Auto-mounted |
| Git config | Auto-injected |
| Credentials | Persist in `docker-claude-sandbox-data` volume |

### Pre-installed in sandbox

Claude Code, Docker CLI, GitHub CLI, Node.js, Go, Python 3, Git, ripgrep, jq

---

## References

- [Docker Sandboxes Documentation](https://docs.docker.com/ai/sandboxes/)
- [Docker Claude Code Configuration](https://docs.docker.com/ai/sandboxes/claude-code/)
- [Docker Desktop WSL Integration](https://docs.docker.com/desktop/wsl/)
- [Matt Pocock: Getting Started With Ralph](https://www.aihero.dev/getting-started-with-ralph)
- [Matt Pocock: Streaming Claude Code](https://www.aihero.dev/heres-how-to-stream-claude-code-with-afk-ralph)
