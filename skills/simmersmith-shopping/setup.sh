#!/usr/bin/env bash
# Convenience installer for the SimmerSmith Shopping skill.
#
# Optional — the skill works via `uv run --project ...` without ever
# running this script. setup.sh just pre-warms the dependency cache
# (so the first invocation isn't slow), installs the Playwright
# Chromium binary, and adds the discovery symlink under
# ~/.claude/skills/.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

if ! command -v uv >/dev/null 2>&1; then
    echo "==> uv not found. Install via:"
    echo "      brew install uv"
    echo "    or https://docs.astral.sh/uv/getting-started/installation/"
    exit 1
fi

echo "==> pre-warming dependency cache (first run downloads/compiles)"
uv sync --project "$HERE" 2>&1 | tail -5
uv run --project "$HERE" python -c "import simmersmith_shopping; print('  loaded', simmersmith_shopping.__version__)"

echo "==> installing Playwright chromium binary"
uv run --project "$HERE" python -m playwright install chromium

# Skill discovery: symlink into ~/.claude/skills/ so Claude Code + Codex find it.
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

cat <<EOF
==> done.

Next:
  uv run --project ~/.claude/skills/simmersmith-shopping \\
    python -m simmersmith_shopping login --store aldi
  uv run --project ~/.claude/skills/simmersmith-shopping \\
    python -m simmersmith_shopping login --store walmart

Then a real run:
  uv run --project ~/.claude/skills/simmersmith-shopping \\
    python -m simmersmith_shopping --list "SimmerSmith"

Or a dry run:
  uv run --project ~/.claude/skills/simmersmith-shopping \\
    python -m simmersmith_shopping --list "SimmerSmith" --dry-run
EOF
