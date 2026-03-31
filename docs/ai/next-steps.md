# Next Steps

Use this as the exact short checklist for the next work session.

- [x] Add the canonical ingredient catalog foundation:
  - base ingredients
  - ingredient variations
  - structured ingredient preferences
  - canonical links on recipe/week/grocery ingredient rows
- [x] Add a first native review UX for unresolved or suggested ingredient matches
- [x] Add the matching web-facing review UX for unresolved or suggested ingredient matches
- [x] Redesign the native Recipes create/import entry points so URL, camera scan, photo import, and PDF import are first-class and discoverable
- [x] Remove or rename the misleading `Import from URL` top-level action if it still contains non-URL import methods
- [x] Build a durable fixture corpus for recipe imports:
  - real recipe URLs
  - OCR text samples
  - PDF samples
  - expected ingredient/step parsing outcomes
- [x] Add regression coverage around import structure quality, ingredient resolution quality, and grocery resolution quality
- [x] Expose structured ingredient preference editing in the app so households can actually choose preferred brands/products
- [x] Add a first recipe-editor ingredient review flow:
  - accept suggested base ingredient
  - choose a different base ingredient
  - choose or clear a variation
  - optionally lock a recipe ingredient to a specific product
- [x] Surface ingredient preference editing from recipe review and grocery review flows instead of Settings only
- [x] Add “create new base ingredient / variation” actions to the ingredient review flow
- [x] Add a bulk review queue for unresolved imported ingredients and grocery items
- [ ] Decide whether exact branded ingredient matches from imports should become `locked` automatically or only `resolved`
- [ ] Extend retailer/pricing matching to use canonical ingredient and variation identity instead of raw ingredient strings alone
- [ ] Decide whether grocery review on the web should stay recipe-first or gain direct canonical ingredient resolution actions
- [ ] Decide whether to filter the discovered OpenAI model list to a smaller supported subset or keep the broader provider-visible list
- [ ] Decide whether to document `scripts/codex_mcp_http_bridge.py` as a supported operator workflow or keep it as a local dev helper only
- [ ] Decide whether the Streamable HTTP bearer-token mode is sufficient for local/operator use or if stronger auth is needed before broader exposure
- [ ] Reduce or suppress the noisy upstream `codex/event` validation logs emitted by the local MCP bridge session
- [ ] Manually verify the read-only Assistant empty state and disabled composer when neither MCP nor direct providers are available
- [ ] Expand `docs/ai/mcp-tools.md` with a few end-to-end recipe/week/operator examples after the first real external-client session
