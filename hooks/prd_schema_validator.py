#!/usr/bin/env python3
"""
PreToolUse hook to validate prd.json schema on Write operations.
Exit codes:
- 0: Valid or not a prd.json write
- 2: Invalid schema (blocks write, stderr shown to Claude)
"""
import json
import sys

REQUIRED_ROOT_FIELDS = {"title", "spec_path", "created_at", "stories", "log"}
REQUIRED_STORY_FIELDS = {"id", "title", "category", "skills", "depends_on", "acceptance_criteria", "passes", "priority", "completed_at", "commit"}
VALID_CATEGORIES = {"functional", "ui", "integration", "edge-case", "performance"}


def validate_prd(prd: dict) -> list[str]:
    """Validate PRD schema, return list of errors."""
    errors = []

    # Check root fields
    missing_root = REQUIRED_ROOT_FIELDS - set(prd.keys())
    if missing_root:
        errors.append(f"Missing root fields: {', '.join(sorted(missing_root))}")

    # Check stories is non-empty array
    stories = prd.get("stories")
    if not isinstance(stories, list):
        errors.append("'stories' must be an array")
        return errors
    if len(stories) == 0:
        errors.append("'stories' array must not be empty")
        return errors

    # Check log is array
    log = prd.get("log")
    if not isinstance(log, list):
        errors.append("'log' must be an array")

    # Validate each story
    priorities = []
    for i, story in enumerate(stories):
        prefix = f"stories[{i}]"

        # Check required fields
        if not isinstance(story, dict):
            errors.append(f"{prefix}: must be an object")
            continue

        missing = REQUIRED_STORY_FIELDS - set(story.keys())
        if missing:
            errors.append(f"{prefix}: missing fields: {', '.join(sorted(missing))}")
            continue

        # Type checks
        if not isinstance(story.get("id"), (int, float)):
            errors.append(f"{prefix}.id: must be a number")
        if not isinstance(story.get("title"), str):
            errors.append(f"{prefix}.title: must be a string")
        if not isinstance(story.get("category"), str):
            errors.append(f"{prefix}.category: must be a string")
        elif story["category"] not in VALID_CATEGORIES:
            errors.append(f"{prefix}.category: must be one of {', '.join(sorted(VALID_CATEGORIES))}")
        if not isinstance(story.get("skills"), list):
            errors.append(f"{prefix}.skills: must be an array")
        if not isinstance(story.get("depends_on"), list):
            errors.append(f"{prefix}.depends_on: must be an array")
        elif not all(isinstance(d, (int, float)) for d in story["depends_on"]):
            errors.append(f"{prefix}.depends_on: all items must be story IDs (numbers)")
        if not isinstance(story.get("acceptance_criteria"), list):
            errors.append(f"{prefix}.acceptance_criteria: must be an array")
        elif not all(isinstance(s, str) for s in story["acceptance_criteria"]):
            errors.append(f"{prefix}.acceptance_criteria: all items must be strings")
        elif len(story["acceptance_criteria"]) < 1:
            errors.append(f"{prefix}.acceptance_criteria: must have at least 1 item")
        if not isinstance(story.get("passes"), bool):
            errors.append(f"{prefix}.passes: must be a boolean")
        if not isinstance(story.get("priority"), (int, float)):
            errors.append(f"{prefix}.priority: must be a number")
        else:
            priorities.append(story["priority"])

        # completed_at and commit must be null or string
        for field in ["completed_at", "commit"]:
            val = story.get(field)
            if val is not None and not isinstance(val, str):
                errors.append(f"{prefix}.{field}: must be null or string")

    # Check unique priorities
    if len(priorities) != len(set(priorities)):
        errors.append("Duplicate priorities detected - each story must have unique priority")

    # Check priorities are sorted
    if priorities != sorted(priorities):
        errors.append("Priorities must be in ascending order")

    # Validate depends_on references valid story IDs
    all_ids = {s.get("id") for s in stories if isinstance(s, dict) and isinstance(s.get("id"), (int, float))}
    for i, story in enumerate(stories):
        if not isinstance(story, dict):
            continue
        deps = story.get("depends_on", [])
        if isinstance(deps, list):
            for dep in deps:
                if dep not in all_ids:
                    errors.append(f"stories[{i}].depends_on: references non-existent story ID {dep}")

    return errors


def main():
    try:
        input_data = json.load(sys.stdin)
    except json.JSONDecodeError:
        sys.exit(0)

    tool_name = input_data.get("tool_name", "")
    if tool_name != "Write":
        sys.exit(0)

    tool_input = input_data.get("tool_input", {})
    file_path = tool_input.get("file_path", "")

    # Only validate prd.json files
    if not file_path.endswith("prd.json"):
        sys.exit(0)

    content = tool_input.get("content", "")

    # Parse the JSON content
    try:
        prd = json.loads(content)
    except json.JSONDecodeError as e:
        print(f"BLOCKED: Invalid JSON in prd.json\n{e}", file=sys.stderr)
        sys.exit(2)

    # Validate schema
    errors = validate_prd(prd)
    if errors:
        print("BLOCKED: prd.json schema validation failed\n", file=sys.stderr)
        print("Errors:", file=sys.stderr)
        for error in errors:
            print(f"  - {error}", file=sys.stderr)
        print("\nFix these issues before writing prd.json.", file=sys.stderr)
        sys.exit(2)

    sys.exit(0)


if __name__ == "__main__":
    main()
