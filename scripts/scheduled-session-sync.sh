#!/usr/bin/env bash
# Background session indexing - called by launchd every 30 min
#
# Runs incremental sync and embedding. Logs to ~/.claude/session-sync.log
# Safe to run concurrently (sync script handles locking internally)

set -euo pipefail

LOG_FILE="$HOME/.claude/session-sync.log"
MAX_LOG_SIZE=1048576  # 1MB

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Rotate log if too large
if [[ -f "$LOG_FILE" ]] && [[ $(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null || echo 0) -gt $MAX_LOG_SIZE ]]; then
    mv "$LOG_FILE" "${LOG_FILE}.old"
fi

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

log "Starting scheduled session sync"

# Check if qmd is available
if ! command -v qmd &>/dev/null; then
    log "qmd not found, skipping"
    exit 0
fi

# Get plugin root (relative to this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/sync-sessions-to-qmd.sh"

if [[ ! -x "$SYNC_SCRIPT" ]]; then
    log "Sync script not found: $SYNC_SCRIPT"
    exit 1
fi

# Run incremental sync
log "Running incremental sync..."
if "$SYNC_SCRIPT" >> "$LOG_FILE" 2>&1; then
    log "Sync completed successfully"
else
    log "Sync failed with exit code $?"
fi

# Run embedding
log "Running qmd embed..."
if qmd embed >> "$LOG_FILE" 2>&1; then
    log "Embedding completed successfully"
else
    log "Embedding failed with exit code $?"
fi

log "Scheduled sync complete"
