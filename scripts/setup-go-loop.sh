#!/bin/bash

# Go Loop Setup Script
# Dual-mode: Generic (ralph-wiggum style) or PRD-aware
#
# Generic mode:
#   setup-go-loop.sh Build a CSV parser --completion-promise "DONE"
#
# PRD mode:
#   setup-go-loop.sh plans/feature/prd.json
#   setup-go-loop.sh --prd plans/feature/prd.json

set -euo pipefail

# Defaults
MODE=""
PROMPT_PARTS=()
PRD_PATH=""
MAX_ITERATIONS=50
COMPLETION_PROMISE=""
ONCE_MODE=false

show_help() {
  cat << 'HELP_EOF'
Go Loop - Iterative task execution (generic or PRD-aware)

USAGE:
  /go PROMPT... --completion-promise "DONE" [OPTIONS]
  /go <prd.json> [OPTIONS]
  /go --prd <prd.json> [OPTIONS]

MODES:
  Generic: Provide a prompt and completion promise
  PRD:     Provide a prd.json file (auto-detects by .json extension)

OPTIONS:
  --prd <path>                    PRD file path (forces PRD mode)
  --completion-promise '<text>'   Promise phrase for generic mode (required)
  --max-iterations <n>            Safety limit (default: 50)
  --once                          Run single iteration (HITL mode), then stop
  -h, --help                      Show this help message

GENERIC MODE:
  Loops until you output <promise>YOUR_TEXT</promise>
  Multi-word prompts work without quotes:
    /go Build a CSV parser with validation --completion-promise "DONE"

PRD MODE:
  Loops through stories until all have passes=true
  Auto-commits per story, auto-updates progress.txt
    /go plans/auth/prd.json

STOPPING:
  Generic: output <promise>TEXT</promise>
  PRD: all stories pass (automatic)
  Both: /cancel-go
HELP_EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      show_help
      exit 0
      ;;
    --prd)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --prd requires a file path" >&2
        echo "" >&2
        echo "  Valid examples:" >&2
        echo "    --prd plans/auth/prd.json" >&2
        echo "    --prd ./my-feature/prd.json" >&2
        echo "" >&2
        echo "  You provided: --prd (with no path)" >&2
        exit 1
      fi
      PRD_PATH="$2"
      MODE="prd"
      shift 2
      ;;
    --completion-promise)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --completion-promise requires a text argument" >&2
        echo "" >&2
        echo "  Valid examples:" >&2
        echo "    --completion-promise 'DONE'" >&2
        echo "    --completion-promise 'TASK COMPLETE'" >&2
        echo "    --completion-promise 'All tests passing'" >&2
        echo "" >&2
        echo "  You provided: --completion-promise (with no text)" >&2
        echo "" >&2
        echo "  Note: Multi-word promises must be quoted!" >&2
        exit 1
      fi
      COMPLETION_PROMISE="$2"
      shift 2
      ;;
    --max-iterations)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --max-iterations requires a number argument" >&2
        echo "" >&2
        echo "  Valid examples:" >&2
        echo "    --max-iterations 10" >&2
        echo "    --max-iterations 50" >&2
        echo "    --max-iterations 100" >&2
        echo "" >&2
        echo "  You provided: --max-iterations (with no number)" >&2
        exit 1
      fi
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "Error: --max-iterations must be a positive integer, got: $2" >&2
        echo "" >&2
        echo "  Valid examples:" >&2
        echo "    --max-iterations 10" >&2
        echo "    --max-iterations 50" >&2
        echo "" >&2
        echo "  Invalid: decimals (10.5), negative numbers (-5), text" >&2
        exit 1
      fi
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    --once)
      ONCE_MODE=true
      shift
      ;;
    -*)
      echo "Error: Unknown option: $1" >&2
      echo "" >&2
      echo "  Valid options:" >&2
      echo "    --prd <path>                  PRD file path" >&2
      echo "    --completion-promise <text>   Promise phrase" >&2
      echo "    --max-iterations <n>          Safety limit" >&2
      echo "    --once                        Single iteration mode" >&2
      echo "    -h, --help                    Show help" >&2
      echo "" >&2
      echo "  Use --help for full usage information" >&2
      exit 1
      ;;
    *)
      # Non-option argument - collect as prompt part or detect PRD
      if [[ "$1" == *.json ]]; then
        PRD_PATH="$1"
        MODE="prd"
      else
        PROMPT_PARTS+=("$1")
      fi
      shift
      ;;
  esac
