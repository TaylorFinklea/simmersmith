#!/usr/bin/env bash
# One-time install for the SimmerSmith Shopping skill.
#
# Creates a local .venv, installs the skill package, runs
# `playwright install chromium`, and symlinks this directory into
# ~/.claude/skills/ so Claude Code discovers it from any session.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

echo "==> creating .venv"
python3 -m venv .venv
.venv/bin/python -m pip install --upgrade pip

echo "==> installing simmersmith-shopping"
.venv/bin/pip install -e .

# PyXA is macOS-only and may not always be installable. Best-effort.
if .venv/bin/pip install -e ".[pyxa]" 2>/dev/null; then
    echo "==> PyXA installed (modern Reminders read path)"
else
    echo "==> PyXA install skipped — falling back to osascript at runtime"
fi

echo "==> installing playwright browsers"
.venv/bin/python -m playwright install chromium

# Skill discovery: symlink into ~/.claude/skills/ so Claude Code finds it.
SKILL_HOME="$HOME/.claude/skills"
mkdir -p "$SKILL_HOME"
LINK="$SKILL_HOME/simmersmith-shopping"
if [ -L "$LINK" ] || [ -e "$LINK" ]; then
    echo "==> ~/.claude/skills/simmersmith-shopping already exists; leaving alone"
else
    ln -s "$HERE" "$LINK"
    echo "==> linked $LINK -> $HERE"
fi

# Config dir for per-store profiles + .env.
mkdir -p "$HOME/.config/simmersmith/skill-profile"

cat <<'EOF'
==> done.

Next:
  .venv/bin/python -m simmersmith_shopping login --store aldi
  .venv/bin/python -m simmersmith_shopping login --store walmart
  # ...sams_club / instacart as desired

Then a real run:
  .venv/bin/python -m simmersmith_shopping --list "SimmerSmith"

Or a dry run that prints the proposed split:
  .venv/bin/python -m simmersmith_shopping --list "SimmerSmith" --dry-run
EOF
