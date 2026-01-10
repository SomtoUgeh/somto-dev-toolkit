#!/usr/bin/env python3
"""
Git Safety Guard - Blocks destructive git and filesystem commands.

Exit codes:
- 0: Allow command
- 2: Block command (stderr shown to Claude)
"""

import json
import re
import sys

DESTRUCTIVE_PATTERNS = [
    # git checkout that discards changes (but not branch operations)
    (r"git\s+checkout\s+--\s+", "git checkout -- discards uncommitted changes"),
    (r"git\s+checkout\s+\.\s*$", "git checkout . discards all uncommitted changes"),
    (r"git\s+checkout\s+HEAD\s+--", "git checkout HEAD -- discards changes"),

    # git restore without --staged (discards working tree changes)
    (r"git\s+restore\s+(?!.*--staged)(?!.*-S).*\S", "git restore discards uncommitted changes (use --staged for staging area)"),

    # git reset destructive variants
    (r"git\s+reset\s+--hard", "git reset --hard discards all uncommitted changes"),
    (r"git\s+reset\s+--merge", "git reset --merge can discard changes"),

    # git clean (removes untracked files)
    (r"git\s+clean\s+-[a-zA-Z]*f", "git clean -f permanently deletes untracked files"),

    # force push
    (r"git\s+push\s+.*--force(?!-with-lease)", "git push --force can overwrite remote history (use --force-with-lease)"),
    (r"git\s+push\s+.*-f(?:\s|$)", "git push -f can overwrite remote history"),

    # force delete branch
    (r"git\s+branch\s+-D", "git branch -D force deletes without merge check (use -d)"),

    # stash destruction
    (r"git\s+stash\s+drop", "git stash drop permanently deletes stashed changes"),
    (r"git\s+stash\s+clear", "git stash clear deletes ALL stashed changes"),

    # git rm (deletes files from working tree unless --cached)
    (r"git\s+rm\s+(?!.*--cached)", "git rm permanently deletes files (use --cached to only unstage)"),

    # rm -rf (except common temp/build dirs)
    (r"rm\s+-[a-zA-Z]*r[a-zA-Z]*f|rm\s+-[a-zA-Z]*f[a-zA-Z]*r", "rm -rf permanently deletes files"),
]

# Patterns that are safe despite matching destructive patterns
SAFE_PATTERNS = [
    r"git\s+checkout\s+-b",  # create new branch
    r"git\s+checkout\s+-B",  # create/reset branch
    r"git\s+checkout\s+--orphan",  # create orphan branch
    r"git\s+restore\s+--staged",  # unstage files (safe)
    r"git\s+restore\s+-S",  # unstage files (safe)
    r"rm\s+-rf\s+(/tmp/|/var/tmp/|node_modules|\.next|dist/|build/|__pycache__|\.pytest_cache|\.mypy_cache|target/|\.gradle|\.cache)",  # common build/temp dirs
]


def is_safe_command(command: str) -> bool:
    """Check if command matches a safe pattern."""
    for pattern in SAFE_PATTERNS:
        if re.search(pattern, command, re.IGNORECASE):
            return True
    return False


def check_destructive(command: str) -> tuple[bool, str]:
    """Check if command is destructive. Returns (is_destructive, reason)."""
    if is_safe_command(command):
        return False, ""

    for pattern, reason in DESTRUCTIVE_PATTERNS:
        if re.search(pattern, command, re.IGNORECASE):
            return True, reason

    return False, ""


def main():
    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)  # Can't parse, allow

    tool_name = input_data.get("tool_name", "")
    if tool_name != "Bash":
        sys.exit(0)  # Not a Bash command

    command = input_data.get("tool_input", {}).get("command", "")
    if not command:
        sys.exit(0)

    is_destructive, reason = check_destructive(command)

    if is_destructive:
        print(f"BLOCKED: {reason}", file=sys.stderr)
        print(f"Command: {command[:100]}{'...' if len(command) > 100 else ''}", file=sys.stderr)
        print("\nIf you need to run this command, ask the user to run it manually.", file=sys.stderr)
        sys.exit(2)

    sys.exit(0)


if __name__ == "__main__":
    main()
