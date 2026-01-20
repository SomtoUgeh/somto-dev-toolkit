---
name: deslop
description: Remove AI-generated code slop from current branch
argument-hint: "[optional: specific file path]"
---

# Remove AI Code Slop

Check the diff against main and remove AI-generated slop introduced in this branch.

## Step 1: Get changed files

```bash
git diff main --name-only
```

If an argument was provided, focus only on that file.

## Step 2: For each file, compare with original

For each changed file:
1. Read the current version
2. Get the original from main: `git show main:<filepath>`
3. Compare style, patterns, and conventions

## Step 3: Remove slop

Use Edit tool to remove:

**Unnecessary comments:**
- Comments explaining obvious code (`// increment counter`, `// return the result`)
- Comments that weren't in the original and add no value
- Comments inconsistent with the file's existing style
- Redundant JSDoc/docstrings on simple functions

**Defensive over-engineering:**
- Try/catch blocks around code that can't throw
- Null checks on values already validated upstream
- Defensive checks in internal/trusted code paths
- Unnecessary `|| []` or `?? {}` defaults not present in similar code

**Type hacks:**
- `as any` or `as unknown` casts
- `@ts-ignore` / `@ts-expect-error` without clear reason
- `!` non-null assertions that hide real issues

**Style inconsistencies:**
- Verbose patterns when the file uses terse style
- Different naming conventions than the rest of the file
- Extra blank lines or formatting differences from original

**Over-abstraction:**
- Helper functions used only once
- Unnecessary intermediate variables
- Overly generic code for specific use cases

## Step 4: Report

Output ONLY a 1-3 sentence summary. No bullet points, no file lists, no explanations.

Example: "Removed 4 redundant comments and 2 unnecessary null checks. Simplified error handling in auth.ts."
