# SimmerSmith Roadmap

This file is the durable roadmap source of truth for AI assistants working in this repo.

## Durable Goals

- Keep SimmerSmith Apple-first: iOS is the primary client.
- Keep FastAPI as the canonical state and business-logic layer.
- Use the web app as a secondary admin/proving surface, not the primary product.
- Keep AI features draft-first and MCP-first, while preserving the direct-provider seam.

## Current Milestones

1. Finish the Recipes platform until it is trustworthy enough for real planning.
2. Build the guided future-week planning wizard.
3. Expand grocery, pricing, ingredient-assistant, and equipment workflows.
4. Harden iOS release/compliance and web/admin infrastructure in parallel.
5. Only after the above, consider a macOS operator client.

## Near-Term Sequence

1. AI recipe suggestions
2. Recipe companion suggestions
3. Import quality lab
4. Scan/photo/PDF import hardening
5. Native recipe PDF export
6. Template customization
7. Live step/substep reorder
8. Recipe experience polish
9. Guided future-week planning wizard
10. Week staging/change-history hardening

## Platform Tech Debt To Sprinkle In

- SwiftUI architecture pass
- Swift Concurrency cleanup
- Swift Testing expansion
- iOS UI automation expansion
- iOS release pipeline hardening
- iOS metadata/compliance synchronization
- Web admin design-system consolidation
- Browser E2E coverage
- Cloudflare hosting/deployment/observability
- Public support/privacy maintenance

## Constraints

- Do not move core business logic into the iOS client.
- Do not silently persist AI-generated recipes or week changes.
- Do not let the web app roadmap displace the iOS-first product direction.
- Keep shared docs updated at session end.

## Non-Goals

- Rewriting the app into a web-first product
- Replacing the FastAPI server with client-owned state
- Shipping the macOS client before recipe/planning/server contracts are stable
