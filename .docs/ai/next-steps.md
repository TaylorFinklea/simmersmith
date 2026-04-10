# Next Steps

> Short checklist of exact next actions. Updated at end of every session.

## Immediate

- [ ] Deploy to Fly.io — `fly apps create`, provision Neon Postgres (or Fly Postgres), set secrets (`DATABASE_URL`, `JWT_SECRET`, `API_TOKEN`), `fly deploy`, verify health endpoint
- [ ] Service-layer user_id scoping — replace `get_settings().local_user_id` shims with proper `user_id` from `get_current_user` caller. Every query on user-owned tables needs `WHERE user_id = :uid`. This is the biggest remaining infrastructure task.
- [ ] Cross-user isolation tests — adversarial tests proving user A can't see user B's data

## Soon

- [ ] iOS: Wire Sign in with Apple to `POST /api/auth/apple`, store session JWT in Keychain
- [ ] iOS: Wire Sign in with Google to `POST /api/auth/google`
- [ ] MCP per-user token system — mint per-user MCP bearer tokens
- [ ] Unblock TestFlight upload — ASC credentials or API key flow

## Deferred

- [ ] Guided onboarding AI preference interview — M1
- [ ] AI-driven week planning wizard — M1
- [ ] Grocery pricing hybrid model — M2
