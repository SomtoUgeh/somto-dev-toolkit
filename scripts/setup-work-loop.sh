#!/bin/bash

# Work Loop Setup Script
# Dual-mode: Generic (ralph-wiggum style) or PRD-aware
#
# Generic mode:
#   setup-work-loop.sh "Your prompt" --completion-promise "DONE" [--max-iterations N]
#
# PRD mode:
#   setup-work-loop.sh --prd plans/feature/prd.json [--max-iterations N]
#   setup-work-loop.sh plans/feature/prd.json  # auto-detect .json

set -euo pipefail

# Defaults
MODE=""
PROMPT=""
PRD_PATH=""
MAX_ITERATIONS=50
COMPLETION_PROMISE=""

show_help() {
  cat << 'HELP_EOF'
Work Loop - Iterative task execution (generic or PRD-aware)

USAGE:
  /work "<prompt>" --completion-promise "DONE" [OPTIONS]
  /work --prd <prd.json> [OPTIONS]
  /work <prd.json> [OPTIONS]

MODES:
  Generic: Provide a prompt and completion promise (ralph-wiggum style)
  PRD:     Provide a prd.json file (auto-detects by .json extension)

OPTIONS:
  --prd <path>                    PRD file path (forces PRD mode)
  --completion-promise '<text>'   Promise phrase for generic mode (required)
  --max-iterations <n>            Safety limit (default: 50)
  -h, --help                      Show this help message

GENERIC MODE:
  Loops until you output <promise>YOUR_TEXT</promise>
  Example: /work "Build a CSV parser" --completion-promise "PARSER COMPLETE"

PRD MODE:
  Loops through stories until all have passes=true
  Auto-commits per story, auto-updates progress.txt
  Example: /work plans/auth/prd.json

STOPPING:
  Generic: output <promise>TEXT</promise>
  PRD: all stories pass (automatic)
  Both: /cancel-work
HELP_EOF
}

# Parse arguments
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      show_help
      exit 0
      ;;
    --prd)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --prd requires a file path" >&2
        exit 1
      fi
      PRD_PATH="$2"
      MODE="prd"
      shift 2
      ;;
    --completion-promise)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --completion-promise requires a text argument" >&2
        exit 1
      fi
      COMPLETION_PROMISE="$2"
      shift 2
      ;;
    --max-iterations)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --max-iterations requires a number" >&2
        exit 1
      fi
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "Error: --max-iterations must be a positive integer, got: $2" >&2
        exit 1
      fi
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    -*)
      echo "Unknown option: $1" >&2
      echo "Use --help for usage information" >&2
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

