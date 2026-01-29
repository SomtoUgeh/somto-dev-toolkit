#!/usr/bin/env python3
"""
Memory Injection Hook - Injects relevant past session context before tool use.

Triggered on PreToolUse for: Read, Edit, Write, Glob, Grep
Queries qmd keyword search with YAKE-extracted keywords for focused results.

Exit codes:
- 0: Always (never block tool use)

Outputs JSON to stdout for additionalContext injection when relevant memories found.
"""

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

from keyword_extractor import extract_keywords, keywords_to_query

# Configuration
MAX_RESULTS = 3
MAX_THINKING_CHARS = 1500
TIMEOUT_SECONDS = 5.0
CONTEXT_TOOLS = {"Read", "Edit", "Write", "Glob", "Grep"}
QMD_COLLECTION = "claude-sessions"


def get_session_id() -> str:
    """Get session ID from environment or input."""
    return os.environ.get("CLAUDE_SESSION_ID", "unknown")


def sanitize_session_id(session_id: str) -> str:
    """Sanitize session ID for use in file paths."""
    return session_id.replace("/", "-").replace("\\", "-")


def get_transcript_path() -> str | None:
    """Get transcript path from environment."""
    return os.environ.get("CLAUDE_TRANSCRIPT_PATH")


def extract_last_thinking(transcript_path: str) -> str:
    """Extract last thinking block from transcript JSONL (tail for efficiency)."""
    try:
        # Read last 100 lines for efficiency
        result = subprocess.run(
            ["tail", "-n", "100", transcript_path],
            capture_output=True,
            text=True,
            timeout=2.0,
        )
        if result.returncode != 0:
            return ""

        lines = result.stdout.strip().split("\n")

        # Find last thinking block (reverse search)
        for line in reversed(lines):
            if not line.strip():
                continue
            try:
                entry = json.loads(line)
                # Look for assistant message with thinking
                if entry.get("type") == "assistant":
                    message = entry.get("message", {})
                    content = message.get("content", [])
                    for block in reversed(content):
                        if block.get("type") == "thinking":
                            thinking = block.get("thinking", "")
                            # Truncate for query efficiency
                            return thinking[:MAX_THINKING_CHARS]
            except json.JSONDecodeError:
                continue

        return ""
    except (subprocess.TimeoutExpired, FileNotFoundError, PermissionError):
        return ""


def get_hash_path(session_id: str) -> Path:
    """Get path for query hash dedup file."""
    return Path(f"/tmp/{sanitize_session_id(session_id)}_memory_hash")


def get_shown_path(session_id: str) -> Path:
    """Get path for shown memories dedup file (shared with prompt_context.py)."""
    return Path(f"/tmp/{sanitize_session_id(session_id)}_shown_memories")


def should_skip_query(session_id: str, thinking: str) -> bool:
    """Hash-based deduplication - skip if same query as last time."""
    if not thinking:
        return True

    current_hash = hashlib.md5(thinking.encode()).hexdigest()[:16]
    hash_path = get_hash_path(session_id)

    try:
        if hash_path.exists():
            last_hash = hash_path.read_text().strip()
            if last_hash == current_hash:
                return True

        # Store new hash
        hash_path.write_text(current_hash)
        return False
    except (PermissionError, OSError):
        return False


def get_shown_memories(session_id: str) -> set[str]:
    """Session-level deduplication - get already shown doc IDs."""
    shown_path = get_shown_path(session_id)
    try:
        if shown_path.exists():
            return set(shown_path.read_text().strip().split("\n"))
        return set()
    except (PermissionError, OSError):
        return set()


def add_shown_memories(session_id: str, doc_ids: list[str]) -> None:
    """Add doc IDs to shown memories."""
    shown_path = get_shown_path(session_id)
    try:
        existing = get_shown_memories(session_id)
        existing.update(doc_ids)
        shown_path.write_text("\n".join(existing))
    except (PermissionError, OSError):
        pass


def query_qmd(thinking: str) -> list[dict]:
    """Query qmd search with YAKE-extracted keywords.

    Uses 'search' (BM25 keyword) instead of 'vsearch' (semantic) because:
    - search is instant, vsearch needs ~1 min model load on first use
    - Real-time hooks need <5s response time

    YAKE extracts focused keywords from thinking to improve BM25 matching.
    Long text dilutes BM25 relevance - keywords fix this.
    """
    # Extract keywords for focused BM25 search
    keywords = extract_keywords(thinking, max_keywords=8)
    query = keywords_to_query(keywords) if keywords else thinking[:200]

    try:
        result = subprocess.run(
            [
                "qmd",
                "search",
                query,
                "--json",
                "-n",
                str(MAX_RESULTS + 2),  # Get extra for dedup
                "-c",
                QMD_COLLECTION,
            ],
            capture_output=True,
            text=True,
            timeout=TIMEOUT_SECONDS,
        )
        if result.returncode != 0:
            return []

        # Handle "No results found." text response
        stdout = result.stdout.strip()
        if not stdout or stdout == "No results found.":
            return []

        results = json.loads(stdout)
        return results if isinstance(results, list) else []
    except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
        return []


def format_context(memories: list[dict], shown: set[str]) -> tuple[str, list[str]]:
    """Format memories as concise additionalContext. Returns (context_str, new_doc_ids)."""
    if not memories:
        return "", []

    lines = ["📚 RELEVANT PAST SESSIONS:"]
    new_doc_ids = []
    count = 0

    for mem in memories:
        if count >= MAX_RESULTS:
            break

        doc_id = mem.get("id", mem.get("path", ""))
        if doc_id in shown:
            continue

        title = mem.get("title", mem.get("path", "Unknown"))
        snippet = mem.get("snippet", mem.get("content", ""))[:200]

        lines.append(f"\n• {title}")
        if snippet:
            # Clean up snippet
            snippet = snippet.replace("\n", " ").strip()
            lines.append(f"  {snippet}...")

        new_doc_ids.append(doc_id)
        count += 1

    if count == 0:
        return "", []

    lines.append(
        "\n\nTo fork a session, run: claude --resume <session-id> --fork-session"
    )
    return "\n".join(lines), new_doc_ids


def main():
    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    tool_name = input_data.get("tool_name", "")
    if tool_name not in CONTEXT_TOOLS:
        sys.exit(0)

    # Check if qmd is available
    if subprocess.run(["which", "qmd"], capture_output=True).returncode != 0:
        sys.exit(0)

    session_id = get_session_id()
    transcript_path = get_transcript_path()

    if not transcript_path:
        sys.exit(0)

    # Extract thinking for query
    thinking = extract_last_thinking(transcript_path)
    if not thinking:
        sys.exit(0)

    # Hash-based dedup
    if should_skip_query(session_id, thinking):
        sys.exit(0)

    # Query qmd
    memories = query_qmd(thinking)
    if not memories:
        sys.exit(0)

    # Session-level dedup
    shown = get_shown_memories(session_id)
    context, new_doc_ids = format_context(memories, shown)

    if context and new_doc_ids:
        # Track shown memories
        add_shown_memories(session_id, new_doc_ids)

        # Output for additionalContext injection
        output = {"additionalContext": context}
        print(json.dumps(output))

    sys.exit(0)


if __name__ == "__main__":
    main()
