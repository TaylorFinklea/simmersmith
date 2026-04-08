# Next Steps

> Short checklist of exact next actions. Updated at end of every session.

## Immediate

- [x] Full code quality audit — backend services and API routes (30 issues found, critical fixes applied)
- [x] Split `app/mcp_server.py` — extracted into `app/mcp/` package
- [x] Clean up repo-wide ruff failures — all checks passing
- [ ] Code quality audit — iOS views and SimmerSmithKit
- [ ] Fix grocery full-table scans — filter queries by week's meals, not global (`app/services/grocery.py:123-129`)
- [ ] Unblock TestFlight upload — repair ASC credentials or switch to API key flow

## Soon

- [ ] Split `app/models.py` (723 lines) — extract domain-specific model files
- [ ] Split `app/schemas.py` (711 lines) — extract domain-specific schema files
- [ ] Set up Supabase project (Postgres instance, auth configuration)
- [ ] Database abstraction — test SQLAlchemy on Postgres, create dialect-aware migration path
- [ ] Multi-user data isolation — add `user_id` to ALL tables, auth middleware

## Deferred

- [ ] Guided onboarding AI preference interview — after M0 foundation is solid
- [ ] AI-driven week planning wizard — after auth and multi-user are working
- [ ] Grocery pricing hybrid model — M2 scope
