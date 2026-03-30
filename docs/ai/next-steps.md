# Next Steps

Use this as the exact short checklist for the next work session.

- [ ] Rebuild and reinstall the iOS app, then manually verify the Assistant works against the local MCP bridge with no saved API keys
- [ ] Manually verify the new iOS AI settings flow: save a direct-provider key, confirm the app never reads it back, then clear it and confirm the server secret flag resets
- [ ] Exercise the new `simmersmith` MCP server from Codex or another MCP client against real recipe/week flows and note any tool-shape friction
- [ ] Manually exercise the new Streamable HTTP mode for the `simmersmith` MCP server from a second client, not just Codex
- [ ] Expand `docs/ai/mcp-tools.md` with a few end-to-end recipe/week/operator examples after the first real external-client session
- [ ] Decide whether to document `scripts/codex_mcp_http_bridge.py` as an operator workflow or keep it as a local dev helper only
- [ ] Decide whether the Streamable HTTP bearer-token mode is sufficient for local/operator use or if stronger auth is needed before broader exposure
- [ ] Reduce or suppress the noisy upstream `codex/event` validation logs emitted by the local MCP bridge session
- [ ] Manually verify the read-only Assistant empty state and disabled composer when neither MCP nor direct providers are available
- [ ] Decide whether to migrate the older heuristic recipe AI endpoints onto the same direct/MCP execution seam or leave them heuristic through the import-hardening milestone
- [ ] Return to the roadmap sequence with the import quality lab after direct/MCP Assistant validation
- [ ] Update `docs/ai/current-state.md` and `docs/ai/decisions.md` with the result
