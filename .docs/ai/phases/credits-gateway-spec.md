# Credits Gateway — keyless-user AI monetization (bx1 / 98v relaunch)

> Status: DRAFT (Fable, 2026-07-09) — panel review pending. Post-launch track; nothing here
> blocks submission. Product decisions locked with user 2026-07-09: **subscription with monthly
> AI allowance** (reuse `simmersmith.pro.monthly`/`.annual`) · **one-time trial grant** for
> keyless users · **Cloudflare Worker + D1** hosting. Supersedes nothing; realizes ADR-2's
> "credits-gateway tier on a small non-Fly endpoint."

## 1. Problem

Keyless users have zero cloud AI (BYO-key is the only path; on-device parse is flagged off
until AFM quality clears). ADR-2 killed Fly-era server enforcement; `AITier.creditsGateway`
exists in `ProviderRouter` but nothing serves it. Post-launch revenue = Pro subscription whose
AI allowance is fulfilled by a gateway holding OUR provider key.

## 2. Shape (one paragraph)

A single Cloudflare Worker exposes (a) an **OpenAI-compatible `/v1/chat/completions` proxy**
that meters usage against a D1 credit ledger and forwards to our upstream provider(s) with a
Worker-secret key, and (b) an **App Store Server Notifications v2 receiver** that maintains
subscription entitlement + monthly allowance cycles in D1. The iOS app treats the gateway as
one more open-models vendor: a `ProviderDescriptor` whose baseURL is the Worker and whose
bearer is a **gateway session token** — the existing descriptor-driven chat/stream/tool-loop
code paths reuse unchanged. Identity is **`appAccountToken`** (a UUID the app mints once per
iCloud user, persisted in the CloudKit private plane so it survives reinstall) set on every
StoreKit purchase, plus **App Attest** on session acquisition to keep trial farming and proxy
abuse bounded.

## 3. Identity & auth (the crux)

No accounts, no sign-in. Three subjects, one precedence chain:

