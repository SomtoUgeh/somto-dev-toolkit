#!/usr/bin/env bash
# Install scheduled sync - detects OS and uses appropriate scheduler
#
# macOS: launchd (30-min interval)
# Linux: cron (*/30 * * * *)
#
# Usage: ./setup-scheduled-sync.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC_SCRIPT="$SCRIPT_DIR/scheduled-session-sync.sh"

# Verify sync script exists
if [[ ! -x "$SYNC_SCRIPT" ]]; then
    echo "Error: Sync script not found or not executable: $SYNC_SCRIPT" >&2
    exit 1
fi

# Check if qmd is available
if ! command -v qmd &>/dev/null; then
    echo "Warning: qmd not found. Install qmd first for memory features to work."
    echo "  brew install qmd  # or see https://github.com/qmd-tools/qmd"
    echo ""
fi

install_launchd() {
    local plist_path="$HOME/Library/LaunchAgents/com.claude.session-sync.plist"
    local label="com.claude.session-sync"

    # Create LaunchAgents directory if needed
    mkdir -p "$HOME/Library/LaunchAgents"

    # Unload existing if present
    if launchctl list | grep -q "$label" 2>/dev/null; then
        echo "Unloading existing scheduler..."
        launchctl unload "$plist_path" 2>/dev/null || true
    fi

    # Get PATH for qmd (include common locations for macOS)
    local path_value
    path_value="$HOME/.bun/bin:$HOME/.local/bin:$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    # Write plist
    cat > "$plist_path" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$SYNC_SCRIPT</string>
    </array>
    <key>StartInterval</key>
    <integer>1800</integer>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>$path_value</string>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$HOME/.claude/session-sync.log</string>
    <key>StandardErrorPath</key>
    <string>$HOME/.claude/session-sync.log</string>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF

    # Load the job
    launchctl load "$plist_path"

    echo "✓ Installed launchd scheduler"
    echo "  Schedule: Every 30 minutes"
    echo "  Plist: $plist_path"
    echo "  Logs: ~/.claude/session-sync.log"
    echo ""
    echo "To verify: launchctl list | grep claude.session-sync"
    echo "To uninstall: ./scripts/uninstall-scheduled-sync.sh"
}

install_cron() {
    # Build PATH that includes common qmd install locations for Linux/WSL
    local path_value="$HOME/.bun/bin:$HOME/.local/bin:$HOME/.cargo/bin:/usr/local/bin:/usr/bin:/bin"
    local cron_cmd="*/30 * * * * PATH=$path_value $SYNC_SCRIPT >> $HOME/.claude/session-sync.log 2>&1"
    local cron_marker="# claude-session-sync"

    # Use temp file for reliable cron installation (pipe approach unreliable on some systems)
    local tmp_cron="/tmp/claude-cron-$$"
    crontab -l 2>/dev/null | grep -v "session-sync" > "$tmp_cron" || true
    echo "$cron_cmd $cron_marker" >> "$tmp_cron"
    crontab "$tmp_cron"
    rm -f "$tmp_cron"

    echo "✓ Installed cron scheduler"
    echo "  Schedule: Every 30 minutes"
    echo "  Logs: ~/.claude/session-sync.log"
    echo ""
    echo "To verify: crontab -l | grep session-sync"
    echo "To uninstall: ./scripts/uninstall-scheduled-sync.sh"

    # WSL-specific note
    if grep -qi microsoft /proc/version 2>/dev/null; then
        echo ""
        echo "⚠️  WSL detected: Ensure cron service is running:"
        echo "    sudo service cron start"
        echo "    # Or add to ~/.bashrc: sudo service cron status &>/dev/null || sudo service cron start"
    fi
}

# Main
echo "Setting up scheduled session sync..."
echo ""

if [[ "$OSTYPE" == "darwin"* ]]; then
    install_launchd
else
    install_cron
fi

# Run initial sync
echo ""
echo "Running initial sync..."
"$SYNC_SCRIPT"
