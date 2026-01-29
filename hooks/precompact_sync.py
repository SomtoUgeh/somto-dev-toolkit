#!/usr/bin/env python3
"""
PreCompact hook - sync current session to qmd before compaction.
Skips embedding (60s+) - scheduled sync handles that.

Exit codes:
- 0: Always (never block compaction)
"""

import json
import os
import subprocess
import sys


def main():
    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    session_id = os.environ.get("CLAUDE_SESSION_ID")
    transcript_path = os.environ.get("CLAUDE_TRANSCRIPT_PATH")
    project_dir = os.environ.get("CLAUDE_PROJECT_DIR", os.getcwd())

    # Skip if missing required env vars
    if not session_id or not transcript_path:
        sys.exit(0)

    # Get sync script path from plugin root
    plugin_root = os.environ.get("CLAUDE_PLUGIN_ROOT")
    if not plugin_root:
        sys.exit(0)

    sync_script = os.path.join(plugin_root, "scripts", "sync-sessions-to-qmd.sh")
    if not os.path.exists(sync_script):
        sys.exit(0)

    # Run sync for this session only (--no-embed to stay under timeout)
    try:
        subprocess.run(
            [sync_script, "--single", transcript_path, session_id, project_dir, "--no-embed"],
            capture_output=True,
            timeout=30.0,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, PermissionError):
        pass  # Best effort - don't block compaction

    # NOTE: --no-embed flag skips qmd embed (60s+) - scheduled sync handles embedding

    sys.exit(0)


if __name__ == "__main__":
    main()
