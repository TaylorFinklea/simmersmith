# Current State
Branch: main

## Plan
- [ ] 990.5.1-A PUBLIC identity/search/reference reads + headless tests; read revised spec + bead. tier_floor: senior · complexity: M · Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path SimmerSmithCloudKit`
- [ ] 990.5.1-B household IngredientRepository CRUD/detail + signed app tests; mirror Pantry/Recipe repos. tier_floor: senior · complexity: M · Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -quiet -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination id=FDDFB511-272B-40DD-8927-5E71311E96BA -only-testing:SimmerSmithTests/IngredientRepositoryTests`
- [ ] 990.5.1-C household-local base merge/repoint/cycle tests; no PUBLIC mutation. tier_floor: senior · complexity: M · Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -quiet -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination id=FDDFB511-272B-40DD-8927-5E71311E96BA -only-testing:SimmerSmithTests/IngredientRepositoryTests`
- [ ] 990.5.1-D lifecycle/AppState/UI/grocery-link rewire + ownership gating; zero live ingredient apiClient calls. tier_floor: senior · complexity: M · Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build -quiet -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination id=FDDFB511-272B-40DD-8927-5E71311E96BA CODE_SIGNING_ALLOWED=NO`
- [ ] 990.5.1-E receipt-gated complete owned-ingredient Fly migration + tests. tier_floor: senior · complexity: M · Verify: `.venv/bin/pytest -q tests/test_api.py -k ingredient && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -quiet -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination id=FDDFB511-272B-40DD-8927-5E71311E96BA -only-testing:SimmerSmithTests/IngredientMigrationTests`
- [ ] 990.5.2-A pure resolver + public constructor + precedence tests in SimmerSmithKit. tier_floor: senior · complexity: M · Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path SimmerSmithKit`
- [ ] 990.5.2-B bind resolver to PUBLIC/household/private repos; persist preference display names. tier_floor: senior · complexity: M · Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -quiet -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination id=FDDFB511-272B-40DD-8927-5E71311E96BA -only-testing:SimmerSmithTests/IngredientResolverIntegrationTests`
- [ ] 990.5.3 delete the full obsolete nutrition-match slice; preserve NutritionSummary/calculator. tier_floor: senior · complexity: S · Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path SimmerSmithKit && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild build -quiet -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination id=FDDFB511-272B-40DD-8927-5E71311E96BA CODE_SIGNING_ALLOWED=NO`
- [ ] 990.5 product-flow test + phase report/device checklist; do not close beads before Lead backstop. tier_floor: senior · complexity: S · Verify: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -quiet -project SimmerSmith/SimmerSmith.xcodeproj -scheme SimmerSmith -destination id=FDDFB511-272B-40DD-8927-5E71311E96BA -only-testing:SimmerSmithTests/IngredientsProductFlowTests`

## Blockers
- none; execute Plan strictly top-to-bottom; app-target tests run serially and never with `CODE_SIGNING_ALLOWED=NO`.

## Open Questions
- none; Lead corrections recorded in revised spec + decisions.md. Ralph workers do not close beads.
