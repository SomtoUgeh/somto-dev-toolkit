#!/usr/bin/env python3
"""
Combined UserPromptSubmit hook: fork suggestion + memory injection.
Merges both outputs to avoid clobbering when multiple hooks run.

Outputs JSON with additionalContext:
- Fork suggestion for closest match
- Memory context for additional relevant sessions

Shares dedup file with PreToolUse memory_injection to avoid duplicate context.
"""

import json
import os
import shutil
import subprocess
import sys

from keyword_extractor import extract_keywords, keywords_to_query

MAX_RESULTS = 3
MIN_PROMPT_LENGTH = 20
QMD_COLLECTION = "claude-sessions"
TIMEOUT_SECONDS = 5.0


def sanitize_session_id(session_id: str) -> str:
    """Sanitize session ID for use in file paths."""
    return session_id.replace("/", "-").replace("\\", "-")


def get_shown_path(session_id: str) -> str:
    """Get dedup file path (shared with PreToolUse memory_injection)."""
    return f"/tmp/{sanitize_session_id(session_id)}_shown_memories"


def add_shown_memories(session_id: str, doc_ids: list[str]) -> None:
    """Track shown memories for dedup with PreToolUse."""
    if not session_id or session_id == "unknown":
        return
    path = get_shown_path(session_id)
    try:
        existing = set()
        if os.path.exists(path):
            with open(path) as f:
                content = f.read().strip()
                if content:
                    existing = set(content.split("\n"))
        existing.update(doc_ids)
        with open(path, "w") as f:
            f.write("\n".join(existing))
    except (PermissionError, OSError):
        pass


def query_qmd(prompt: str, num_results: int = MAX_RESULTS) -> list[dict]:
    """Query qmd with YAKE-extracted keywords."""
    if not shutil.which("qmd"):
        return []

    keywords = extract_keywords(prompt, max_keywords=6)
    query = keywords_to_query(keywords) if keywords else prompt[:200]

    try:
        result = subprocess.run(
            ["qmd", "search", query, "--json", "-n", str(num_results), "-c", QMD_COLLECTION],
            capture_output=True,
            text=True,
            timeout=TIMEOUT_SECONDS,
        )
        if result.returncode != 0:
            return []
        stdout = result.stdout.strip()
        if not stdout or stdout == "No results found.":
            return []
        results = json.loads(stdout)
        return results if isinstance(results, list) else []
    except (subprocess.TimeoutExpired, json.JSONDecodeError, FileNotFoundError):
        return []


def extract_session_id_from_path(file_path: str) -> str:
    """Extract session ID from qmd file path."""
    return os.path.basename(file_path).replace(".md", "")


def format_output(memories: list[dict]) -> tuple[str, str, list[str]]:
    """Format combined output: fork suggestion (first) + memory context (rest).

    Returns (user_message, claude_context, doc_ids):
    - user_message: Shown to user via systemMessage (fork suggestion only)
    - claude_context: Full context for Claude via additionalContext
    - doc_ids: Document IDs for deduplication
    """
    if not memories:
        return "", "", []

    user_parts = []
    context_parts = []
    doc_ids = []

    # First result: fork suggestion (shown to user AND Claude)
    first = memories[0]
    title = first.get("title", first.get("path", ""))
    file_path = first.get("file", first.get("path", ""))
    doc_id = first.get("id", file_path)

    if title and file_path:
        session_id = extract_session_id_from_path(file_path)
        # Truncate long titles for terminal display
        display_title = title[:50] + "..." if len(title) > 50 else title
        fork_msg = f'🔍 Related: "{display_title}"\n  claude --resume {session_id} --fork-session'
        user_parts.append(fork_msg)
        context_parts.append(f"""SIMILAR PAST SESSION FOUND:
"{title}"
Session ID: {session_id}
To fork: claude --resume {session_id} --fork-session""")
        doc_ids.append(doc_id)

    # Remaining results: memory context (Claude only, not shown to user)
    if len(memories) > 1:
        context_parts.append("\n📚 ADDITIONAL RELEVANT SESSIONS:")
        for mem in memories[1:MAX_RESULTS + 1]:
            mem_file = mem.get("file", mem.get("path", ""))
            title = mem.get("title", mem_file)
            snippet = mem.get("snippet", "")[:200].replace("\n", " ")
            doc_id = mem.get("id", mem_file)
            if not title:
                continue
            context_parts.append(f"\n• {title}")
            if snippet:
                context_parts.append(f"  {snippet}...")
            doc_ids.append(doc_id)

    return "\n".join(user_parts), "\n".join(context_parts), doc_ids


def main():
    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    prompt = input_data.get("prompt", "")
    if len(prompt) < MIN_PROMPT_LENGTH:
        sys.exit(0)

    # Query for fork + memory (get extra for both purposes)
    memories = query_qmd(prompt, num_results=MAX_RESULTS + 1)
    if not memories:
        sys.exit(0)

    user_message, claude_context, doc_ids = format_output(memories)
    if doc_ids:
        session_id = os.environ.get("CLAUDE_SESSION_ID", "")
        add_shown_memories(session_id, doc_ids)

        # Output JSON per hook docs:
        # - systemMessage (top-level): shown to user
        # - additionalContext (in hookSpecificOutput): injected to Claude
        output = {}
        if user_message:
            output["systemMessage"] = user_message
        if claude_context:
            output["hookSpecificOutput"] = {
                "hookEventName": "UserPromptSubmit",
                "additionalContext": claude_context,
            }
        if output:
            print(json.dumps(output))

    sys.exit(0)


if __name__ == "__main__":
    main()
