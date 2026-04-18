# Phase Spec: Freemium Boundaries + Subscription (M5)

## Why this, why now

SimmerSmith now has four shippable differentiators — preference-aware AI planning (M1), Kroger-backed pricing (M2), Google/Apple auth (M3), and nutrition-aware rebalancing (M4). Every one of them costs us money to run. OpenAI tokens alone are real money per week-generation; Kroger calls are free today but rate-limited; Postgres and Fly machines scale with users.

Before launch we need an honest way for the app to pay for itself. That means:

1. A **free tier** that is real: new users can generate a week, approve it, and see grocery pricing once or twice without a paywall. Nothing about the core flow feels crippled.
2. **Paid "Pro"** that unlocks the high-cost, high-value features: unlimited AI generations, macro tracking, rebalance-this-day, and future household sharing.
3. **Server-enforced limits**. The iOS app is a view; the authoritative "can this user generate another week?" answer lives on the backend so a jailbroken client can't evade it.

This spec ships the plumbing: usage counting, a `subscriptions` record per user, a Fly-side entitlement check, StoreKit 2 integration on iOS, and a polished paywall. It does **not** ship household sharing or recipe images — those are separate M5+ phases that live on top of the Pro entitlement.

## Goal

A user can:

- Sign up, generate **one** week plan per month, see prices for one week per month, and view today's meals — all without paying.
- Hit a limit → see a single bottom-sheet paywall with two SKUs (monthly + annual) → subscribe → the limit disappears without leaving the app.
- Cancel in Settings → app continues to work for the paid period, degrades to free afterwards.

From the business side:

- Server logs every AI generation, every pricing fetch, and every rebalance against a monthly counter.
- The `POST /api/weeks/{id}/generate`, `POST /api/weeks/{id}/pricing/fetch`, and `POST /api/weeks/{id}/days/rebalance` endpoints all respect the same gate.
- We can change free-tier limits server-side without shipping a new app.

---

## Scope

Backend + iOS. New DB table for usage counters, new table for subscriptions, StoreKit 2 client on iOS, App Store Connect product configuration, webhook receiver for renewals/cancellations.

**Not in scope**:
- Web checkout / Stripe / any non-App-Store payment path. iOS-first.
- Promo codes, gift subscriptions, family sharing (the Apple kind), or educational pricing.
- Server-driven price experiments — we'll hardcode the tiers and ship.
- Grandfathering existing users to permanent Pro. They hit the free tier like everyone else (there are effectively zero users today).
- Anything in Settings beyond "Manage Subscription" and a status chip. No pricing comparison screen, no testimonials, no feature grid.

---

## Free tier limits (proposed)

| Action | Free | Pro |
|--------|------|-----|
| AI week generation | 1 / month | unlimited |
| Fetch Kroger prices | 1 / month | unlimited |
| Rebalance-this-day | 0 | unlimited |
| Dietary goal + macro rings | view-only (no rebalance CTA) | full |
| Manual meal editing | unlimited | unlimited |
| Recipe import | 5 / month | unlimited |
| Recipe favorites | unlimited | unlimited |

The numbers are a starting point — the point of the `UsageLimit` table is to change them later without a deploy.

---

## Architecture

### 1. Subscription model

New `Subscription` row per user, nullable.

```python
class Subscription(Base):
    user_id: str                   # unique
    product_id: str                # "simmersmith.pro.monthly" | "simmersmith.pro.annual"
    apple_original_transaction_id: str
    status: str                    # "active" | "expired" | "in_grace" | "refunded"
    current_period_starts_at: datetime
    current_period_ends_at: datetime
    auto_renew: bool
    cancelled_at: datetime | None
    raw_payload_json: str          # last Apple notification payload for debugging
    created_at: datetime
    updated_at: datetime
```

