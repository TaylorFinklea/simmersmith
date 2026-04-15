# Phase Spec: Store-Specific Grocery Pricing (Kroger API)

## Goal

Integrate real store-specific grocery pricing so users can see what their weekly meal plan costs at their local Kroger store.

## Scope

**Backend only.** Add Kroger API client, live pricing fetch endpoint, store location search, and config settings. Relax hardcoded retailer enum to support dynamic retailers.

## Approach

### Data source: Kroger API

- Free public API at developer.kroger.com
- OAuth2 authentication (client_id + client_secret)
- `GET /locations` — search stores by zip code
- `GET /products` — search by ingredient name + store location ID, returns real prices
- Covers ~2,750 stores across 35 states (Kroger, Harris Teeter, Fred Meyer, Ralphs, etc.)

### Architecture

1. **Kroger client** (`app/services/kroger.py`) — OAuth2 token management, location search, product price search
2. **Store selection** — User sets preferred store via profile settings (zip search → pick store → save location_id)
3. **Live pricing endpoint** — `POST /api/weeks/{week_id}/pricing/fetch` iterates grocery items, queries Kroger API, stores RetailerPrice rows
4. **Schema update** — Relax `PricingImportItem.retailer` from Literal to `str` to support "kroger" alongside existing retailers
5. **Config** — Add `SIMMERSMITH_KROGER_CLIENT_ID` and `SIMMERSMITH_KROGER_CLIENT_SECRET` to Settings

### Flow

```
User approves week
  → POST /api/weeks/{week_id}/pricing/fetch
    → Read user's preferred store (profile setting: kroger_location_id)
    → For each GroceryItem:
      → GET /products?filter.term={ingredient_name}&filter.locationId={store_id}
      → Pick best match (by candidate_score)
      → Create/update RetailerPrice row
    → Set week status = "priced"
    → Return PricingResponse with totals
```

### Store search flow

```
GET /api/stores/search?zip=78701&radius=10
  → Kroger GET /locations?filter.zipCode.near=78701&filter.radiusInMiles=10
  → Return list of {location_id, name, address, chain}

PUT /api/profile — settings: {kroger_location_id: "01234567"}
```

## Acceptance Criteria

- [ ] Kroger OAuth2 token acquisition works (client credentials flow)
- [ ] Store search by zip code returns nearby Kroger-family stores
- [ ] User can save preferred store in profile settings
- [ ] Pricing fetch queries Kroger API for each grocery item and stores results
- [ ] PricingResponse includes kroger totals and per-item prices
- [ ] Existing import flow still works for aldi/walmart/sams_club
- [ ] Graceful handling when Kroger API is unavailable or rate-limited
- [ ] All existing tests pass + new tests with mocked Kroger responses

## Assumptions

- User will register at developer.kroger.com and provide client_id/secret
- Kroger API rate limits are sufficient for one week's grocery list (~20-40 items)
- Product search by ingredient name returns usable matches (may need query normalization)

## Out of Scope

- iOS UI for store selection or price display (backend-only this phase)
- Instacart "shop now" integration (future)
- Spoonacular estimated pricing fallback (future)
- Price comparison across multiple retailers
- Caching/background refresh of prices
