#!/bin/bash

# =============================================================================
# SUBAGENT STOP HOOK - Quality Gates for PRD Research & Review Agents
# =============================================================================
#
# PURPOSE: Validates that subagents spawned during PRD workflow return
#          structured, actionable output before completing.
#
# SUPPORTED AGENT TYPES:
#   - somto-dev-toolkit:prd-codebase-researcher
#   - somto-dev-toolkit:prd-external-researcher
#   - somto-dev-toolkit:prd-complexity-estimator
#   - compound-engineering:research:git-history-analyzer
#   - compound-engineering:review:* (all review agents)
#   - compound-engineering:workflow:spec-flow-analyzer
#
# EXIT CODES:
#   0 + no JSON output: Allow subagent to stop
#   0 + JSON with decision=block: Block subagent, show reason to Claude
#
# =============================================================================

set -euo pipefail

export LC_ALL=C
export LANG=C

# Read hook input from stdin
HOOK_INPUT=$(cat)

# Validate JSON input
if [[ -z "$HOOK_INPUT" ]] || ! echo "$HOOK_INPUT" | jq empty 2>/dev/null; then
  exit 0  # Invalid input - allow completion
fi

# Extract subagent metadata
SUBAGENT_TYPE=$(echo "$HOOK_INPUT" | jq -r '.subagent_type // ""')
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | jq -r '.transcript_path // ""')

# Skip if no subagent type or transcript
if [[ -z "$SUBAGENT_TYPE" ]] || [[ -z "$TRANSCRIPT_PATH" ]] || [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  exit 0
fi

# =============================================================================
# Helper: Extract last assistant message from transcript
# =============================================================================
get_last_assistant_output() {
  local transcript="$1"
  local last_line=""
  local output=""

  if grep -Eq '"role"[[:space:]]*:[[:space:]]*"assistant"' "$transcript" 2>/dev/null; then
    last_line=$(grep -E '"role"[[:space:]]*:[[:space:]]*"assistant"' "$transcript" | tail -1)
    if [[ -n "$last_line" ]]; then
      output=$(printf '%s' "$last_line" | jq -r '
        .message.content |
        map(select(.type == "text")) |
        map(.text) |
        join("\n")
      ' 2>/dev/null || echo "")
    fi
  fi

  printf '%s' "$output"
}

# =============================================================================
# Helper: Extract regex (portable, no grep -P)
# =============================================================================
extract_regex() {
  local string="$1"
  local pattern="$2"
  if [[ $string =~ $pattern ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
  fi
}

# =============================================================================
# Validation Functions
# =============================================================================

# Validate research agent output has required sections
validate_research_output() {
  local output="$1"
  local agent_name="$2"
  local required_sections="$3"  # Pipe-separated: "Findings|Patterns|Files"

  if [[ -z "$output" ]]; then
    echo "{\"decision\": \"block\", \"reason\": \"$agent_name returned empty output. Please provide structured findings.\"}"
    return 1
  fi

  # Check for at least one required section
  if ! echo "$output" | grep -qE "##[[:space:]]*(${required_sections})"; then
    echo "{\"decision\": \"block\", \"reason\": \"$agent_name must return structured output with sections: ${required_sections//|/, }. Add markdown headers for your findings.\"}"
    return 1
  fi

  return 0
}

# Validate complexity estimator returns max_iterations
validate_complexity_output() {
  local output="$1"

  if [[ -z "$output" ]]; then
    echo "{\"decision\": \"block\", \"reason\": \"Complexity estimator returned empty output. Analyze PRD stories and output <max_iterations>N</max_iterations>.\"}"
    return 1
  fi

  # Extract max_iterations tag
  local iterations=""
  if [[ $output =~ \<max_iterations\>([0-9]+)\</max_iterations\> ]]; then
    iterations="${BASH_REMATCH[1]}"
  fi

  if [[ -z "$iterations" ]]; then
    echo "{\"decision\": \"block\", \"reason\": \"Complexity estimator must output <max_iterations>N</max_iterations> where N is the estimated iteration count. Analyze story complexity and estimate.\"}"
    return 1
  fi

  # Validate reasonable range (5-100)
  if [[ $iterations -lt 5 ]]; then
    echo "{\"decision\": \"block\", \"reason\": \"Estimated iterations ($iterations) too low. Minimum is 5. Re-evaluate - each story typically needs 1-3 iterations.\"}"
    return 1
  fi

  if [[ $iterations -gt 100 ]]; then
    echo "{\"decision\": \"block\", \"reason\": \"Estimated iterations ($iterations) too high. Maximum is 100. Consider if PRD should be split into phases.\"}"
    return 1
  fi

  return 0
}

# Validate review agent output has actionable feedback
validate_review_output() {
  local output="$1"
  local agent_name="$2"

  if [[ -z "$output" ]]; then
    echo "{\"decision\": \"block\", \"reason\": \"$agent_name returned empty output. Provide review findings.\"}"
    return 1
  fi

  # Check for some indicator of actual review (findings, issues, recommendations, or explicit "no issues")
  if ! echo "$output" | grep -qiE "(finding|issue|concern|recommend|suggest|improve|warning|critical|no issues|looks good|approved)"; then
    echo "{\"decision\": \"block\", \"reason\": \"$agent_name output doesn't contain review findings. Analyze the spec and report findings, concerns, or explicitly state 'no issues found'.\"}"
    return 1
  fi

  return 0
}

# =============================================================================
# Route by Subagent Type
# =============================================================================

LAST_OUTPUT=$(get_last_assistant_output "$TRANSCRIPT_PATH")

case "$SUBAGENT_TYPE" in
  # PRD Research Agents
  "somto-dev-toolkit:prd-codebase-researcher")
    validate_research_output "$LAST_OUTPUT" "Codebase researcher" "Existing Patterns|Files to Modify|Models|Services|Patterns Found"
    ;;

  "somto-dev-toolkit:prd-external-researcher")
    validate_research_output "$LAST_OUTPUT" "External researcher" "Best Practices|Code Examples|Pitfalls|Recommendations|Findings"
    ;;

  "compound-engineering:research:git-history-analyzer")
    validate_research_output "$LAST_OUTPUT" "Git history analyzer" "History|Evolution|Contributors|Changes|Commits|Patterns"
    ;;

  # Complexity Estimator (critical - can hang PRD if fails)
  "somto-dev-toolkit:prd-complexity-estimator")
    validate_complexity_output "$LAST_OUTPUT"
    ;;

  # Review Agents (all compound-engineering:review:* patterns)
  compound-engineering:review:*)
    REVIEWER_NAME=$(echo "$SUBAGENT_TYPE" | sed 's/compound-engineering:review://' | tr '-' ' ')
    validate_review_output "$LAST_OUTPUT" "$REVIEWER_NAME"
    ;;

  # Spec Flow Analyzer
  "compound-engineering:workflow:spec-flow-analyzer")
    validate_review_output "$LAST_OUTPUT" "Spec flow analyzer"
    ;;

  # Skill extraction agents (Explore type)
  "Explore")
    # Only validate if this looks like a skill extraction task
    if echo "$HOOK_INPUT" | jq -r '.prompt // ""' | grep -qi "skill"; then
      validate_research_output "$LAST_OUTPUT" "Skill extractor" "Pattern|Anti-pattern|Example|Constraint|Implementation"
    fi
    ;;

  *)
    # Unknown agent type - allow completion
    ;;
esac

# If we get here without outputting JSON, allow completion
exit 0
