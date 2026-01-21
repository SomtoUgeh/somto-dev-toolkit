#!/bin/bash

# PRD Loop Setup Script
# Creates state file and outputs initial phase prompt
#
# Usage:
#   setup-prd.sh                    # Interactive mode
#   setup-prd.sh <path>             # From existing file/folder
#   setup-prd.sh <idea description> # From idea

set -euo pipefail

# Parse arguments
INPUT="${*:-}"

# Create .claude directory if needed
mkdir -p .claude

# Read session_id from SessionStart hook
SESSION_ID=$(cat .claude/.current_session 2>/dev/null || echo "default")

STATE_FILE=".claude/prd-loop-${SESSION_ID}.local.md"

# Classify input
INPUT_TYPE="empty"
INPUT_PATH=""
FEATURE_NAME=""

if [[ -n "$INPUT" ]]; then
  # Check if it looks like a path
  if [[ "$INPUT" =~ ^[/~.] ]] || [[ "$INPUT" == *"/"* ]]; then
    # Normalize path
    INPUT_PATH="$INPUT"
    if [[ -f "$INPUT_PATH" ]]; then
      INPUT_TYPE="file"
      FEATURE_NAME=$(basename "$(dirname "$INPUT_PATH")")
    elif [[ -d "$INPUT_PATH" ]]; then
      INPUT_TYPE="folder"
      FEATURE_NAME=$(basename "$INPUT_PATH")
    else
      # Path-like but doesn't exist - treat as idea
      INPUT_TYPE="idea"
      FEATURE_NAME=$(echo "$INPUT" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-' | head -c 30)
    fi
  else
    INPUT_TYPE="idea"
    FEATURE_NAME=$(echo "$INPUT" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-' | head -c 30)
  fi
fi

# Generate unique feature name if empty
if [[ -z "$FEATURE_NAME" ]]; then
  FEATURE_NAME="feature-$(date +%s)"
fi

# Create state file with phase 1
cat > "$STATE_FILE" <<EOF
---
loop_type: "prd"
mode: "prd"
active: true
feature_name: "$FEATURE_NAME"
current_phase: "1"
input_type: "$INPUT_TYPE"
input_path: "$INPUT_PATH"
input_raw: "$INPUT"
spec_path: ""
prd_path: ""
progress_path: ""
interview_questions: 0
max_iterations: 0
gate_status: "pending"
review_count: 0
retry_count: 0
last_error: ""
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
---

# PRD Loop: Phase 1 - Input Classification

**Input type:** $INPUT_TYPE
**Raw input:** $INPUT

## Your Task

Based on the input type, take the appropriate action:

EOF

# Add phase-specific instructions based on input type
case "$INPUT_TYPE" in
  empty)
    cat >> "$STATE_FILE" <<'EOF'
**Empty input detected.** Use AskUserQuestion tool to ask:
"What feature or project would you like to spec out?"

After getting the answer, output:
```
<phase_complete phase="1" feature_name="NAME"/>
```

Where NAME is a slug-friendly name derived from their answer (lowercase, hyphens, alphanumeric).
EOF
    ;;
  file)
    cat >> "$STATE_FILE" <<EOF
**File detected:** \`$INPUT_PATH\`

1. Read the file contents
2. Extract the core feature/problem description
3. Identify any existing requirements or constraints

After reading and analyzing, output:
\`\`\`
<phase_complete phase="1" feature_name="$FEATURE_NAME"/>
\`\`\`
EOF
    ;;
  folder)
    cat >> "$STATE_FILE" <<EOF
**Folder detected:** \`$INPUT_PATH\`

1. Use Glob to find \`*.md\`, \`*.txt\`, \`*.json\` files in the folder
2. Read relevant files (README, spec, plan files)
3. Synthesize the feature context

After reading and analyzing, output:
\`\`\`
<phase_complete phase="1" feature_name="$FEATURE_NAME"/>
\`\`\`
EOF
    ;;
  idea)
    cat >> "$STATE_FILE" <<EOF
**Idea detected:** "$INPUT"

1. Parse the idea/description
2. Identify the core problem being solved
3. Note any implicit requirements

Ready for interview. Output:
\`\`\`
<phase_complete phase="1" feature_name="$FEATURE_NAME"/>
\`\`\`
EOF
    ;;
esac

# Output setup message
cat <<EOF
PRD loop activated!

Feature: $FEATURE_NAME
Input type: $INPUT_TYPE
State file: $STATE_FILE

The stop hook is now active. Complete each phase and output the
appropriate marker to advance to the next phase.

Current phase: 1 - Input Classification
EOF

# Output state file path for debugging
echo ""
echo "Read the state file above for your task."