"User is Pro" = `subscription.status == "active"` and `current_period_ends_at > now()` (with Apple's grace period semantics).

### 2. Usage counters

```python
class UsageCounter(Base):
    user_id: str
    action: str                    # "ai_generate" | "pricing_fetch" | "rebalance_day" | "recipe_import"
    period_key: str                # "2026-04" (YYYY-MM, UTC)
    count: int
    updated_at: datetime
    __table_args__ = (UniqueConstraint("user_id", "action", "period_key"),)
```

Single row per (user, action, month). Bump-on-success, not bump-on-request, so a 500 from OpenAI doesn't burn a free generation.

### 3. Entitlement + gating

**File**: `app/services/entitlements.py` (new)

```python
def is_pro(session, user_id) -> bool: ...
def free_tier_limit(action: str) -> int: ...
def ensure_action_allowed(session, user_id, action: str) -> None:
    if is_pro(session, user_id):
        return
    limit = free_tier_limit(action)
    used = current_month_count(session, user_id, action)
    if used >= limit:
        raise UsageLimitReached(action, limit, used)
```

FastAPI dependency: `require_quota(action: str)` that calls the gate. Used by `generate_week_plan`, `fetch_pricing`, `rebalance_day_endpoint`. When raising, returns HTTP 402 with `{detail: str, action: str, limit: int, used: int}` so the iOS client can show the paywall.

Bump call (`increment_usage(session, user_id, action)`) happens in the success path after commit.

### 4. Apple receipt verification

Two paths, we implement both:

- **Client-driven** (at paywall close): iOS sends the App Store Server API `originalTransactionId` → backend `POST /api/subscriptions/verify` hits Apple's `/inApps/v1/transactions/{id}` endpoint, decodes the JWS response, persists the `Subscription` row. This is what unlocks the user right after they pay.
- **Webhook** (ongoing): Apple posts `V2DecodedPayload` notifications to `POST /api/subscriptions/apple-webhook`. We map `notificationType`/`subtype` to `status` transitions and update the row. Survives server restarts, refunds, renewals.

**Files**:
- `app/services/subscriptions.py` — Apple JWS verification (ES256 signed), transaction → Subscription upsert
- `app/api/subscriptions.py` — the two endpoints above
- `app/config.py` — add `apple_shared_secret`, `apple_issuer_id`, `apple_key_id`, `apple_private_key_pem` (from App Store Connect API key) — store as Fly secrets

### 5. StoreKit 2 on iOS

**File**: `SimmerSmith/SimmerSmith/Features/Paywall/` (new module)

- `SubscriptionStore.swift` — `@Observable` actor wrapping `StoreKit.Product.products(for:)`, `Product.purchase()`, and `Transaction.currentEntitlements`. Source of truth for "is this user Pro on device?" while offline.
- `PaywallSheet.swift` — bottom sheet presented by a `usageLimitReached` binding on `AppState`. Two SKU cards (monthly, annual), price pulled from StoreKit, "Restore Purchases" link, "Try for free" CTA if Apple's intro offer applies.
- `SubscriptionStatusRow.swift` — renders in Settings. "Pro — renews Jan 12" / "Free — 0 of 1 generations left this month".

**File**: `SimmerSmith/SimmerSmith/App/AppState+Subscription.swift` (new extension)

- `@Observable var isPro: Bool`
- `@Observable var usage: [UsageCounter]`
- `startObservingTransactions()` — kicked off at app launch; listens for StoreKit `Transaction.updates` and forwards the transaction to `/api/subscriptions/verify`.
- `presentPaywall(reason:)` — sets a state var that `RootView` observes to slide up the paywall sheet.

### 6. 402 handling in SimmerSmithKit

Current `SimmerSmithAPIError` has `.server(String)`. Add `.usageLimitReached(action: String, limit: Int, used: Int)`. In `decodeResponse`:

```swift
if http.statusCode == 402,
   let payload = try? decoder.decode(UsageLimitResponse.self, from: data) {
    throw SimmerSmithAPIError.usageLimitReached(action: payload.action, limit: payload.limit, used: payload.used)
}
```

Callers that catch this specifically (the Generate button, the Fetch Prices button, the Rebalance CTA) call `appState.presentPaywall(reason:)` instead of surfacing the raw error.

### 7. App Store Connect config

Out of code, but the spec must call it out:

- Two auto-renewing subscriptions in one subscription group:
  - `simmersmith.pro.monthly` — $4.99/mo, 7-day free trial as intro offer
  - `simmersmith.pro.annual` — $39.99/yr (33% off), no intro offer
- Upload review screenshot of the paywall
- Generate an App Store Connect API key → store key id / issuer id / private key in Fly secrets
- Configure App Store Server Notifications v2 → point at `https://simmersmith.fly.dev/api/subscriptions/apple-webhook`

---

## Acceptance criteria

Backend:
- [ ] Alembic migration adds `subscriptions` + `usage_counters`; all 111 existing tests still pass
- [ ] `is_pro(session, user_id)` returns false for any user without an active subscription row
- [ ] `POST /api/weeks/{id}/generate` returns 402 on the second call in a month for a free user, 200 when they have an active Pro subscription
- [ ] Same for `POST /api/weeks/{id}/pricing/fetch` and `POST /api/weeks/{id}/days/rebalance`
- [ ] Apple JWS verification accepts a signed sample payload from Apple's sandbox and rejects a signature-broken one
- [ ] Webhook handler handles `SUBSCRIBED`, `DID_RENEW`, `EXPIRED`, `REFUND`, `GRACE_PERIOD_EXPIRED` notification types and leaves the row in the correct `status`
- [ ] `/api/profile` response exposes the user's Pro state + remaining-month counts so the iOS app can render the badge

iOS:
- [ ] First-time user can generate a week (counter bumps 0 → 1) without seeing a paywall
- [ ] Second generate attempt in the same month shows the paywall sheet with "Free — used 1 of 1 this month"
- [ ] Sandbox purchase in StoreKit testing environment unlocks Pro and dismisses the paywall within 2 seconds
- [ ] `SubscriptionStatusRow` in Settings shows "Pro — renews Jan 12" with a "Manage in App Store" link
- [ ] Force-quit + relaunch → Pro state survives (StoreKit `currentEntitlements` is the local source of truth)
- [ ] Airplane-mode launch: last-known Pro state still renders; first sync after online catches up
- [ ] Canceling via App Store → we don't block immediately; at period end the next gated action shows the paywall

End-to-end:
- [ ] A new Apple ID subscribed through TestFlight unlocks Pro on a second device within 30 seconds (thanks to the webhook-driven upsert)
- [ ] A refund pushed through App Store Connect flips `status` to `refunded` and the next gated action 402s

---

## Sequencing (recommended)

1. **Backend: models + Alembic + is_pro stub + usage counters + 402 gate** (~2 sessions) — unblocks iOS work
2. **Backend: Apple JWS verification + `/subscriptions/verify` + webhook** (~1-2 sessions)
3. **iOS: SimmerSmithKit 402 path + AppState.isPro/usage + simple "locked" banner** (~1 session) — shippable stopgap where gated actions fail with a clear message
4. **iOS: StoreKit 2 integration + paywall sheet + Settings row** (~2 sessions)
5. **App Store Connect product config + Fly secrets + TestFlight sandbox purchase end-to-end** (~1 session)
6. **Polish: restore purchases, intro offer copy, paywall analytics events** (~1 session)

Each step leaves the app in a working state. After step 3 we have honest limits with a plain error; after step 4 users can actually pay; after step 5 we have real revenue.

---

## Risks

- **Apple review**. Paywalls get rejected for (a) blocking core function without explaining value, (b) missing "Restore Purchases", (c) unclear price/renewal copy. The paywall spec already covers these. Expect a 1-2 round review hassle.
- **Free-tier calibration**. If free users never experience the AI's quality on one generation they won't convert. We'll need to instrument conversion rate and tweak the monthly limits. Keep the limits in a server-side config so we don't need a client update.
- **Anti-abuse**. Apple's `originalTransactionId` is unique per Apple ID — no cheating by reinstalling. Multiple Apple IDs bypassing the limit is a theoretical concern but negligible at our scale.
- **Webhook idempotency**. Apple retries. The `subscriptions` upsert must use `apple_original_transaction_id` as the natural key to avoid double-inserts.
- **Grace period**. Apple gives a 16-day grace period on failed renewals. Respect it server-side so a temporary card decline doesn't lock a paying user out.
- **Tax / currency**. Apple handles price localization. We store the product_id only; the displayed price comes from the user's App Store.

---

## Out of scope (parked)

- Promo codes + educational pricing (post-launch feature flag)
- Web subscription / Stripe path (would require a separate receipt model and billing page; iOS-only for now)
- Household sharing tied to a Pro seat (M6 — depends on this spec)
- Pro-only recipe images (M6 — images are not gated in M5)
- Usage analytics dashboard (log to stdout → Fly log search is enough until we feel pain)
- Refund-abuse mitigation beyond what Apple provides
- Offer-based onboarding (giving Pro for 30 days to new signups) — clean to add later once the core gate works
