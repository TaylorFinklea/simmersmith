# SP-C — AI track, slice AI-2: Recipe AI (import + generation + web search)

> 2026-06-22. Second AI slice. Reuses AI-1 infra (AIService/BYOKeyProvider + prompt-port + the
> draft-apply already through RecipeRepository). Brings the 8 recipe-AI methods off Fly.

## 0. Goal + scope
Port the recipe-AI methods (all currently Fly `// AI TRACK`) to run on-device. All return DRAFTS the
user approves; the approve→save path ALREADY writes through `RecipeRepository` (map confirmed) — so
this slice rewires only the GENERATION, not the save.

Methods (AppState+Recipes.swift): `importRecipeDraft(fromURL:/fromText:/fromHTML:)`,
`generateRecipeVariationDraft(recipeID:goal:)`, `generateRecipeSuggestionDraft(goal:)`,
`generateRecipeCompanionDrafts(recipeID:)`, `refineRecipeDraft(currentDraft:prompt:contextHint:)`,
`searchRecipeOnWeb(query:)`.

## 1. Design decisions (Lead, from the map)
- **Import URL/HTML = deterministic JSON-LD + LLM fallback.** The server parses schema.org JSON-LD +
  HTML deterministically (`app/services/recipe_import/parser.py`). On-device: fetch the URL (URLSession,
  https-only + reject localhost/private-IP hosts — the device isn't a server but still don't probe the
  local network), extract `<script type="application/ld+json">` Recipe nodes → map to RecipeDraft
  (exact, no API key needed). If no JSON-LD → fall back to the LLM extraction (§Import-LLM).
- **Import text/OCR = LLM extraction.** Unstructured text → the BYO-key LLM extracts a structured recipe
  (cleaner than porting the regex heuristics).
- **Variation/Suggestion/Companion/Refine = LLM.** The server's variation is a preset rule-engine; on
  BYO-key an LLM produces better variations. Port/author the prompts; route via AIService.
- **Web search = provider web-search tool.** Extend BYOKeyProvider to issue the provider's built-in web
  search (OpenAI Responses API `web_search`; Anthropic `web_search_20250305`, max_uses ~5) per
  `app/services/recipe_search_ai.py`, then extract the chosen recipe → RecipeDraft.
- **No API key set:** the LLM-backed features surface the "add your key in Settings" prompt (like AI-1);
  JSON-LD import works WITHOUT a key (deterministic) — a nice win.
- **Allergy note:** these are recipe drafts the USER reviews before save (not auto-applied like week-gen),
  so no hard allergy-gate needed; but surface allergen ingredients if trivially known. (Keep it simple.)

## 2. Components to build
| Component | New? | Responsibility |
|---|---|---|
| `RecipeURLFetcher` | new (SimmerSmithKit) | fetch a URL on-device (URLSession): https-only, reject localhost/private/link-local hosts, cap body size, follow redirects with re-validation. Returns HTML. |
| `JSONLDRecipeExtractor` | new (SimmerSmithKit) | parse schema.org JSON-LD `Recipe` from HTML → a RecipeDraft-shaped value (name/ingredients/steps/times/servings/cuisine/yield). Handles `@graph`, arrays, `recipeIngredient`/`recipeInstructions` (string or HowToStep). Returns nil if no Recipe node. Headless-testable (fixture HTML). |
| recipe-AI prompts | new (AIProviderKit or app) | Swift prompt-builders + JSON schemas for: LLM recipe extraction (from text/HTML), variation (recipe+goal), suggestion (goal), companion (recipe→sides), refine (draft+instruction). Port intent from `app/services/recipe_ai.py` + `recipe_search_ai.py`. Structured output → RecipeDraft. Headless-test the builders + parsers. |
| BYOKeyProvider web-search | modify (AIProviderKit) | add a web-search request mode: OpenAI Responses API with `web_search` tool / Anthropic messages with the `web_search` tool. Inject transport (already done); test the request bodies. |
| `AppState+Recipes` rewire | modify | each of the 8 methods: build the draft via the deterministic path (import) or `AIService.generate` (LLM) instead of `apiClient`; keep the RecipeDraft/RecipeAIDraft/RecipeAIOptions return shapes intact (the UI + save path are unchanged). Un-gate the `isCloudKitOnly`-guarded ones (variation, companion) — they now work on AIService (need a key). |

## 3. Reuse / do-not-rebuild
- **AIService.generate(AIRequest)** (AI-1 seam) — all LLM features route through it.
- **BYOKeyProvider** (AI-1) — extend with web-search; the injected HTTPTransport + structured-output are there.
- **RecipeRepository.save(draft)** + RecipeDraftReviewSheet — the approve→save path is DONE (writes to CloudKit). Don't touch.
- RecipeDraft / RecipeAIDraft / RecipeAIOptions domain shapes — keep; the UI binds to them.

## 4. Verification
- **Headless:** JSONLDRecipeExtractor against fixture HTML (a JSON-LD recipe → correct draft; no-JSON-LD →
  nil); the URL-fetcher host guard (rejects localhost/10.x/192.168/169.254, accepts https public); each
  prompt-builder produces the expected structure + the parser round-trips a sample response; the
  BYOKeyProvider web-search request bodies (OpenAI + Anthropic).
- **On-device (TestFlight):** paste a recipe URL → JSON-LD import → draft → save (recipe appears, no key
  needed); a URL without JSON-LD → LLM fallback (with a key); generate a variation/suggestion/companion;
  refine a draft; web search returns a recipe. All save through CloudKit.

## 5. Risks
- **URL fetch safety** — https-only + private-host rejection + body cap; don't let it probe the local net.
- **JSON-LD variety** — recipe sites vary (@graph, nested, string vs HowToStep instructions); test a few shapes; LLM fallback covers misses.
- **Web-search provider mechanics** — OpenAI Responses vs Anthropic tool differ; test both bodies; degrade gracefully if a provider/key lacks the tool.
- **Prompt fidelity** — variation/suggestion match the server's intent (not its rule-engine) — author clear prompts; reviews check quality.
- **No new CloudKit types / no schema deploy** (recipes write existing records).
