# SimmerSmith Shopping Skill (M23)

Local Claude Code / Codex skill that turns a SimmerSmith grocery list
into pre-filled retailer carts. Reads from the Apple Reminders list
that the SimmerSmith iOS app mirrors into, runs Playwright against
Aldi / Walmart / Sam's Club / Instacart, and stops at "ready to
check out" so a human reviews each cart before placing the order.

Discovered as a Claude Code skill via `SKILL.md`. Triggered by user
phrases like "shop the grocery list", "fill the carts", "do shopping".

## Why this is a local skill, not a service

- Per-store cookies stay on your laptop in a Playwright profile.
- The retailers' anti-bot tooling is friendlier to a real Mac
  browser than a Fly.io egress.
- Cart review is naturally a "sit at the laptop" task — no benefit
  to running it in the cloud.

## Setup

The skill needs three things on first use:

1. **Discovery symlink** so Claude Code finds it:
   ```bash
   ln -s ~/git/simmersmith/skills/simmersmith-shopping \
         ~/.claude/skills/simmersmith-shopping
   ```
2. **uv** for env management — install via `brew install uv` or
   <https://docs.astral.sh/uv/getting-started/installation/>.
3. **Playwright browsers** — the skill auto-installs chromium on
   first browser-driving call, but you can pre-warm:
   ```bash
   uv run --project ~/.claude/skills/simmersmith-shopping \
     python -m playwright install chromium
   ```

The convenience script `setup.sh` does all three.

## First-run login per store

Each retailer needs a one-time interactive sign-in so the skill can
persist cookies. Run once per store:

```bash
uv run --project ~/.claude/skills/simmersmith-shopping \
  python -m simmersmith_shopping login --store aldi
```

A Playwright window opens. Sign in normally (handle 2FA, captchas,
whatever). Close the window when you see your account landing page.
Cookies are saved under `~/.config/simmersmith/skill-profile/aldi/`.

Repeat for `walmart`, `sams_club`, `instacart`.

## Run a shopping pass

```bash
uv run --project ~/.claude/skills/simmersmith-shopping \
  python -m simmersmith_shopping --list "SimmerSmith"
```

What happens:
1. Read the named Reminders list (default `"SimmerSmith"`).
2. Parse each unchecked title into `(qty, unit, name)`.
3. Ask each configured store for product candidates + prices.
4. Pick a 1- or 2-store split that minimizes total cost subject to
   per-store delivery minimums.
5. Open the chosen stores' carts in Playwright and add items.
6. Print a summary table and leave the browser windows open at the
   cart pages.

## Dry-run

```bash
uv run --project ~/.claude/skills/simmersmith-shopping \
  python -m simmersmith_shopping --list "SimmerSmith" --dry-run
```

Prints the parsed list + the proposed split + per-item store
assignment. Does NOT open any browser. Use this to confirm the
parser produced sensible items before driving real carts.

## Configuration

Optional `.env` file at `~/.config/simmersmith/skill.env`:

```
SIMMERSMITH_ALDI_MIN=35
SIMMERSMITH_WALMART_MIN=35
SIMMERSMITH_SAMS_MIN=50
SIMMERSMITH_INSTACART_MIN=10
SIMMERSMITH_MAX_STOPS=2

SIMMERSMITH_API_BASE=https://simmersmith.fly.dev
SIMMERSMITH_API_TOKEN=...   # bearer token from your iOS Settings (optional)
```

## Per-store handler status

| Store        | Status        | Notes                                            |
|--------------|---------------|--------------------------------------------------|
| Aldi         | scaffolded    | Login + cart-add patterns set; selectors filled. |
| Walmart      | scaffolded    | Login + cart-add patterns set; selectors filled. |
| Sam's Club   | stub          | Login flow works; product search is a TODO.     |
| Instacart    | stub          | Login flow works; product search is a TODO.     |

Stubs return zero candidates so the splitter naturally avoids them
until a human fills in the selectors. To complete a stub:
1. Open `src/simmersmith_shopping/stores/<store>.py`.
2. Replace `search_products` with the real selectors.
3. Replace `add_to_cart` with the real cart-button click.
4. Re-run a dry-run pass to verify product matches.

## Smoke tests

Self-contained — no Playwright, no Reminders, no network:

```bash
uv run --project ~/.claude/skills/simmersmith-shopping \
  python -m unittest discover tests -v
```

## What the skill never does

- Place an order — it stops at the cart page.
- Modify the SimmerSmith grocery list — it only reads.
- Persist credentials — Playwright's persistent context holds
  cookies; passwords stay in your password manager.
