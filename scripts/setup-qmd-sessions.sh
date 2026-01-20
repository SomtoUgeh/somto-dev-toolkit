#!/usr/bin/env bash
# setup-qmd-sessions.sh - One-time setup for qmd session indexing
#
# Usage: ./setup-qmd-sessions.sh
#
# This script:
# 1. Syncs all Claude Code sessions to markdown
# 2. Creates qmd collection pointing to session files
# 3. Adds context description for better search
# 4. Generates embeddings

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSIONS_DIR="$HOME/.claude/qmd-sessions"

echo "Setting up qmd session indexing..."
echo ""

# Check dependencies
if ! command -v qmd &>/dev/null; then
  echo "Error: qmd is not installed"
  echo "Install with: bun install -g https://github.com/tobi/qmd"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "Error: jq is not installed"
  echo "Install with: brew install jq"
  exit 1
fi

# Ensure output directory exists
mkdir -p "$SESSIONS_DIR"

# Run full sync
echo "Step 1: Syncing sessions to markdown..."
"$SCRIPT_DIR/sync-sessions-to-qmd.sh" --full
echo ""

# Create/update qmd collection
echo "Step 2: Creating qmd collection..."
qmd collection add "$SESSIONS_DIR" --name claude-sessions --mask "**/*.md" 2>/dev/null || true
echo "  ✓ Collection: claude-sessions"

# Add context for better search understanding
echo "Step 3: Adding context..."
qmd context add qmd://claude-sessions "Claude Code session transcripts - coding conversations, debugging sessions, feature implementations, and project discussions" 2>/dev/null || true
echo "  ✓ Context added"

# Generate embeddings
echo ""
echo "Step 4: Generating embeddings (this may take a while on first run)..."
qmd embed
echo ""

# Show status
echo "Step 5: Verifying setup..."
qmd status
echo ""

# Count documents
doc_count=$(find "$SESSIONS_DIR" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✓ qmd session indexing ready!"
echo ""
echo "  Collection: claude-sessions"
echo "  Documents:  $doc_count sessions indexed"
echo "  Output:     $SESSIONS_DIR"
echo ""
echo "Usage:"
echo "  qmd query \"your search\" -c claude-sessions"
echo "  /fork-detect <what you want to do>"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
