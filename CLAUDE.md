# CLAUDE.md

This file provides guidance to Claude Code and similar assistants when working with code in this repository.

## Session Workflow

### Starting a session

1. Read these files to understand the current project state:
   - `docs/ai/roadmap.md` -- durable goals, milestones, constraints, non-goals
   - `docs/ai/current-state.md` -- what happened last, blockers, changed files, validation status
   - `docs/ai/next-steps.md` -- exact next actions
2. Check `git log --oneline -5` and `git status --short` to verify repo state matches the shared docs.
3. Only trust the codebase plus the shared `docs/ai` files; do not use chat memory as project state.

## Ending a session

Before signing off, update these shared docs:
1. `docs/ai/current-state.md` -- session summary, changed files, blockers, validation status
2. `docs/ai/next-steps.md` -- remove completed items and add the exact next actions
3. `docs/ai/decisions.md` -- append an ADR entry if any non-obvious architectural or workflow decision was made

See `docs/ai/handoff-template.md` for the session-end format.

## Repository Guidance

- Keep the workflow aligned with `AGENTS.md`; assistant-specific behavior should not fork the shared repo state.
- Preserve roadmap continuity: do not reorder the roadmap casually. Update the shared docs first if the plan changes.
- Keep SimmerSmith Apple-first: iOS is the primary product, FastAPI is canonical, and the web app is a secondary admin surface.
- Prefer concise implementation notes and explicit validation results.
- Do not push unless the user explicitly asks.
