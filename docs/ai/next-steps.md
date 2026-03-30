# Next Steps

Use this as the exact short checklist for the next work session.

- [ ] Start the `Recipe import UX and hardening` phase from the roadmap
- [ ] Redesign the Recipes create/import entry points so URL, camera scan, photo import, and PDF import are all first-class and discoverable
- [ ] Remove or rename the misleading `Import from URL` top-level action if it still contains non-URL import methods
- [ ] Build a durable fixture corpus for recipe imports:
  - real recipe URLs
  - OCR text samples
  - PDF samples
  - expected ingredient/step parsing outcomes
- [ ] Add regression coverage around import structure quality, not just endpoint success
- [ ] Compare URL import and scan/text import output quality on the same recipes and note the biggest mismatches
- [ ] Verify the camera/photo/PDF import affordances make sense in the iOS flow before tuning parser quality
- [ ] Decide whether to filter the discovered OpenAI model list to a smaller supported subset or keep the broader provider-visible list
- [ ] Decide whether to document `scripts/codex_mcp_http_bridge.py` as a supported operator workflow or keep it as a local dev helper only
- [ ] Decide whether the Streamable HTTP bearer-token mode is sufficient for local/operator use or if stronger auth is needed before broader exposure
- [ ] Reduce or suppress the noisy upstream `codex/event` validation logs emitted by the local MCP bridge session
- [ ] Manually verify the read-only Assistant empty state and disabled composer when neither MCP nor direct providers are available
- [ ] Expand `docs/ai/mcp-tools.md` with a few end-to-end recipe/week/operator examples after the first real external-client session
- [ ] Update `docs/ai/current-state.md` and `docs/ai/decisions.md` with the result
