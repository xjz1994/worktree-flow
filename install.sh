#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Detect Claude Code commands directory.
# WSL: Claude Code runs on Windows native, NOT inside WSL.
# $HOME inside WSL = /home/xxx, but Claude reads from C:\Users\xxx\.claude\commands\
detect_commands_dir() {
  # Check if running under WSL
  if [ -f /proc/version ] && grep -qi microsoft /proc/version 2>/dev/null; then
    # Resolve Windows user profile
    local win_home
    win_home="$(cmd.exe /c "echo %USERPROFILE%" 2>/dev/null | tr -d '\r\n' || true)"
    if [ -z "$win_home" ]; then
      # Fallback: assume /mnt/c/Users/$SUDO_USER or $USER
      win_home="/mnt/c/Users/${SUDO_USER:-$USER}"
    fi
    local win_commands
    win_commands="$(wslpath -u "$win_home" 2>/dev/null || echo "$win_home")/.claude/commands"
    echo "$win_commands"
  else
    # Native Linux/macOS — standard path
    echo "$HOME/.claude/commands"
  fi
}

COMMANDS_DIR="$(detect_commands_dir)"
SCRIPTS_DIR="$COMMANDS_DIR/scripts"

echo "Installing worktree-flow to $COMMANDS_DIR ..."

mkdir -p "$COMMANDS_DIR"
mkdir -p "$SCRIPTS_DIR"

# Copy command entry
cp "$SCRIPT_DIR/worktree.md" "$COMMANDS_DIR/worktree.md"
echo "  -> $COMMANDS_DIR/worktree.md"

# Copy shell script
cp "$SCRIPT_DIR/scripts/worktree-flow.sh" "$SCRIPTS_DIR/worktree-flow.sh"
chmod +x "$SCRIPTS_DIR/worktree-flow.sh"
echo "  -> $SCRIPTS_DIR/worktree-flow.sh"

echo ""
echo "Install complete. Use /worktree in Claude Code."
echo ""
echo "Usage:"
echo "  /worktree init              Initialize main branch config"
echo "  /worktree sync              Sync worktree changes to main directory"
echo "  /worktree sync --force      Force-sync (direct copy, no merge)"
echo "  /worktree reject            Reject worktree (reset main to origin)"
echo "  /worktree reject --force    Force-reject (discard local commits)"
