#!/usr/bin/env python3
"""
Fork Suggestion Hook - Suggests forking similar past sessions.

Triggered on UserPromptSubmit. Queries qmd with YAKE-extracted keywords,
suggests fork command if relevant session found.

Exit codes:
- 0: Always (never block prompt submission)
"""

import json
import os
import subprocess
import sys

from keyword_extractor import extract_keywords, keywords_to_query

# Configuration
MIN_PROMPT_LENGTH = 20
QMD_COLLECTION = "claude-sessions"
TIMEOUT_SECONDS = 5.0


def check_qmd_available() -> bool:
    """Check if qmd CLI is available."""
    try:
        result = subprocess.run(
            ["which", "qmd"],
            capture_output=True,
            timeout=2.0,
        )
        return result.returncode == 0
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


def check_collection_exists() -> bool:
    """Check if claude-sessions collection exists in qmd."""
    try:
        result = subprocess.run(
            ["qmd", "status"],
            capture_output=True,
            text=True,
            timeout=3.0,
        )
        return QMD_COLLECTION in result.stdout
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False


def query_qmd(prompt: str) -> dict | None:
    """Query qmd for similar sessions. Returns first result or None."""
    # Extract keywords for focused BM25 search
    keywords = extract_keywords(prompt, max_keywords=6)
    query = keywords_to_query(keywords) if keywords else prompt

    try:
        result = subprocess.run(
            ["qmd", "search", query, "--json", "-n", "1", "-c", QMD_COLLECTION],
            capture_output=True,
            text=True,
            timeout=TIMEOUT_SECONDS,
        )
        if result.returncode != 0:
            return None

        # Handle "No results found." text response
        stdout = result.stdout.strip()
        if not stdout or stdout == "No results found.":
            return None

        results = json.loads(stdout)
        if isinstance(results, list) and len(results) > 0:
            return results[0]
        return None
    except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
        return None


def extract_session_id(file_path: str) -> str:
    """Extract session ID from qmd file path."""
    # Path format: qmd://claude-sessions/project/uuid.md
    basename = os.path.basename(file_path)
    return basename.replace(".md", "")


def format_suggestion(title: str, session_id: str) -> str:
    """Format fork suggestion as additionalContext."""
    return f"""🔍 SIMILAR PAST SESSION FOUND:

"{title}"

To fork and continue from this session, run in a NEW terminal:

  claude --resume {session_id} --fork-session

(Cannot fork mid-session - must start fresh with the fork flag)"""


def main():
    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    prompt = input_data.get("prompt", "")

    # Skip short prompts
    if len(prompt) < MIN_PROMPT_LENGTH:
        sys.exit(0)

    # Check qmd available
    if not check_qmd_available():
        sys.exit(0)

    # Check collection exists
    if not check_collection_exists():
        sys.exit(0)

    # Query qmd
    result = query_qmd(prompt)
    if not result:
        sys.exit(0)

    # Extract info
    title = result.get("title") or result.get("file") or ""
    file_path = result.get("file", "")

    if not title or not file_path:
        sys.exit(0)

    session_id = extract_session_id(file_path)
    if not session_id:
        sys.exit(0)

    # Output suggestion
    context = format_suggestion(title, session_id)
    print(json.dumps({"additionalContext": context}))
    sys.exit(0)


if __name__ == "__main__":
    main()
