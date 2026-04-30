# M17.1: Image-Gen Cost Telemetry — Spec

## Product Overview

M17 (shipped 2026-04-29) gave each user a per-account toggle to pick
OpenAI vs. Gemini for recipe image generation. The pitch was that
Gemini is cheaper per image, but we have no data. M17.1 adds a tiny
counter so the dogfooders (and the maintainer) can confirm the
cheaper-per-image claim and decide whether to flip the default
provider. Concretely: every successful image-gen call writes one row
to `image_gen_usage` with provider + user + estimated cost. Settings
shows the user a 30-day rollup ("38 images this month: 22 Gemini /
16 OpenAI — ~$1.49"); the legacy admin bearer can hit
`/api/admin/image-usage` for a global view.

This is a small follow-up — not a full milestone — but it's load-
bearing for the M17 hypothesis ("Gemini saves money") so it's worth
shipping cleanly rather than as inline `print` statements.

## Current State

- `app/services/recipe_image_ai.py:110-125` — `generate_recipe_image` is the single entry point that returns `(bytes, mime, prompt)`. It dispatches per-provider and is called from exactly three places: save (best-effort), backfill, regenerate.
- `app/services/recipe_image_ai.py:83-95` — `_resolve_provider` is the source of truth for the provider name. The telemetry write must happen *after* a successful return, with the same provider value.
- `app/api/recipes.py:184-215` — `save_recipe` swallows `RecipeImageError`. We must log usage only on success (no row on failure / skipped). This already matches the `UsageCounter` "bumped on success only" pattern.
- `app/api/recipes.py:220-275` — `backfill_recipe_images` loops; every successful generation logs one row.
- `app/api/recipe_images.py:82-106` — `regenerate_recipe_image_route`. Same: log on success.
- `app/models/billing.py:36-56` — `UsageCounter` is the existing aggregate-counter pattern. We do **not** reuse it because we want per-call rows (cost answer needs provider + timestamp granularity), not a monthly bucket.
- `app/services/presenters.py:32-64` — `profile_payload` is what Settings reads. We extend it with an `image_usage` block.
- `app/auth.py` + `app/main.py:75` — admin route precedent: subscriptions exposes a public webhook gated by Apple JWS. The legacy `SIMMERSMITH_API_TOKEN` already maps to "dev/local user"; we'll repurpose it as the admin gate via a small `require_admin_bearer` dependency.
- `SimmerSmith/.../Features/Settings/SettingsView.swift:141-176` — Recipe-images section. Add a footer line under the existing Picker.
- `SimmerSmithKit/.../Models/SimmerSmithModels.swift` — `ProfileSnapshot` already carries arbitrary nested decoded values; add an optional `imageUsage` field.
- `SimmerSmithKit/.../API/SimmerSmithAPIClient.swift:399-412` — `fetchProfile` returns the snapshot; no new API call needed.

## Decisions

1. **Granularity**: per-call rows. A monthly aggregate hides the "did
   the user actually flip and re-run?" signal we want for dogfooding.
   At even 100 images/user/week the table stays tiny.
2. **Cost figures**: stored at write time as `est_cost_usd_cents`
   (int cents to avoid float drift). Fixed per-provider constants in
   `app/services/recipe_image_ai.py`:
   - OpenAI `gpt-image-1` 1024×1024 standard quality → **4¢** per image (verify against current pricing before merge — note in PR if it has moved).
   - Gemini `gemini-2.5-flash-image-preview` → **4¢** per image (~1290 output image tokens × ~$30/M tokens ≈ $0.039). If the gap is <0.5¢, the readout will not move, which is itself a useful product datum.
   The implementer may bump constants in a follow-up if Anthropic/Google pricing changes.
3. **Retention**: indefinite for v1 (rows are tiny, ~50 bytes each). Add a one-line note in `decisions.md` that we'll prune to 90 days if the table exceeds 100k rows. No cron yet.
4. **Surfacing**: per-user readout in Settings ("This month: N images, ~$X.XX") + admin-only `GET /api/admin/image-usage` returning global aggregates. No hard usage limit — this is read-only telemetry, not a quota.

## Implementation Plan

### Phase 1 — Data model + write

1. New Alembic migration `20260430_0025_image_gen_usage.py` (renumber to next free slot — verify after the push-notifications spec lands; if both ship together, push-notifications is `_0025_push_devices` and this is `_0026_image_gen_usage`):
   ```
   image_gen_usage
     id              string(36) PK
     user_id         string(36) NOT NULL, INDEX
     recipe_id       string(120) NULL  -- nullable: ON DELETE SET NULL on recipes
     provider        string(16) NOT NULL  -- 'openai' | 'gemini'
     model           string(80) NOT NULL  -- e.g. 'gpt-image-1', 'gemini-2.5-flash-image-preview'
     est_cost_cents  integer NOT NULL    -- per-provider constant at write time
     trigger         string(16) NOT NULL  -- 'save' | 'backfill' | 'regenerate'
     created_at      datetime(tz) NOT NULL, INDEX
     INDEX (user_id, created_at)         -- powers the per-user 30-day rollup
   ```
   `ON DELETE SET NULL` on `recipe_id` so deleting a recipe doesn't lose the cost data.
2. New `app/models/image_usage.py` — `ImageGenUsage` SQLAlchemy model. Add to `app/models/__init__.py`.
3. New `app/services/image_usage.py`:
   - `_PROVIDER_COST_CENTS = {"openai": 4, "gemini": 4}` — module-level dict; comment with the source URL + date.
   - `def record_image_gen(session, *, user_id, recipe_id, provider, model, trigger) -> None` — single insert. `est_cost_cents = _PROVIDER_COST_CENTS.get(provider, 0)`. No commit (caller owns the transaction).
   - `def usage_summary(session, user_id, *, days=30) -> dict` — returns
     ```python
     {"window_days": 30, "total_count": int, "total_cost_cents": int,
      "by_provider": [{"provider": "openai", "count": 16, "cost_cents": 64}, ...]}
     ```
     Single grouped query. Used by `profile_payload`.
   - `def global_usage_summary(session, *, days=30, top_users=10) -> dict` — for the admin endpoint. Returns counts by provider + the top N users by image count.
4. Modify the three call sites to log on success:
   - `app/api/recipes.py:200-214` (save_recipe): after `persist_recipe_image(...)` call `record_image_gen(session, user_id=current_user.id, recipe_id=recipe.id, provider=resolved, model=resolved_model, trigger="save")`. To get `provider` + `model` cleanly, change `generate_recipe_image` to return `(bytes, mime, prompt, provider, model)` instead of `(bytes, mime, prompt)`. Update the two other call sites to unpack the new tuple. Document the breaking signature change in the function docstring.
   - `app/api/recipes.py:255-269` (backfill loop): same — log each successful row.
   - `app/api/recipe_images.py:99-105` (regenerate): same.
5. Update `app/services/recipe_image_ai.py`:
   - `generate_recipe_image` returns `(bytes, mime, prompt, provider, model)`. `provider` is the resolved value; `model` is `settings.ai_image_model` for OpenAI, `settings.ai_gemini_image_model` for Gemini.
   - Internal `_generate_via_openai` / `_generate_via_gemini` similarly return the model string.

### Phase 2 — Read endpoints

6. Extend `profile_payload` in `app/services/presenters.py:32-64`:
   ```python
   from app.services.image_usage import usage_summary
   ...
   return {
       ...,
       "image_usage": usage_summary(session, user_id, days=30),
   }
   ```
   Add the matching field to `ProfileResponse` in `app/schemas/profile.py`:
   ```python
   class ImageUsageProvider(BaseModel):
       provider: str
       count: int
       cost_cents: int

   class ImageUsageSummary(BaseModel):
       window_days: int
       total_count: int
       total_cost_cents: int
       by_provider: list[ImageUsageProvider]

   class ProfileResponse(BaseModel):
       ...
       image_usage: ImageUsageSummary | None = None
   ```
7. New admin route. New `app/api/admin.py`:
   - `def require_admin_bearer(authorization: HTTPAuthorizationCredentials = Depends(bearer_scheme), settings: Settings = Depends(get_settings))` — accepts only when `settings.api_token` is non-empty AND matches via `compare_digest`. Otherwise 403. Reuse `bearer_scheme` from `app/auth.py`.
   - `GET /api/admin/image-usage?days=30` → returns `global_usage_summary(...)`. Wire in `app/main.py` as a top-level router (NOT under `protected_dependencies`, since admin uses its own gate).
8. Do **not** add the admin endpoint to the iOS API client — it is a curl-only diagnostic for the maintainer.

### Phase 3 — iOS Settings readout

9. Extend `SimmerSmithKit/.../Models/SimmerSmithModels.swift`:
   ```swift
   public struct ImageUsageProvider: Codable, Hashable, Sendable {
       public let provider: String
       public let count: Int
       public let costCents: Int
   }
   public struct ImageUsageSummary: Codable, Hashable, Sendable {
       public let windowDays: Int
       public let totalCount: Int
       public let totalCostCents: Int
       public let byProvider: [ImageUsageProvider]
   }
   ```
   Add `public let imageUsage: ImageUsageSummary?` to `ProfileSnapshot` (mirror the `dietaryGoal: DietaryGoal?` pattern). Confirm `SimmerSmithJSONCoding.swift` has `convertFromSnakeCase` set; otherwise add `CodingKeys`.
10. In `SettingsView.swift`, inside the existing `Section("Recipe images")` (line 141), add a single footer row under the Picker (around line 157):
    ```
    if let usage = appState.profile?.imageUsage, usage.totalCount > 0 {
        Text(formatUsage(usage))   // "This month: 38 images · ~$1.49 (22 Gemini · 16 OpenAI)"
            .font(.footnote)
            .foregroundStyle(SMColor.textSecondary)
    }
    ```
    Format: count + dollar amount (cents → dollars/2dp), and per-provider counts ordered by count descending.
11. No new APIClient call — the data rides on the existing `fetchProfile`.

### Phase 4 — Tests + verification

12. `tests/test_image_usage.py`:
    - `record_image_gen` writes a row and increments the per-user summary.
    - `usage_summary(days=30)` only counts rows in window.
    - Save flow: `POST /api/recipes` with a fake provider client → row appears with `trigger="save"`, correct provider/model.
    - Regenerate: same.
    - Failure path: provider raises `RecipeImageError` → no row written.
    - Recipe deletion → row's `recipe_id` becomes `NULL` (if relying on FK) or row remains (verify your migration choice).
    - Admin route: 403 without bearer; 200 with `SIMMERSMITH_API_TOKEN`. Returns aggregated counts.
13. iOS: snapshot decode test for `ImageUsageSummary` from a fixture JSON in `SimmerSmithKitTests`.
14. Manual e2e checklist:
    - Fresh user → no usage row in Settings (Settings shows nothing for an empty list).
    - Save 3 recipes on OpenAI, 2 on Gemini → Settings reads "5 images · ~$0.20 (3 OpenAI · 2 Gemini)".
    - `curl -H "Authorization: Bearer $SIMMERSMITH_API_TOKEN" http://localhost:8080/api/admin/image-usage` → JSON with global counts.

## Interfaces and Data Flow

**New routes**:
- `GET /api/admin/image-usage?days=30` — admin only, legacy bearer.

**Modified responses**:
- `GET /api/profile` now includes `image_usage: { window_days, total_count, total_cost_cents, by_provider: [...] }` (or `null` for users with no rows).

**Modified internal API**:
- `recipe_image_ai.generate_recipe_image` returns `(bytes, mime, prompt, provider, model)` (was 3-tuple). Three call sites updated.

**No env-var or migration deps beyond the new table.** Cost constants live in code (versioned with the codebase) so an update is a normal commit, not an ops task.

## Edge Cases and Failure Modes

- Provider returns success but persistence fails → don't log usage (write inside the same transaction as `persist_recipe_image`; commit-or-rollback together). The save-flow `try/except` already swallows; just put `record_image_gen` *before* the `commit()` in the same try-block, and let the existing exception path skip the log naturally.
- Provider not in `_PROVIDER_COST_CENTS` (e.g. someone adds a third provider) → store `est_cost_cents=0`. Better than crashing.
- Pricing changes → bump the constants and add a new ADR entry. Existing rows keep their old prices (correct historical record).
- User deletes a recipe → `ON DELETE SET NULL` keeps the cost row.
- 30-day rollover → `usage_summary(days=30)` is recomputed each `GET /api/profile`. Cheap (indexed scan over a tiny set).
- Admin route disabled in production by default (no `SIMMERSMITH_API_TOKEN` set on Fly today → 403). Operator opts in by setting it.
- Tests run with no admin token configured → admin route 403. That's expected; tests should explicitly set the token via the existing `Settings` override fixture.

## Test Plan

```bash
.venv/bin/ruff check .
.venv/bin/pytest tests/test_image_usage.py -v
.venv/bin/pytest -v   # full suite stays green
swift test --package-path SimmerSmithKit
xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO
```

Acceptance:
- A successful save / backfill / regenerate writes exactly one `image_gen_usage` row with the correct `provider`, `model`, `trigger`, and a non-zero `est_cost_cents` for known providers.
- A failed AI call writes zero rows.
- `GET /api/profile` shows `image_usage` with the right count/cost; absent or `null` for a brand-new user.
- iOS Settings → Recipe images footer renders the rollup line when `totalCount > 0`; hides cleanly otherwise.
- `GET /api/admin/image-usage` returns 403 without bearer, 200 with bearer matching `SIMMERSMITH_API_TOKEN`.

## Out of Scope

- Hard usage limits / paywalls (M5 territory; deferred).
- Per-day or hourly trend charts.
- A scheduled prune job.
- Surfacing the admin endpoint in iOS.
- Per-user cost cap with email alerts.

## Handoff

- **Tier**: small (Haiku, or Sonnet at low effort). One small migration, one new service module, one new admin route, one new iOS struct, one Settings footer line. Decision-complete; no architectural choices left.
- **Files likely touched**: `alembic/versions/20260430_0026_image_gen_usage.py` (new), `app/models/image_usage.py` (new), `app/models/__init__.py`, `app/services/image_usage.py` (new), `app/services/recipe_image_ai.py` (return-tuple change), `app/api/recipes.py` (two call sites), `app/api/recipe_images.py` (regenerate call site), `app/services/presenters.py`, `app/schemas/profile.py`, `app/api/admin.py` (new), `app/main.py` (register admin router), `tests/test_image_usage.py` (new), `SimmerSmithKit/.../Models/SimmerSmithModels.swift`, `SimmerSmithKit/Tests/SimmerSmithKitTests/SimmerSmithKitTests.swift`, `SimmerSmith/.../Features/Settings/SettingsView.swift`.
- **Constraints**: do not ship before push-notifications spec — both add migrations, so renumber if both are in flight. Cost constants must cite their source (URL + date) in the comment block above the dict. The legacy `SIMMERSMITH_API_TOKEN` is the admin gate; do not introduce a new admin auth scheme.
- **Open user-side**: none. The implementer can verify cost constants against current pricing pages at implementation time and either accept the spec values (4¢ each) or update with a one-line ADR.