# Process positional args
if [[ ${#POSITIONAL_ARGS[@]} -gt 0 ]]; then
  FIRST_ARG="${POSITIONAL_ARGS[0]}"

  # Auto-detect PRD mode if arg ends in .json
  if [[ "$FIRST_ARG" == *.json ]]; then
    PRD_PATH="$FIRST_ARG"
    MODE="prd"
  else
    PROMPT="$FIRST_ARG"
    MODE="generic"
  fi
fi

# Validate based on mode
if [[ -z "$MODE" ]]; then
  echo "Error: No prompt or PRD file provided" >&2
  echo "Use --help for usage information" >&2
  exit 1
fi

# Create .claude directory if needed
mkdir -p .claude

STATE_FILE=".claude/work-loop.local.md"

if [[ "$MODE" == "generic" ]]; then
  # Generic mode validation
  if [[ -z "$PROMPT" ]]; then
    echo "Error: No prompt provided for generic mode" >&2
    exit 1
  fi
  if [[ -z "$COMPLETION_PROMISE" ]]; then
    echo "Error: --completion-promise required for generic mode" >&2
    echo "Example: /work \"Your task\" --completion-promise \"DONE\"" >&2
    exit 1
  fi

  # Create generic mode state file
  cat > "$STATE_FILE" <<EOF
---
mode: "generic"
active: true
iteration: 1
max_iterations: $MAX_ITERATIONS
completion_promise: "$COMPLETION_PROMISE"
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---

# Work Loop

$PROMPT

---

When complete, output:

\`\`\`
<promise>$COMPLETION_PROMISE</promise>
\`\`\`

CRITICAL: Only output this promise when the task is genuinely complete.
EOF

  # Output setup message
  cat <<EOF
Work loop activated (generic mode)!

Iteration: 1
Max iterations: $MAX_ITERATIONS
Completion promise: $COMPLETION_PROMISE

The stop hook is now active. When you try to exit, the same prompt will be
fed back for the next iteration until you output the completion promise.

To complete: output <promise>$COMPLETION_PROMISE</promise>
To cancel: /cancel-work
EOF

else
  # PRD mode validation
  if [[ ! -f "$PRD_PATH" ]]; then
    echo "Error: PRD file not found: $PRD_PATH" >&2
    exit 1
  fi

  # Validate JSON
  if ! jq empty "$PRD_PATH" 2>/dev/null; then
    echo "Error: Invalid JSON in PRD file: $PRD_PATH" >&2
    exit 1
  fi

  # Check for stories
  STORY_COUNT=$(jq '.stories | length' "$PRD_PATH")
  if [[ "$STORY_COUNT" -eq 0 ]]; then
    echo "Error: No stories found in PRD file" >&2
    exit 1
  fi

  # Find first incomplete story
  FIRST_INCOMPLETE=$(jq -r '[.stories[] | select(.passes == false)] | first | .id // empty' "$PRD_PATH")
  if [[ -z "$FIRST_INCOMPLETE" ]]; then
    echo "All stories already pass! Nothing to do." >&2
    exit 0
  fi

  # Extract feature name from path (plans/<feature>/prd.json)
  FEATURE_NAME=$(echo "$PRD_PATH" | sed -n 's|.*/plans/\([^/]*\)/prd\.json|\1|p')
  if [[ -z "$FEATURE_NAME" ]]; then
    FEATURE_NAME=$(basename "$(dirname "$PRD_PATH")")
  fi

  # Derive spec and progress paths
  PRD_DIR=$(dirname "$PRD_PATH")
  SPEC_PATH="$PRD_DIR/spec.md"
  PROGRESS_PATH="$PRD_DIR/progress.txt"

  # Create progress file if it doesn't exist
  if [[ ! -f "$PROGRESS_PATH" ]]; then
    cat > "$PROGRESS_PATH" <<EOF
# Progress Log: $FEATURE_NAME
# Each line: JSON object with ts, story_id, status, notes
# Status values: STARTED, PASSED, FAILED, BLOCKED
EOF
  fi

  # Get current story details
  CURRENT_STORY=$(jq ".stories[] | select(.id == $FIRST_INCOMPLETE)" "$PRD_PATH")
  CURRENT_TITLE=$(echo "$CURRENT_STORY" | jq -r '.title')
  TOTAL_STORIES=$STORY_COUNT
  INCOMPLETE_COUNT=$(jq '[.stories[] | select(.passes == false)] | length' "$PRD_PATH")

  # Create PRD mode state file
  cat > "$STATE_FILE" <<EOF
---
mode: "prd"
active: true
prd_path: "$PRD_PATH"
spec_path: "$SPEC_PATH"
progress_path: "$PROGRESS_PATH"
feature_name: "$FEATURE_NAME"
current_story_id: $FIRST_INCOMPLETE
total_stories: $TOTAL_STORIES
iteration: 1
max_iterations: $MAX_ITERATIONS
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---

# Work Loop: $FEATURE_NAME

**Progress:** Story $FIRST_INCOMPLETE of $TOTAL_STORIES ($INCOMPLETE_COUNT remaining)
**PRD:** \`$PRD_PATH\`
**Spec:** \`$SPEC_PATH\`

## Current Story

\`\`\`json
$CURRENT_STORY
\`\`\`

## Your Task

1. Read the full spec at \`$SPEC_PATH\`
2. Implement story #$FIRST_INCOMPLETE: "$CURRENT_TITLE"
3. Follow the verification steps listed in the story
4. Write/update tests as needed
5. Run: format, lint, tests, types (all must pass)
6. Update \`$PRD_PATH\`: set \`passes = true\` for story $FIRST_INCOMPLETE
7. Commit with appropriate type: \`<type>($FEATURE_NAME): story #$FIRST_INCOMPLETE - $CURRENT_TITLE\`
   Types: feat (new feature), fix (bug fix), refactor, test, chore, docs

When you're done with this story, the hook will automatically:
- Verify the story passes in prd.json
- Verify you committed
- Log to progress.txt
- Advance to the next story (or complete if all done)

CRITICAL: Only mark the story as passing when it genuinely passes all verification steps.
EOF

  # Log start to progress file
  echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"story_id\":$FIRST_INCOMPLETE,\"status\":\"STARTED\",\"notes\":\"Beginning story #$FIRST_INCOMPLETE\"}" >> "$PROGRESS_PATH"

  # Output setup message
  cat <<EOF
Work loop activated (PRD mode)!

Feature: $FEATURE_NAME
PRD: $PRD_PATH
Current story: #$FIRST_INCOMPLETE - $CURRENT_TITLE
Progress: $INCOMPLETE_COUNT of $TOTAL_STORIES remaining
Max iterations: $MAX_ITERATIONS

The stop hook is now active. When you complete a story, it will:
- Verify passes=true in prd.json
- Verify you committed
- Advance to the next story automatically

To cancel: /cancel-work
EOF
fi
