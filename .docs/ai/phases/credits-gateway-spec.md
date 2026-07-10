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
2. **Trial user (keyless, no purchase)**: session acquisition sends an **App Attest**
   assertion (`DCAppAttestService`); the Worker verifies with Apple and keys the one-time
   trial grant on the attest key id. Bounded fraud accepted: reinstall/device-reset can mint a
   new attest key — the trial size prices that in. Belt-and-braces: the app also records a
   `trialClaimed` marker in the CloudKit private plane and self-reports it; the Worker treats
   a self-reported claim as authoritative-deny (cheap honesty check, blocks casual re-claims).
3. **Session**: `POST /v1/session` with either a transaction JWS (subscriber) or an App Attest
   assertion (trial). Worker verifies — **JWS x5c chain to Apple Root CA, not just the leaf**
   (the F22 lesson) — and returns a short-lived signed session token (JWT, ~24h, subject =
   userToken or attest key id). The app stores it in the Keychain under the existing
   provider-key plumbing (keychain id `gateway`).

Precedence in `ProviderRouter` is unchanged: BYO-key beats creditsGateway; the gateway serves
only when no key is configured and `creditsAvailable` (valid session + balance > 0).

## 4. Worker endpoints (contract — spec-exact)

| Route | Auth | Behavior |
|---|---|---|
| `POST /v1/session` | JWS or App Attest assertion | verify → upsert subject in D1 → return session JWT + balance snapshot |
| `GET /v1/balance` | session JWT | current credits, cycle reset date, trial state |
| `POST /v1/chat/completions` | session JWT | balance check → forward to upstream (streaming SSE pass-through) → debit actual usage post-stream (usage field; estimate+reconcile for aborted streams) → 402 JSON error when balance exhausted |
| `POST /assn` | Apple (signedPayload JWS) | verify chain → dedup by `notificationUUID` → update entitlement rows; RENEWAL/DID_RENEW resets the monthly allowance; REVOKE/EXPIRED zeroes it |

Errors are OpenAI-shape JSON (`{"error":{"message","type","code"}}`) so the existing
`AIError.errorDescription` path (401/429/402 handling) renders them without new client code.
`402 insufficient_credits` is the paywall trigger signal.

## 5. Ledger (D1 — spec-exact schema, columns may gain, never lose)

```sql
users(subject TEXT PRIMARY KEY, kind TEXT CHECK(kind IN ('subscriber','trial')),
      created_at INTEGER, trial_claimed_at INTEGER)
entitlements(subject TEXT PRIMARY KEY REFERENCES users, product_id TEXT,
      status TEXT, expires_at INTEGER, cycle_started_at INTEGER,
      last_transaction_id TEXT, updated_at INTEGER)
balances(subject TEXT PRIMARY KEY REFERENCES users, credits INTEGER NOT NULL,
      cycle_grant INTEGER NOT NULL, updated_at INTEGER)
usage_events(id INTEGER PRIMARY KEY AUTOINCREMENT, subject TEXT, feature TEXT,
      model TEXT, prompt_tokens INTEGER, completion_tokens INTEGER,
      credits_debited INTEGER, created_at INTEGER)
assn_dedup(notification_uuid TEXT PRIMARY KEY, received_at INTEGER)
```

**Credit unit**: 1 credit ≈ 1k normalized upstream tokens (weighted: completion ×3 prompt),
rounded up per call. Allowance/trial sizes and any per-feature weighting are **activation-time
parameters** (env-config, not code): launch defaults `MONTHLY_ALLOWANCE`, `TRIAL_GRANT`,
picked by the user when 98v flips. Rate limiting per subject (token bucket in a Durable
Object or KV) is mandatory — a stolen session token must not drain the upstream budget.

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
