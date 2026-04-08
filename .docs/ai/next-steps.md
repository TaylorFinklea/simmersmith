# Next Steps

> Short checklist of exact next actions. Updated at end of every session.

## Immediate

- [ ] Full code quality audit — start with backend services (`app/services/*.py`), then models (`app/models.py`), then iOS (`SimmerSmith/`), then SimmerSmithKit
- [ ] Split `app/services/recipe_import.py` (1,040 lines) — extract parser and ingredient normalizer
- [ ] Clean up pre-existing repo-wide Ruff failures in `app/api/assistant.py`, `app/mcp_server.py`, `app/services/nutrition.py`, and `scripts/rewrite_product_like_catalog.py`
- [ ] Unblock TestFlight upload — repair ASC credentials or switch to API key flow

## Soon

- [ ] Split `app/mcp_server.py` (835 lines) — extract per-domain route modules
- [ ] Split `app/models.py` (723 lines) — extract domain-specific model files
- [ ] Set up Supabase project (Postgres instance, auth configuration)
- [ ] Database abstraction — test SQLAlchemy on Postgres, create dialect-aware migration path
- [ ] Multi-user data isolation — add `user_id` to all tables, auth middleware
- [ ] Supabase Auth integration — JWT validation in FastAPI, iOS auth flow

## Deferred

- [ ] Guided onboarding AI preference interview — after M0 foundation is solid
- [ ] AI-driven week planning wizard — after auth and multi-user are working
- [ ] Grocery pricing hybrid model — M2 scope
