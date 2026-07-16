# P8 baseline-runner — worktree pins (spec §Worktree)

- Base commit: `12ff8c5` (main, 2026-07-16)
- Branch: `p8-baseline-runner`
- `SimmerSmith/SimmerSmith/Features/VoicePlanning/CloudParseService.swift` SHA-256:
  `40575d47e38256a6970bd28d64e252280f098cb97c1a5ba266b614850d8ed3b7`

Standing verify, every phase:

```sh
shasum -a 256 -c <<< "40575d47e38256a6970bd28d64e252280f098cb97c1a5ba266b614850d8ed3b7  SimmerSmith/SimmerSmith/Features/VoicePlanning/CloudParseService.swift"
git diff 12ff8c5..HEAD -- SimmerSmith/SimmerSmith/Features/VoicePlanning/CloudParseService.swift
```

(diff must be empty; hash must check OK; plus the existing `useBallastParse == false` test.)
