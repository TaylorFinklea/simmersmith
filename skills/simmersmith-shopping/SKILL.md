---
name: simmersmith-shopping
description: |
  Cart-automation for the SimmerSmith household grocery list. Reads
  the Apple Reminders list that the SimmerSmith iOS app mirrors into,
  resolves each item to per-store products + prices, computes an
  optimal split across Aldi / Walmart / Sam's Club / Instacart, and
  drives each store's web cart to "ready to checkout" via Playwright.
  Stops short of placing orders so a human reviews the cart.

  Trigger this skill when the user says any of:
    - "shop the grocery list"
    - "fill the carts"
    - "split groceries this week"
    - "run shopping skill"
    - "do shopping"
  Or any equivalent phrasing about turning a SimmerSmith grocery list
  into pre-filled retailer carts.
---

# SimmerSmith Shopping Skill

## What this skill does

The SimmerSmith iOS app mirrors the household's weekly grocery list
into an Apple Reminders list of the user's choosing. This skill:

1. Reads that Reminders list.
2. Parses each title — `"<qty> <unit> <name>"` (e.g. `"2 cups flour"`).
3. For each item, asks each configured retailer (Aldi, Walmart,
   Sam's Club, Instacart) for current price + availability.
4. Computes a store-split that minimizes cost subject to:
   - per-store delivery minimums,
   - "no more than 2 stops" (configurable).
5. Opens each store's web UI in a Playwright window, adds the
   chosen items to the cart, and stops at the cart page so the user
   reviews and clicks Checkout.

## Workflow when invoked

Run the CLI:

```bash
cd ~/.claude/skills/simmersmith-shopping
.venv/bin/python -m simmersmith_shopping --list "SimmerSmith"
```

Or explicit stores / dry run:

```bash
.venv/bin/python -m simmersmith_shopping \
  --list "SimmerSmith" \
  --stores aldi,walmart \
  --dry-run
```

`--dry-run` prints the split + per-item store assignment without
opening any browser windows. Useful for verifying the parser and
splitter before doing real cart work.

## First-run setup

```bash
cd ~/.claude/skills/simmersmith-shopping
./setup.sh        # creates .venv, installs deps, runs `playwright install`
.venv/bin/python -m simmersmith_shopping login --store aldi
.venv/bin/python -m simmersmith_shopping login --store walmart
# repeat for sams_club, instacart
```

Each `login` command opens an interactive Playwright browser. Sign
in on the retailer's site; the persistent profile saves cookies in
`~/.config/simmersmith/skill-profile/<store>/`. Subsequent runs reuse
those cookies.

## When NOT to use this skill

- The user is asking about meal planning, recipe edits, or week
  composition. Those flow through the SimmerSmith iOS app or
  the assistant inside it.
- The user wants to add items to the grocery list. That's the iOS
  app's `+` button on the Grocery tab — the skill READS the list, it
  does not write to it.
- The user wants to actually place an order. The skill stops at the
  cart page on purpose — the user reviews and clicks Checkout.

## Hand-off contract from M22

Each grocery item in Reminders has:
- **Title** in the form `"<qty> <unit> <name>"` produced by
  `RemindersService.swift:remindersTitle(for:)`. Parser is permissive:
  optional leading number, optional unit, remainder is name.
- **Notes** field optionally carries source-meal context. Skill
  ignores notes for matching.
- **Completion state** = whether someone has checked the item off in
  the SimmerSmith app or Reminders.app. Skill skips completed items.

The skill MAY (not MUST) call SimmerSmith's bearer-token API for
richer base_ingredient / brand-preference metadata if string-only
matches are too ambiguous. Credentials live in
`~/.config/simmersmith/skill.env`.
