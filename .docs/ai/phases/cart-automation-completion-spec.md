# Phase Spec: Cart Automation Completion (M23 follow-up)

## Why this, why now

The `simmersmith-shopping` skill exists and works end-to-end for two
of its four supported retailers. `stores/aldi.py` and
`stores/walmart.py` carry real `data-testid`-first `_SELECTORS`
maps; `search_products` and `add_to_cart` drive their Playwright
contexts to "review-and-check-out" cleanly. `stores/sams_club.py`
and `stores/instacart.py` ship as stubs — their file-level
docstrings document exactly what's missing:

> "Login flow works (Playwright persistent profile + the URL
> below), but `search_products` and `add_to_cart` are intentionally
> stubbed — Sam's Club requires per-region store selection and SSO
> that's finicky to script."

While they stay stubbed, the splitter never assigns lines to those
stores, and real-world dogfood reduces to "fill Aldi + Walmart
carts and shop the other two by hand." Closing this gap converts
the skill from a two-store demo into the actual way Taylor shops a
SimmerSmith grocery list.

## Goal

`uv run --project ~/.claude/skills/simmersmith-shopping
python -m simmersmith_shopping --list "SimmerSmith"` opens four
Playwright windows — Aldi, Walmart, Sam's Club, Instacart — and
each lands on its cart-review screen with the items the splitter
assigned to it. Sam's Club uses the region/store the persistent
profile last saved; Instacart uses the storefront the profile last
selected. The skill still stops short of placing orders.

## Scope

In:
- `stores/sams_club.py` and `stores/instacart.py` go from stub to
  full handler. Each gets a real `_SELECTORS` map, a working
  `search_products` returning real `ProductCandidate`s, and a
  working `add_to_cart` that clicks the store's add button and
  verifies the cart count incremented.
- A new `capture` subcommand on the skill CLI:
  `python -m simmersmith_shopping capture --store sams_club`
  opens the persistent-profile browser pointed at the store, waits
  for the human to type a search and click a product manually, and
  dumps the rendered HTML + a ranked list of `[data-testid]` /
  `[aria-label]` / stable CSS attribute candidates around each
  interaction. Output lands in
  `~/.config/simmersmith-shopping/captures/<store>-<timestamp>/`.
- Selector-rot documentation: a "When a driver breaks" section in
  `SKILL.md` covering re-running `capture` and updating
  `_SELECTORS` without re-reading this spec.

Out:
- Cross-store price normalization, substitution logic, savings
  estimates — handled by the existing parser + splitter; no
  change.
- Anti-bot evasion beyond what Playwright's persistent profile
  already gives. If a store starts challenging us routinely, the
  fallback is "best-effort + log".
- Mobile-app cart automation. Web only.
- A fifth or sixth store. H-E-B / Costco / Kroger Boost are
  separate follow-ups.
- Order placement. Skill stops at "review and check out".

## Architecture

The `StoreHandler` ABC in `stores/base.py` already encodes the
driver contract. Each driver carries:

- `slug`, `display_name`, `default_login_url` properties
- `_SELECTORS: dict[str, str]` with at minimum `search_input`,
  `product_card`, `card_title`, `card_price`, `card_link`,
  `add_to_cart`
- `search_products(context, line) -> list[ProductCandidate]`
- `add_to_cart(context, candidate) -> bool`

`stores/aldi.py:32-50` is the canonical template. The two new
drivers will follow it exactly, differing only in URL conventions
and the per-store details that show up during capture.

### Capture subcommand

The only net-new code outside per-store files. Implementation
outline (lives in `cli.py`, ~80–120 lines):

1. Resume the same Playwright persistent profile the `login`
   subcommand seeded.
2. Navigate to the store's homepage; pause and prompt the human to
   type a search and click a product.
3. After each interaction, snapshot `page.content()` and walk the
   accessibility tree to enumerate every element carrying a
   `data-testid`, `aria-label`, `role`, or stable-shape `id`. For
   each, record a 200-char HTML excerpt for context.
4. Repeat after the human clicks ADD on the product page.
5. Write a single directory under
   `~/.config/simmersmith-shopping/captures/<store>-<UTC-iso>/`
   containing `search.html`, `product.html`, and `candidates.txt`.