done

# Join all prompt parts with spaces
PROMPT="${PROMPT_PARTS[*]:-}"

# Determine mode if not already set
if [[ -z "$MODE" ]] && [[ -n "$PROMPT" ]]; then
  MODE="generic"
fi

# Validate based on mode
if [[ -z "$MODE" ]]; then
  echo "Error: No prompt or PRD file provided" >&2
  echo "" >&2
  echo "  Generic mode examples:" >&2
  echo "    /go Build a REST API --completion-promise 'DONE'" >&2
  echo "    /go Fix the auth bug --completion-promise 'BUG FIXED'" >&2
  echo "" >&2
  echo "  PRD mode examples:" >&2
  echo "    /go plans/auth/prd.json" >&2
  echo "    /go --prd plans/feature/prd.json" >&2
  echo "" >&2
  echo "  For all options: /go --help" >&2
  exit 1
fi

# Create .claude directory if needed
mkdir -p .claude

# Read session_id from SessionStart hook (with fallback for edge cases)
SESSION_ID=$(cat .claude/.current_session 2>/dev/null || echo "default")

STATE_FILE=".claude/go-loop-${SESSION_ID}.local.md"

if [[ "$MODE" == "generic" ]]; then
  # Generic mode validation
  if [[ -z "$PROMPT" ]]; then
    echo "Error: No prompt provided for generic mode" >&2
    echo "" >&2
    echo "  Go loop needs a task description to work on." >&2
    echo "" >&2
    echo "  Examples:" >&2
    echo "    /go Build a REST API for todos --completion-promise 'DONE'" >&2
    echo "    /go Fix the auth bug --max-iterations 20 --completion-promise 'FIXED'" >&2
    echo "" >&2
    echo "  For all options: /go --help" >&2
    exit 1
  fi
  if [[ -z "$COMPLETION_PROMISE" ]]; then
    echo "Error: --completion-promise required for generic mode" >&2
    echo "" >&2
    echo "  Generic mode needs a completion promise to know when to stop." >&2
    echo "" >&2
    echo "  Examples:" >&2
    echo "    /go \"$PROMPT\" --completion-promise 'DONE'" >&2
    echo "    /go \"$PROMPT\" --completion-promise 'TASK COMPLETE'" >&2
    echo "" >&2
    echo "  Note: Multi-word promises must be quoted!" >&2
    exit 1
  fi

  # Quote completion promise for YAML
  COMPLETION_PROMISE_YAML="\"$COMPLETION_PROMISE\""

  # Create progress file for generic mode
  PROGRESS_FILE=".claude/go-progress.txt"
  if [[ ! -f "$PROGRESS_FILE" ]]; then
    echo "# Go Loop Progress Log" > "$PROGRESS_FILE"
    echo "# Format: JSONL - one entry per event" >> "$PROGRESS_FILE"
    echo "" >> "$PROGRESS_FILE"
  fi

  # Create generic mode state file
  cat > "$STATE_FILE" <<EOF
---
mode: "generic"
active: true
once: $ONCE_MODE
iteration: 1
max_iterations: $MAX_ITERATIONS
completion_promise: $COMPLETION_PROMISE_YAML
progress_path: "$PROGRESS_FILE"
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---

# go Loop

$PROMPT

---

When complete, output:

