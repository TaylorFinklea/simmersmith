# SimmerSmith Roadmap

This file is the durable roadmap source of truth for AI assistants working in this repo.

## Durable Goals

- Keep SimmerSmith Apple-first: iOS is the primary client.
- Keep FastAPI as the canonical state and business-logic layer.
- Treat the backend API and native iOS app as the product surface; the web frontend is slated for decommissioning and should not drive roadmap priorities.
- Keep AI features draft-first and MCP-first, while preserving the direct-provider seam.
- Expose a standard SimmerSmith MCP surface so external AI clients can operate the same app domains the native app and in-app assistant use.

## Current Milestones

1. Finish the Recipes platform until it is trustworthy enough for real planning.
2. Build the guided future-week planning wizard.
3. Expand grocery, pricing, ingredient-assistant, and equipment workflows.
4. Harden iOS release/compliance, MCP/operator contracts, and decommission-web maintenance.
5. Only after the above, consider a macOS operator client.

## Foundations Already Landed

- Canonical ingredient catalog and recipe-ingredient resolution foundation
- Native ingredient review, ingredient management, and household preference flows
- Native Assistant tab plus server-backed threads
- Standard SimmerSmith MCP surface and local/operator transport support

## Near-Term Sequence

1. Finish recipe trustworthiness
   - import quality lab and fixture-driven parser hardening
   - branded-vs-generic ingredient/product modeling decisions
   - review-flow hardening and remaining recipe trust gaps
   - native recipe PDF export
   - template customization
   - live step/substep reorder
   - recipe experience polish
2. Build the guided future-week planning wizard
3. Expand grocery, pricing, ingredient-assistant, and equipment workflows
4. Harden iOS release/compliance, MCP/operator contracts, and decommission-web maintenance
5. Only after the above, consider a macOS operator client

## Parallel Backlog For Smaller Assistants

<!-- tier3_owner: claude -->

Smaller assistants may take explicit backlog work in parallel with the formal phases when the task is narrow, localized, and low-risk.

- Allowed: localized product-code changes, test expansion, docs, CI/build hygiene, release maintenance, and operator tooling maintenance.
- Required tags: area plus delegation safety.
- Default escalation rule: if the task reveals a deeper architectural or product-policy issue, promote it into a formal phase or decision and stop the smaller-assistant work.

### Tags

- Area tags: `ios`, `backend`, `infra`, `mcp`, `docs`, `tests`, `release`
- Safety tags: `small-model-safe`, `promote-if-deeper`

### High-Leverage Parallel Work

- `small-model-safe ios tests` expand Swift Testing coverage for ingredient review, ingredient management, and cache-clear recovery flows
- `small-model-safe backend tests` add API edge-case coverage for ingredient browse/search filters, product-like toggles, and ingredient-management endpoints
- `small-model-safe ios promote-if-deeper` perform localized SwiftUI cleanup and view decomposition where behavior is unchanged
- `small-model-safe mcp docs` expand MCP tool-contract docs with end-to-end examples for recipes, weeks, exports, and assistant threads
- `small-model-safe ios tests` add UI automation for cache-clear recovery and ingredient browse/search smoke paths

### Maintenance / Hygiene

- `small-model-safe ios promote-if-deeper` perform narrow Swift Concurrency cleanups that do not alter product behavior or data flow
- `small-model-safe release infra` tighten release-hygiene docs and App Store Connect upload-path documentation without changing release policy
- `small-model-safe docs` keep AI handoff docs, MCP docs, and operator docs synchronized as workflow details become clearer
- `small-model-safe backend tests` add regression fixtures for import/parser failures that are already understood without changing parsing policy
- `small-model-safe infra` improve CI/build hygiene where changes are mechanical and low-risk

### Verification / Coverage

- `small-model-safe ios tests` broaden native/client model and API client coverage in `SimmerSmithKit`
- `small-model-safe backend tests` add focused tests around canonical ingredient resolution fallbacks that already match current behavior
- `small-model-safe mcp tests` validate documented MCP examples against the current tool surface
- `small-model-safe release docs` keep compliance, support, and public-maintenance tasks moving when they are procedural

### Not For Smaller Assistants

- import behavior policy changes
- branded-vs-generic ingredient/product modeling decisions
- API or MCP contract changes
- AI workflow policy changes
- state-model or migration design
- roadmap or phase reprioritization

## Constraints

- Do not move core business logic into the iOS client.
- Do not silently persist AI-generated recipes or week changes.
- Keep the Assistant as a first-class product surface, not a buried action sheet.
- Support conversational AI through direct provider APIs or a real remote MCP execution path; do not rely on local `codex exec` fallback.
- Treat recipe import as a first-class workflow in the Recipes product surface, not as a sub-option hidden under URL import.
- Keep recipe ingredient text for fidelity, but attach canonical ingredient identity so groceries, nutrition, and preferences do not rely on raw strings alone.
- Do not spend new roadmap effort on the web frontend beyond maintenance needed to keep the repo stable during decommissioning.
- Keep shared docs updated at session end.

## Non-Goals

- Rewriting the app into a web-first product
- Replacing the FastAPI server with client-owned state
- Shipping the macOS client before recipe/planning/server contracts are stable
