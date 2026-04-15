# Phase Spec: AI Planning Quality

## Goal

Make the AI week planner preference-aware, history-aware, and feedback-driven so that generated meal plans feel personalized and improve over time.

## Scope

**Backend only** (app/services/week_planner.py + app/api/weeks.py). No iOS changes, no model/migration changes, no AI provider routing changes.

## Approach

The planner already has rich preference/feedback/history data available via existing service functions. The work is:

1. **Gather context** — New `gather_planning_context()` fetches preference signals, staples, and recent meal history from the DB using existing functions (`preference_summary_payload`, `list_preference_signals`, `staple_names`, `list_weeks`).

2. **Enrich the prompt** — Enhance `_build_system_prompt()` with new sections: preference signals (hard avoids, strong likes, cuisine preferences), pantry staples, and recent meal history. Add stronger rules (never use avoided ingredients, limit recipe reuse, leverage staples).

3. **Validate output** — New `validate_plan_guardrails()` checks the AI response for over-duplication (>3 reuses) and avoided-ingredient violations. Warnings go into `week_notes`.

4. **Score output** — New `score_generated_plan()` calls the existing `score_meal_candidate()` on each generated recipe. Scores logged for quality tracking.

5. **Wire into endpoint** — The API endpoint calls gather + planner + validate + score in sequence.

## Acceptance Criteria

- [ ] User with preference signals gets a prompt that includes their avoids/likes/cuisines
- [ ] User with staples gets a prompt mentioning pantry items
- [ ] User with past weeks gets a prompt listing recent meals to avoid
- [ ] New user with no data gets an identical prompt to today's behavior
- [ ] Plans with >3 reuses of a recipe produce a warning in week_notes
- [ ] Plans containing avoided ingredients produce a warning in week_notes
- [ ] Each generated recipe gets a preference score logged
- [ ] All 65 existing tests pass
- [ ] New unit tests cover all new functions
- [ ] ruff check passes clean

## Assumptions

- Profile settings, preference signals, staples, and week history are already populated by existing flows (onboarding, feedback, manual entry).
- The AI model (gpt-5.4-mini) can handle ~1000 tokens of prompt context without degradation.
- Post-generation scoring is informational for now (log/store, don't reject plans).

## Out of Scope

- iOS UI changes for displaying scores or warnings
- Changing AI provider routing or model selection
- Regeneration/retry logic based on scores
- Modifying the draft application flow (drafts.py)
- Alembic migrations or model schema changes
