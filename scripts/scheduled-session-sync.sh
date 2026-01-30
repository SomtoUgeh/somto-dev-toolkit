#!/usr/bin/env bash
# Background session indexing - called by launchd every 30 min
#
# Runs incremental sync and embedding. Logs to ~/.claude/session-sync.log
# Safe to run concurrently (sync script handles locking internally)

set -euo pipefail

LOG_FILE="$HOME/.claude/session-sync.log"
MAX_LOG_SIZE=1048576  # 1MB

# Cross-platform filesize (GNU/BSD stat).
get_filesize() {
    local file="$1"
    local size="0"

    if size=$(stat -c %s "$file" 2>/dev/null); then
        :
    elif size=$(stat -f %z "$file" 2>/dev/null); then
        :
    else
        size=0
    fi

    if [[ ! "$size" =~ ^[0-9]+$ ]]; then
        size=0
    fi

    printf '%s' "$size"
}

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

# Rotate log if too large
if [[ -f "$LOG_FILE" ]] && [[ $(get_filesize "$LOG_FILE") -gt $MAX_LOG_SIZE ]]; then
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

# Update index (adds new files to collection)
log "Running qmd update..."
if qmd update >> "$LOG_FILE" 2>&1; then
    log "Update completed successfully"
else
    log "Update failed with exit code $?"
fi

# Run embedding
log "Running qmd embed..."
if qmd embed >> "$LOG_FILE" 2>&1; then
    log "Embedding completed successfully"
else
    log "Embedding failed with exit code $?"
fi

log "Scheduled sync complete"