The output is structured to make selector-writing a paste-from-grep
exercise — `grep -E '(data-testid|aria-label).+search' candidates.txt`
should surface the search-input selector immediately.

## Selector-authoring procedure

This is the per-driver workflow. Repeat for Sam's Club and
Instacart:

1. **Seed the persistent profile** (one-time):
   `python -m simmersmith_shopping login --store sams_club`
   then sign in manually in the window that opens. Cookies persist
   under `~/.config/simmersmith-shopping/playwright/sams_club`.

2. **Run capture**: `python -m simmersmith_shopping capture --store sams_club`
   and walk through a real search + ADD interaction.

3. **Author `_SELECTORS`** by reading `candidates.txt`. Priority:
   `data-testid` first, ARIA label second, role-based selector
   third, brittle CSS class last.

4. **Implement `search_products`** following the Aldi pattern:
   navigate to the store's search URL, wait for the
   `product_card` selector, harvest up to N candidates into
   `ProductCandidate(title, price, url, store_slug)`.

5. **Implement `add_to_cart`**: navigate to the candidate URL,
   click `add_to_cart`, wait for the cart drawer or
   cart-count badge to increment. Return `True` on success.

6. **Validate** by running the skill against a fixture grocery
   list containing one line each routed to Sam's Club and
   Instacart, and confirm both windows end on cart-review with the
   expected items.

## Acceptance criteria

- [ ] `python -m simmersmith_shopping --list "SimmerSmith" --dry-run`
      routes at least one line to Sam's Club and one to Instacart
      when those stores are in the household's configured store
      list.
- [ ] A live run against the same list opens four Playwright
      windows (Aldi, Walmart, Sam's Club, Instacart) and each
      lands on its cart-review screen with the expected items.
- [ ] When a selector fails, the error names the `_SELECTORS` key
      that mismatched, not a generic Playwright timeout. (Wrap
      every selector use in a small `_locate(key)` helper that
      raises a domain error on miss.)
- [ ] `capture` subcommand documented in `SKILL.md` so future
      selector rot is repairable without this spec.
- [ ] Existing pytest run in `skills/simmersmith-shopping/tests`
      still passes (parser + splitter coverage; drivers stay
      integration-only).

## Sequencing

1. **`capture` subcommand against Aldi** (~1 session). Aldi has
   a known-good `_SELECTORS` map already, so validating capture
   output against the shipped selectors is the cleanest way to
   confirm the tool works before pointing it at a store we can't
   independently verify against.
2. **Sam's Club selectors + driver** (~1 session). Bulk of the
   time is waiting on the Sam's Club site to behave consistently
   during capture, plus the per-region store-selector wrinkle.
3. **Instacart selectors + driver** (~1 session). Slightly harder
   because of storefront switching — Instacart fronts H-E-B,
   Costco, etc. Default to the storefront the profile saved last;
   add a `--storefront` flag if dogfood demands.
4. **End-to-end validation + `SKILL.md` selector-rot section**
   (~0.5 session).

Total: ~3–4 sessions.

## Risks

- **Class-name rotation.** Sam's Club especially A/B-tests. The
  `data-testid`-first ordering is the main mitigation; if a store
  rotates without warning the response is to re-run `capture` and
  edit `_SELECTORS` — bounded effort.
- **Anti-bot challenge.** Both stores occasionally pop an "are you
  human?" challenge. Playwright's persistent profile + slow user-
  typing emulation (already used in Aldi/Walmart) is normally
  enough. If it isn't, we accept best-effort behavior on those
  retailers rather than building deeper evasion.
- **Region / storefront coupling.** Sam's Club products vary by
  store; Instacart by storefront. Both default to the persistent
  profile's last selection. Per-run override is in scope only if
  the default proves wrong during dogfood.
- **Skill is local-only.** Cart automation runs on Taylor's mac
  because Apple Reminders (the source of truth) is local. Scope
  creep would be turning this into a Fly-hosted service; the
  design intentionally rejects that.

## Out of scope (parked)

- New retailers (H-E-B, Costco, Kroger Boost).
- Order placement — skill stops at "review cart".
- Cart-state persistence across runs.
- Background scheduling — skill is invoked, not scheduled.
- Native iOS UI to launch the skill from the app — the iOS user
  triggers it from a host-side Claude Code session today; that
  flow is unchanged.
