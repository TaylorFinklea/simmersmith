# AGENTS.md

Agent workflow preferences for this repository (applies to Codex, Claude Code, Gemini CLI, and other AI coding assistants).

## Session Workflow

### Starting a session

Read these files before doing any work:
1. `.docs/ai/roadmap.md` -- durable goals, milestones, constraints, non-goals
2. `.docs/ai/current-state.md` -- last session summary, changed files, blockers, validation status
3. `.docs/ai/next-steps.md` -- exact next actions as a checklist

These docs are the source of truth for project state, not chat history.

Then inspect the repo state:
- `git status --short`
- `git log --oneline -5`
- the relevant code paths for the next task

### Ending a session

Before finishing, update:
1. `.docs/ai/current-state.md` -- what you did, files changed, blockers, validation status
2. `.docs/ai/next-steps.md` -- check off completed items and add the exact next actions
3. `.docs/ai/decisions.md` -- append an ADR entry if a non-obvious decision or workflow change was made

See `.docs/ai/handoff-template.md` for the format.

## Repository Guidance

- SimmerSmith is an AI-first public product targeting the App Store. AI is the primary interaction model.
- iOS is the main client. FastAPI + Supabase is the canonical backend. Self-hosting (SQLite) is first-class.
- The web frontend is being removed. Do not add web frontend code.
- Use small, reviewable commits by default.
- Do not push unless the user explicitly asks.
- Validate the changed slice before committing and record the result in `.docs/ai/current-state.md`.
- Do not let assistant-specific workflow drift from the shared `.docs/ai` state.