1. **Subscriber**: app mints `userToken = UUID()` once, stores it in the CloudKit **private
   plane** (per-user, survives reinstall, syncs across the user's devices); sets it as
   `Product.PurchaseOption.appAccountToken` on every purchase (this also closes the F23/F24
   Fly-era follow-up). The signed transaction JWS then carries it; ASSN payloads carry it.
   **The token must be minted and CONFIRMED PERSISTED before `purchase()` is called** — a
   silent private-plane write failure would bind the purchase to nothing (panel F2). If the
   write fails, block the purchase with a retryable error rather than proceeding tokenless.
2. **Trial user (keyless, no purchase)**: session acquisition sends an **App Attest**
   assertion (`DCAppAttestService`) over a **server-issued challenge** (`GET /v1/challenge`,
   single-use, short TTL, bound to the assertion) — without challenge-response the assertion
   is trivially replayable (panel F3). Worker verifies with Apple and keys the one-time grant
   on the attest key id. Bounded fraud accepted: reinstall/device-reset mints a new attest key
   — the grant size prices that in. Belt-and-braces: the app also records a `trialClaimed`
   marker in the CloudKit private plane and self-reports it; the Worker treats a self-reported
   claim as authoritative-deny (cheap honesty check, blocks casual re-claims).
3. **Session**: `POST /v1/session` with either a transaction JWS (subscriber) or an App Attest
   assertion (trial). Worker verifies — **JWS x5c chain to Apple Root CA, not just the leaf**
   (the F22 lesson) — and returns a short-lived signed session token (JWT, ~24h, subject =
   userToken or attest key id). The app stores it in the Keychain under the existing
   provider-key plumbing (keychain id `gateway`).

Precedence in `ProviderRouter` is unchanged: BYO-key beats creditsGateway; the gateway serves
only when no key is configured and `creditsAvailable` (valid session + balance > 0).

### 3.1 Family Sharing — the identity hole, named (panel F1, CRITICAL)

If the Pro subscription is Family Shareable, non-purchasing family members receive entitlement
through `Transaction.currentEntitlements` **carrying the ORGANIZER's `appAccountToken`** — they
have no purchase of their own and therefore no token of their own. The naive design collapses an
entire family into one ledger subject: "credits are per-Apple-ID" is **false** for families, and
one member drains the household's allowance.

**Decision: disable Family Sharing on the Pro products for v1** (App Store Connect toggle;
`isFamilyShareable = false`). Rationale: SimmerSmith's sharing unit is already the *household*
(owner + one partner via CKShare), not the Apple family group, and the two do not coincide. A
partner who wants AI uses their own subscription or their own key — the same rule as taste
signals, allergies, and push toggles, all of which are user-scoped by design (M21 ADR).

If Family Sharing is ever enabled, the gateway must (a) detect the shared entitlement
(`Transaction.ownershipType == .familyShared`), (b) refuse to key the ledger on the organizer's
token, and (c) require App Attest to establish a per-member subject with its own allowance slice.
That is a materially larger design; it is explicitly out of v1 scope, and enabling the ASC toggle
without it is a **data-integrity regression**, not a growth lever.

## 4. Worker endpoints (contract — spec-exact; two implementers must not diverge)

| Route | Auth | Behavior |
|---|---|---|
| `GET /v1/challenge` | none | single-use nonce (60s TTL, stored in the subject DO / KV) for App Attest |
| `POST /v1/session` | JWS or App Attest assertion + challenge | verify → upsert subject → session JWT + balance snapshot |
| `GET /v1/balance` | session JWT | credits, cycle reset date, grant state |
| `POST /v1/chat/completions` | session JWT | DO-serialized reserve → upstream forward (SSE) → settle actual usage → `402` when exhausted |
| `POST /assn` | Apple (signedPayload JWS) | verify chain → dedup by `notificationUUID` → update entitlement + allowance cycle |

**Response schemas are normative** (panel F15/F16 — unspecified shapes are the classic
two-incompatible-halves failure):

```jsonc
// POST /v1/session → 200
{"session_token":"<JWT>","expires_at":1783600000,
 "balance":{"credits":420,"cycle_grant":500,"cycle_resets_at":1786000000},
 "kind":"subscriber"}                                  // "subscriber" | "starter"
// JWT claims: {iss:"simmersmith-gw", sub:<subject>, kind, iat, exp, jti}
//   exp = iat + 3600 (1h — see §5.2 revocation). NO balance in the token.
// Errors, everywhere, OpenAI-shape:
{"error":{"message":"…","type":"insufficient_credits","code":"allowance_exhausted"}}
```

`type`/`code` are load-bearing. `402` distinguishes **three** states (panel F9 — conflating them
is an App Review trap and a UX lie):
`starter_exhausted` (no purchase yet → show paywall) · `allowance_exhausted` (subscriber, cycle
spent → show "resets on <date>", **never** a paywall) · `subscription_lapsed` (→ restore/renew).
The existing `AIError.errorDescription` HTTP path renders these with no new client transport.

**Language lock (panel F10):** the keyless grant is called **"starter credits"**, never "free
trial" — App Store guidelines attach specific meaning to trials on subscriptions, and this grant
is not one. `users.kind = 'starter'`, not `'trial'`.

## 5. Ledger (D1 — spec-exact; columns may gain, never lose)

```sql
users(subject TEXT PRIMARY KEY, kind TEXT CHECK(kind IN ('subscriber','starter')),
      created_at INTEGER, starter_claimed_at INTEGER)
entitlements(subject TEXT PRIMARY KEY REFERENCES users(subject),
      original_transaction_id TEXT, product_id TEXT,
      apple_status INTEGER,             -- Apple's raw status, stored verbatim
      effective_state TEXT,             -- derived: active|grace|retry|lapsed|revoked
      last_notification_type TEXT, grace_period_expires_at INTEGER,
      billing_retry_started_at INTEGER, expires_at INTEGER,
      cycle_started_at INTEGER, last_transaction_id TEXT, updated_at INTEGER)
entitlement_history(id INTEGER PRIMARY KEY AUTOINCREMENT, subject TEXT, transaction_id TEXT,
      product_id TEXT, notification_type TEXT, at INTEGER)   -- append-only; proration forensics
balances(subject TEXT PRIMARY KEY REFERENCES users(subject), credits INTEGER NOT NULL,
      cycle_grant INTEGER NOT NULL, updated_at INTEGER)
usage_events(id INTEGER PRIMARY KEY AUTOINCREMENT,
      subject TEXT NOT NULL REFERENCES users(subject),
      request_id TEXT NOT NULL UNIQUE,   -- client-supplied; retry idempotency
      feature TEXT, model TEXT, prompt_tokens INTEGER, completion_tokens INTEGER,
      credits_debited INTEGER, settled INTEGER NOT NULL DEFAULT 0, created_at INTEGER)
assn_dedup(notification_uuid TEXT PRIMARY KEY, received_at INTEGER)

CREATE INDEX ix_usage_subject_time ON usage_events(subject, created_at);
CREATE INDEX ix_entitlements_origtxn ON entitlements(original_transaction_id);
```

**Credit unit**: 1 credit ≈ 1k normalized upstream tokens (completion weighted ×3 vs prompt),
rounded up per call, **scaled by a per-model cost multiplier** in env config — a flat unit does
not survive multiple upstreams at different prices. `MONTHLY_ALLOWANCE`, `STARTER_GRANT`, and the
multiplier table are activation-time parameters set when 98v flips.

### 5.1 Concurrency: one writer per subject (panel F5 — CRITICAL, found independently by two reviewers)

D1 has no row locks. `SELECT credits; UPDATE credits - N` races: two concurrent streams both read
`100`, both pass, the second write lands on a stale read. **Decision: a per-subject Durable
Object owns the token bucket AND the balance.** One writer per subject makes the debit trivially
serial — no CAS, no optimistic-retry loop — and the rate limiter (which a stolen session token
otherwise uses to drain the upstream budget) lives in the same object for free. D1 stays the
durable ledger the DO writes through to; `usage_events.request_id UNIQUE` makes client retries
idempotent even if a DO is evicted mid-flight.

**Reserve → settle**, never check-then-debit: the DO reserves a conservative estimate before
forwarding, then settles to the true cost when usage lands (`settled=1`).

### 5.2 Streaming, aborts, and unknown usage (panel — the mechanism the draft hand-waved)

- **Do not `tee()` the upstream body.** A client abort cancels the tee'd reader and the Worker
  never sees the final `usage` frame. Instead pump upstream chunks into a Worker-owned
  `ReadableStream`; on client cancel, **keep draining upstream inside `ctx.waitUntil(...)`**
  until it closes, then settle the reservation.
- Request `stream_options:{include_usage:true}` on OpenAI-shape upstreams. Per-upstream usage
  extraction must be specified per descriptor (Anthropic splits input/output across
  `message_start` / `message_delta`) — auto-detection is not a plan.
- **Usage unknown** (truncation, upstream 5xx mid-frame, network drop): keep the reservation as
  the charge and mark `settled=0`; a reconciliation pass corrects it if the frame ever lands.
  Over-estimate then refund; never double-debit, never bill zero.

### 5.3 Entitlement state, not a boolean (panel F18)

ASSN v2 emits `GRACE_PERIOD`, `BILLING_RETRY` (60-day window), upgrades/downgrades, `REFUND` vs
`REVOKE`. Store Apple's raw status and derive `effective_state`; `grace`/`retry` keep serving
(that is the point of a grace period), `revoked` zeroes the balance immediately.
**Revocation gap (panel F6/HIGH):** a 24h session JWT lets a revoked user drain credits for a
day, and `Transaction.updates` only fires to a foregrounded app. Therefore: **1h JWT** + the
gateway re-reads the entitlement row on every `/v1/chat/completions` call and 402s on
`revoked`/`lapsed`. The JWT authenticates; it never carries entitlement or balance.

## 6. iOS integration (codebase-derived — mirror, don't invent)

- **New descriptor, zero new transport**: add a `gateway` vendor served by the existing
  descriptor-driven open-models path (`chatWithToolsOpenModels` / `streamWithToolsOpenModels`
  — find the `ProviderDescriptor` for Ollama Cloud and mirror it; baseURL = Worker,
  `modelsURL: nil`, reasoning `.none`). It is NOT user-visible in the vendor picker; the
  router selects it, Settings shows it as "SimmerSmith AI (included with Pro)".
- **Session acquisition** lives beside `SubscriptionStore` (it already retains
  `lastSignedTransaction` "for a future backend-verification path" — that future is this).
  Refresh the gateway session on launch and on `Transaction.updates`.
- **`appAccountToken` at purchase**: extend `SubscriptionStore.purchase(_:)` with
  `Product.PurchaseOption.appAccountToken(userToken)`; mint + persist the token in the
  private plane (mirror how per-user profile rows are stored there today — read the
  pantry-profile private-plane path first).
- **Paywall relaunch (98v)**: `MonetizationFlags` flips at activation; `presentPaywall` choke
  point already exists; paywall copy adds the allowance framing. ASC products + `.storekit`
  config = existing beads (98v children, 2kv).
- **Router wiring**: `creditsAvailable` = session valid && balance > 0 (cached snapshot,
  refreshed opportunistically; a 402 mid-call flips it false and surfaces the paywall).

## 7. Privacy & compliance

- The gateway proxies prompt content → **privacy policy addendum required at activation**
  (NOT at app launch — the feature is dark until 98v flips). Data handling: no prompt
  persistence, usage_events store token counts only. ASC nutrition label gains
  "user content → app functionality, not linked" for the gateway path when it activates.
- IAP-compliant by construction: the only purchase is the existing App Store subscription;
  the gateway never takes payment.
- App Review: the trial grant gives reviewers a working AI path with no key and no purchase.

## 8. What this spec deliberately does NOT do

- No consumable credit packs (deferred; ledger supports them — a pack is just a
  `balances.credits +=` fulfillment from a new consumable product's ASSN/JWS).
- No multi-provider routing logic in v1: one upstream (env-config base URL + key; pick at
  activation — Ollama Cloud subscription is the default candidate). Failover is a config
  change, not code.
- No household-shared allowance: credits are per-Apple-ID (per userToken). A household's
  partner uses their own trial/subscription. Revisit only with real demand.
- No on-device fallback logic here — ProviderRouter already owns tier precedence.

## 9. Sequencing (beads to file under epic 98v; bx1 closes when this spec is approved)

1. `gw-1` Worker scaffold: D1 schema + `/v1/session` (JWS chain verify + App Attest) + tests
   (senior · M — new repo `simmersmith-gateway` or `gateway/` dir, user picks at impl time)
2. `gw-2` proxy + metering + 402 + rate limit (senior · M, depends gw-1)
3. `gw-3` ASSN receiver + allowance cycles + dedup (senior · M, depends gw-1)
4. `gw-4` iOS: userToken mint/persist + appAccountToken at purchase (senior · S)
5. `gw-5` iOS: gateway descriptor + session refresh + router wiring + 402→paywall
   (senior · M, depends gw-1, gw-4)
6. `gw-6` paywall relaunch + allowance copy + `.storekit` validation (senior · S, rides 2kv)
7. `gw-7` activation runbook: ASC product review, allowance/trial/pricing params, privacy
   addendum live, MonetizationFlags flip (lead + user gate)

Verify commands: gateway beads = Worker test suite (`wrangler`-local, vitest) once gw-1
scaffolds it; iOS beads = the standard package tests + app build.
