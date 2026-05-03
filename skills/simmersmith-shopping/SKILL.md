---
name: simmersmith-shopping
description: |
  Cart-automation for the SimmerSmith household grocery list. Reads
  the Apple Reminders list that the SimmerSmith iOS app mirrors
  into, resolves each item to per-store products + prices, computes
  an optimal split across Aldi / Walmart / Sam's Club / Instacart,
  and drives each store's web cart to "ready to check out" via
  Playwright. Stops short of placing orders so a human reviews each
  cart.

  Trigger this skill when the user says any of:
    - "shop the grocery list"
    - "fill the carts"
    - "split groceries this week"
    - "run shopping skill"
    - "do shopping"
  or any equivalent phrasing about turning a SimmerSmith grocery
  list into pre-filled retailer carts.
---

# SimmerSmith Shopping Skill

Local skill that turns a SimmerSmith grocery list into pre-filled
retailer carts. Discovered by Claude Code and Codex via this
`SKILL.md`. Has no side effects until invoked — it does NOT modify
the SimmerSmith app, the grocery list, or place any orders. It only
reads Reminders + drives browser windows to cart pages.

## How to invoke (no venv ceremony)

The skill is a [uv](https://github.com/astral-sh/uv)-managed Python
package. `uv run` reads `pyproject.toml`, creates a cached env on
first call, and reruns instantly thereafter — no `pip install`, no
`.venv/bin/python`, no activation step.

**Dry-run** (synthesize prices, print proposed split, no browsers):
```bash
uv run --project ~/.claude/skills/simmersmith-shopping \
  python -m simmersmith_shopping --list "SimmerSmith" --dry-run
```

**Real run** (open browsers, fill carts, stop at checkout):
```bash
uv run --project ~/.claude/skills/simmersmith-shopping \
  python -m simmersmith_shopping --list "SimmerSmith"
```

**One-time login per store** (interactive Playwright window; cookies
persist in `~/.config/simmersmith/skill-profile/<store>/`):
```bash
uv run --project ~/.claude/skills/simmersmith-shopping \
  python -m simmersmith_shopping login --store aldi
# repeat for walmart, sams_club, instacart
```

The first `uv run` is slow (resolving + installing deps); subsequent
runs reuse the cache and start in <1s. Playwright's chromium binary
downloads automatically the first time the skill needs a browser.

## Setup before first invoke

The skill uses `~/.claude/skills/simmersmith-shopping/` as its
discovery path. To install:

1. Clone the SimmerSmith repo if you haven't.
2. Symlink the skill directory:
   ```bash
   ln -s ~/git/simmersmith/skills/simmersmith-shopping \
         ~/.claude/skills/simmersmith-shopping
   ```
3. Optionally pre-warm dependencies:
   ```bash
   uv run --project ~/.claude/skills/simmersmith-shopping \
     python -c "from simmersmith_shopping import __version__; print(__version__)"
   ```

Or run `bash ~/git/simmersmith/skills/simmersmith-shopping/setup.sh`
to do all of the above plus install Playwright's chromium binary
in advance.

## Hand-off contract from M22

Each grocery reminder has a title in the form `"<qty> <unit> <name>"`
produced by the iOS layer. Parser is permissive: optional leading
number, optional unit, remainder is name. Notes field optional.
Skill skips reminders where `isCompleted == true`.

## When NOT to use this skill

- The user is asking about meal planning, recipe edits, or week
  composition. Those flow through the SimmerSmith iOS app or the
  in-app assistant.
- The user wants to add an item to the grocery list. That's the iOS
  app's `+` button on the Grocery tab. The skill READS the list, it
  does not write to it.
- The user wants to actually place an order. The skill stops at the
  cart page on purpose — the user reviews and clicks Checkout.