\`\`\`
<promise>$COMPLETION_PROMISE</promise>
\`\`\`

CRITICAL: Only output this promise when the task is genuinely complete.
EOF

  # Output setup message
  if [[ "$ONCE_MODE" == "true" ]]; then
    cat <<EOF
Go loop activated (generic mode, ONCE)!

Mode: Single iteration (HITL)
Completion promise: $COMPLETION_PROMISE

After this iteration completes, you'll stop for review.
Run /go again to continue, or switch to full loop mode without --once.
EOF
  else
    cat <<EOF
Go loop activated (generic mode)!

Iteration: 1
Max iterations: $MAX_ITERATIONS
Completion promise: $COMPLETION_PROMISE

The stop hook is now active. When you try to exit, the same prompt will be
fed back for the next iteration until you output the completion promise.

To cancel: /cancel-go
EOF
  fi

  # Display prompt
  echo ""
  echo "$PROMPT"

  # Display completion promise requirements
  echo ""
  echo "========================================================================"
  echo "CRITICAL - Go Loop Completion Promise"
  echo "========================================================================"
  echo ""
  echo "To complete this loop, output this EXACT text:"
  echo "  <promise>$COMPLETION_PROMISE</promise>"
  echo ""
  echo "STRICT REQUIREMENTS:"
  echo "  - Use <promise> XML tags EXACTLY as shown above"
  echo "  - The statement MUST be completely and unequivocally TRUE"
  echo "  - Do NOT output false statements to exit the loop"
  echo "  - Do NOT lie even if you think you should exit"
  echo ""
  echo "If you believe you're stuck or the task is impossible, keep trying."
  echo "The loop continues until the promise is GENUINELY TRUE."
  echo "========================================================================"

  # Log STARTED to progress file
  echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"status\":\"STARTED\",\"mode\":\"generic\",\"notes\":\"Go loop started (generic mode)\"}" >> "$PROGRESS_FILE"

else
  # PRD mode validation
  if [[ ! -f "$PRD_PATH" ]]; then
    echo "Error: PRD file not found: $PRD_PATH" >&2
    echo "" >&2
    echo "  Make sure the file exists and the path is correct." >&2
    echo "" >&2
    echo "  Expected structure:" >&2
    echo "    plans/<feature>/prd.json" >&2
    echo "    plans/<feature>/spec.md" >&2
    echo "" >&2
    echo "  Create a PRD using: /prd <feature description>" >&2
    exit 1
  fi

  # Validate JSON
  if ! jq empty "$PRD_PATH" 2>/dev/null; then
    echo "Error: Invalid JSON in PRD file: $PRD_PATH" >&2
    echo "" >&2
    echo "  The file exists but contains invalid JSON." >&2
    echo "  Check for syntax errors like:" >&2
    echo "    - Missing commas between fields" >&2
    echo "    - Unquoted strings" >&2
    echo "    - Trailing commas" >&2
    exit 1
  fi

  # Check for stories
  STORY_COUNT=$(jq '.stories | length' "$PRD_PATH")
  if [[ "$STORY_COUNT" -eq 0 ]]; then
    echo "Error: No stories found in PRD file" >&2
    echo "" >&2
    echo "  PRD file must have a 'stories' array with at least one story." >&2
    echo "" >&2
    echo "  Example structure:" >&2
    echo '    {"stories": [{"id": 1, "title": "...", "passes": false}]}' >&2
    exit 1
  fi

  # Find first incomplete story
  FIRST_INCOMPLETE=$(jq -r '[.stories[] | select(.passes == false)] | first | .id // empty' "$PRD_PATH")
  if [[ -z "$FIRST_INCOMPLETE" ]]; then
    echo "All stories already pass! Nothing to do."
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
  CURRENT_SKILL=$(echo "$CURRENT_STORY" | jq -r '.skill // empty')
  TOTAL_STORIES=$STORY_COUNT
  INCOMPLETE_COUNT=$(jq '[.stories[] | select(.passes == false)] | length' "$PRD_PATH")

  # Build skill field for frontmatter (only if skill exists)
  SKILL_FRONTMATTER=""
  SKILL_SECTION=""
  if [[ -n "$CURRENT_SKILL" ]]; then
    SKILL_FRONTMATTER="skill: \"$CURRENT_SKILL\""
    SKILL_SECTION="## Required Skill

This story requires the \`$CURRENT_SKILL\` skill. **BEFORE implementing**, invoke:

\`\`\`
/Skill $CURRENT_SKILL
\`\`\`

Follow the skill's guidance for implementation approach, patterns, and quality standards.
"
  fi

  # Create PRD mode state file
  cat > "$STATE_FILE" <<EOF
---
mode: "prd"
active: true
once: $ONCE_MODE
prd_path: "$PRD_PATH"
spec_path: "$SPEC_PATH"
progress_path: "$PROGRESS_PATH"
feature_name: "$FEATURE_NAME"
current_story_id: $FIRST_INCOMPLETE
total_stories: $TOTAL_STORIES
${SKILL_FRONTMATTER:+$SKILL_FRONTMATTER
}iteration: 1
max_iterations: $MAX_ITERATIONS
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---

# go Loop: $FEATURE_NAME

**Progress:** Story $FIRST_INCOMPLETE of $TOTAL_STORIES ($INCOMPLETE_COUNT remaining)
**PRD:** \`$PRD_PATH\`
**Spec:** \`$SPEC_PATH\`

## Current Story

\`\`\`json
$CURRENT_STORY
\`\`\`

## Task Priority

When multiple stories are available, prioritize in this order:
1. **Architectural decisions** - foundations cascade through everything built on top
2. **Integration points** - reveals incompatibilities early, before dependent work
3. **Unknown unknowns** - fail fast on risky spikes rather than fail late
4. **Standard features** - straightforward implementation work
5. **Polish and cleanup** - can be parallelized or deferred

The hook auto-advances by \`priority\` field, but if you notice a dependency or risk the PRD missed, flag it.

## Code Style

- **MINIMAL COMMENTS** - code should be self-documenting
- Only comment the non-obvious "why", never the "what"
- Tests should live next to the code they test (colocation)

$SKILL_SECTION## Your Task

1. Read the full spec at \`$SPEC_PATH\`
2. Implement story #$FIRST_INCOMPLETE: "$CURRENT_TITLE"
3. Follow the verification steps listed in the story
4. Write/update tests next to the code they test
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

  # Log start to progress file (include skill if present)
  if [[ -n "$CURRENT_SKILL" ]]; then
    echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"story_id\":$FIRST_INCOMPLETE,\"status\":\"STARTED\",\"skill\":\"$CURRENT_SKILL\",\"notes\":\"Beginning story #$FIRST_INCOMPLETE (requires $CURRENT_SKILL skill)\"}" >> "$PROGRESS_PATH"
  else
    echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"story_id\":$FIRST_INCOMPLETE,\"status\":\"STARTED\",\"notes\":\"Beginning story #$FIRST_INCOMPLETE\"}" >> "$PROGRESS_PATH"
  fi

  # Build skill line for output
  SKILL_LINE=""
  if [[ -n "$CURRENT_SKILL" ]]; then
    SKILL_LINE="Required skill: $CURRENT_SKILL (invoke /$CURRENT_SKILL before implementing)"
  fi

  # Output setup message
  if [[ "$ONCE_MODE" == "true" ]]; then
    cat <<EOF
Go loop activated (PRD mode, ONCE)!

Mode: Single iteration (HITL)
Feature: $FEATURE_NAME
PRD: $PRD_PATH
Current story: #$FIRST_INCOMPLETE - $CURRENT_TITLE
Progress: $INCOMPLETE_COUNT of $TOTAL_STORIES remaining
${SKILL_LINE:+$SKILL_LINE
}
After this story completes, you'll stop for review.
Run /go $PRD_PATH --once to continue one story at a time.
Or run /go $PRD_PATH to switch to full loop mode.
EOF
  else
    cat <<EOF
Go loop activated (PRD mode)!

Feature: $FEATURE_NAME
PRD: $PRD_PATH
Current story: #$FIRST_INCOMPLETE - $CURRENT_TITLE
Progress: $INCOMPLETE_COUNT of $TOTAL_STORIES remaining
Max iterations: $MAX_ITERATIONS
${SKILL_LINE:+$SKILL_LINE
}
The stop hook is now active. When you complete a story, it will:
- Verify passes=true in prd.json
- Verify you committed
- Advance to the next story automatically

To cancel: /cancel-go
EOF
  fi
fi
