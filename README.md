# SimmerSmith

Apple-first meal planning app with a FastAPI service layer, SQLite persistence, and a companion React workspace.

SimmerSmith is licensed under the GNU Affero General Public License v3.0. See `LICENSE`.

## What it does

- iOS 26+ SwiftUI app built with native tabs, lists, forms, sheets, and Liquid Glass styling
- React + TypeScript SPA built with Vite, Tailwind CSS, and shadcn-style UI primitives
- FastAPI JSON API for profile, recipes, weeks, grocery, and pricing state
- SQLite as the system of record
- agent-imported pricing results for Aldi, Walmart, and Sam's Club
- the web app now acts primarily as the server-facing admin surface while iOS becomes the first native client

The system of record is the SQLite file at `/Users/tfinklea/codex/meals/data/meals.db` by default.

## Quick start

### Backend

```bash
python3 -m venv .venv
.venv/bin/pip install -e '.[dev]'
```

### Frontend

```bash
cd frontend
npm install
```

### iOS

Generate the Xcode project:

```bash
xcodegen generate --spec SimmerSmith/project.yml
open SimmerSmith/SimmerSmith.xcodeproj
```

You can also build and test from the terminal:

```bash
swift test --package-path SimmerSmithKit
xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' build CODE_SIGNING_ALLOWED=NO
xcodebuild -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.0.1' test CODE_SIGNING_ALLOWED=NO
```

### Local development

Run the API:

```bash
.venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port 8080 --reload
```

Run the React app:

```bash
cd frontend
npm run dev
```

Open:

- frontend dev server: [http://localhost:5173](http://localhost:5173)
- backend API: [http://localhost:8080/api/health](http://localhost:8080/api/health)

The Vite dev server proxies `/api/*` to FastAPI automatically.

### Optional bearer-token auth

Set `SIMMERSMITH_API_TOKEN` to require `Authorization: Bearer <token>` on all API routes except `GET /api/health`.

This is intended for the native iOS client and private self-hosted deployments. If the variable is unset, the API remains open for local development.

### Production-style local run

```bash
docker compose up --build
```

Open [http://localhost:8080](http://localhost:8080).

The container serves the built SPA and API from one service, while persistent data stays under the bind mount in [`docker-compose.yml`](/Users/tfinklea/git/simmersmith/docker-compose.yml), which points at `/Users/tfinklea/codex/meals/data` on the host.

## Project home

- Product domain: `https://simmersmith.app`
- Public repository: `https://github.com/TaylorFinklea/simmersmith`

## Support And Privacy

- GitHub Pages base URL: `https://taylorfinklea.github.io/simmersmith/`
- Support URL: `https://taylorfinklea.github.io/simmersmith/support/`
- Privacy Policy URL: `https://taylorfinklea.github.io/simmersmith/privacy/`

## Operator flow

The operator CLI remains the main control surface when Codex needs to talk to the app from the terminal:

```bash
python3 scripts/simmersmith_cli.py start --build --pretty
python3 scripts/simmersmith_cli.py check --pretty
python3 scripts/simmersmith_cli.py profile --pretty
python3 scripts/simmersmith_cli.py preferences --pretty
python3 scripts/simmersmith_cli.py current-week --pretty
```

Core write paths:

```bash
python3 scripts/simmersmith_cli.py create-week --week-start 2026-03-16 --notes "Spring break" --pretty
python3 scripts/simmersmith_cli.py apply-draft --week-id <week-id> --payload /tmp/draft.json --pretty
python3 scripts/simmersmith_cli.py ready-week --week-id <week-id> --pretty
python3 scripts/simmersmith_cli.py approve-week --week-id <week-id> --pretty
python3 scripts/simmersmith_cli.py import-pricing --week-id <week-id> --payload /tmp/pricing.json --pretty
```

Preference memory and deterministic baseline scoring:

```bash
python3 scripts/simmersmith_cli.py save-preferences --payload /tmp/preferences.json --pretty
python3 scripts/simmersmith_cli.py score-meal --payload /tmp/candidate.json --pretty
```

Staging history, structured feedback, and host-side handoff:

```bash
python3 scripts/simmersmith_cli.py week-changes --week-id <week-id> --pretty
python3 scripts/simmersmith_cli.py week-feedback --week-id <week-id> --pretty
python3 scripts/simmersmith_cli.py save-week-feedback --week-id <week-id> --payload /tmp/feedback.json --pretty
python3 scripts/simmersmith_cli.py week-exports --week-id <week-id> --pretty
python3 scripts/simmersmith_cli.py create-export --week-id <week-id> --export-type meal_plan --pretty
python3 scripts/simmersmith_cli.py create-export --week-id <week-id> --export-type shopping_split --pretty
python3 scripts/simmersmith_cli.py run-reminders-export --export-id <export-id> --replace-lists --pretty
```

## Product surfaces

### iOS

The new SwiftUI app currently ships these native-first workflows:

- current week summary and meal browsing
- grocery execution with local check-off state
- recipe browsing plus URL import through the server normalization pipeline
- export queue visibility
- connection/settings management for a self-hosted server

### Browser routes

- `/`
- `/profile`
- `/recipes`
- `/weeks/current`
- `/grocery/current`
- `/pricing/current`

The React UI remains available for:

- staging browser-side edits before chat finalization
- reviewing recorded week change history
- capturing structured meal, shopping, and store feedback
- reviewing the current week
- swapping meals from saved recipes
- changing servings
- editing notes
- approving meal slots
- reviewing grouped grocery output
- reviewing store split recommendations and retailer comparisons
- queueing Apple Reminders export runs for meal plans and shopping splits
- viewing stored taste memory alongside household defaults

## API surface

- `GET /api/health`
- `GET/PUT /api/profile`
- `GET/POST /api/preferences`
- `POST /api/preferences/score-meal`
- `GET/POST /api/recipes`
- `GET /api/weeks`
- `GET /api/weeks/current`
- `POST /api/weeks`
- `GET /api/weeks/{id}`
- `POST /api/weeks/{id}/draft-from-ai`
- `PUT /api/weeks/{id}/meals`
- `GET /api/weeks/{id}/changes`
- `POST /api/weeks/{id}/ready-for-ai`
- `GET/POST /api/weeks/{id}/feedback`
- `POST /api/weeks/{id}/approve`
- `POST /api/weeks/{id}/grocery/regenerate`
- `GET/POST /api/weeks/{id}/exports`
- `GET /api/weeks/{id}/pricing`
- `POST /api/weeks/{id}/pricing/import`
- `GET /api/exports/{id}`
- `GET /api/exports/{id}/apple-reminders`
- `POST /api/exports/{id}/complete`

## Pricing boundary

The app does not scrape retailers itself.

- Codex runs local Playwright outside the container
- Codex resolves product matches and prices
- the app stores those imported results and renders them in the pricing workspace

This keeps the runtime focused on API, UI, and SQLite storage rather than browser automation.

## Export boundary

The container does not automate macOS apps directly.

- the app stores export runs and export item snapshots in SQLite
- the browser queues exports but does not execute them
- the host-side CLI reads the queued export payload
- the host-side CLI writes to Apple Reminders and marks the export run completed or failed

This keeps native Apple automation outside Docker while preserving durable export history inside the app.

## Validation

```bash
cd frontend && npm run build && npm test
.venv/bin/ruff check .
.venv/bin/pytest
docker compose config -q
```
