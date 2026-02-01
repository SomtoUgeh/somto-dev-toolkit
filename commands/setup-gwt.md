---
name: setup-gwt
description: Install the gwt (git worktree manager) script
argument-hint: ""
context: fork
---

# Git Worktree Manager Setup

Install the `gwt` script for managing git worktrees as sibling directories.

## Step 1: Check if already installed

```bash
command -v gwt && gwt --version
```

If already installed and user is happy with version, STOP and confirm it's ready.

## Step 2: Create ~/.local/bin if needed

```bash
mkdir -p ~/.local/bin
```

## Step 3: Copy the script

```bash
cp "${CLAUDE_PLUGIN_ROOT}/scripts/gwt" ~/.local/bin/gwt
chmod +x ~/.local/bin/gwt
```

## Step 4: Check PATH

```bash
echo $PATH | grep -q "$HOME/.local/bin" && echo "PATH OK" || echo "PATH needs update"
```

If PATH needs update, add to shell config:

```bash
# Detect shell config file
SHELL_RC="$HOME/.zshrc"
[[ "$SHELL" == *"bash"* ]] && SHELL_RC="$HOME/.bashrc"

# Add to PATH if not already present
if ! grep -q '.local/bin' "$SHELL_RC" 2>/dev/null; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
    echo "Added to $SHELL_RC"
fi
```

## Step 5: Verify installation

```bash
~/.local/bin/gwt --version
```

## After Installation

Tell the user:

**gwt is installed!**

Usage:
```bash
gwt new feat/my-feature     # Create worktree
cd $(gwt go my-feature)     # Switch to it
gwt ls                      # List worktrees
gwt rm my-feature           # Remove worktree
```

**Note**: If you just added `~/.local/bin` to PATH, run `source ~/.zshrc` (or restart terminal) for `gwt` to work without full path.

## Uninstall

```bash
rm ~/.local/bin/gwt
```
