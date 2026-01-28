#!/usr/bin/env bash
# Remove scheduled sync - detects OS and removes appropriate scheduler entry
#
# Usage: ./uninstall-scheduled-sync.sh

set -euo pipefail

uninstall_launchd() {
    local plist_path="$HOME/Library/LaunchAgents/com.claude.session-sync.plist"
    local label="com.claude.session-sync"

    if [[ -f "$plist_path" ]]; then
        echo "Unloading launchd job..."
        launchctl unload "$plist_path" 2>/dev/null || true
        rm -f "$plist_path"
        echo "✓ Removed launchd scheduler"
    else
        echo "No launchd scheduler found"
    fi
}

uninstall_cron() {
    local existing
    existing=$(crontab -l 2>/dev/null || echo "")

    if echo "$existing" | grep -q "session-sync"; then
        echo "$existing" | grep -v "session-sync" | crontab -
        echo "✓ Removed cron scheduler"
    else
        echo "No cron scheduler found"
    fi
}

# Main
echo "Uninstalling scheduled session sync..."
echo ""

if [[ "$OSTYPE" == "darwin"* ]]; then
    uninstall_launchd
else
    uninstall_cron
fi

echo ""
echo "Note: Log file preserved at ~/.claude/session-sync.log"
echo "Note: Indexed sessions preserved at ~/.claude/qmd-sessions/"
