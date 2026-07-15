import Foundation

/// The release notes shipped inside the app. **This is the file you edit when
/// you cut a release.**
///
/// Rules, in order of how much they will bite you:
///
/// 1. **Every build needs an entry.** `scripts/release-ios.sh` refuses to
///    archive a build whose number has no entry here, and
///    `ReleaseNotesCatalogTests` fails on every test run for the same reason.
///    Nothing ships without you having decided what to tell people.
/// 2. **"Nothing to report" is a valid answer.** A signing-fix rebuild with no
///    user-visible change gets an entry with all three lists empty. That
///    satisfies the preflight and raises no sheet.
/// 3. **`build:` must stay on its own line** in the form `build: 152,` — the
///    release preflight greps for exactly that shape.
/// 4. **Write for the person cooking, not the person committing.** "Memory
///    photos appear right away", not "fixed a stale @Observable read".
enum ReleaseNotesCatalog {

    static let all: [ReleaseNote] = [
        ReleaseNote(
            build: 156,
            version: "1.0.0",
            date: "July 15, 2026",
            headline: "Under the hood",
            new: [],
            improved: [],
            fixed: []
        ),
        ReleaseNote(
            build: 155,
            version: "1.0.0",
            date: "July 14, 2026",
            headline: "The assistant pays attention",
            new: [
                "The assistant now knows which week you're looking at. Flip to next week, ask it to swap Tuesday, and it changes next week — not this one.",
                "It also knows your allergies. If you ask for something that contains one, it says no and tells you why, instead of quietly putting it on the menu.",
                "Recipe nutrition estimates are back on — no API key needed, it does the math from the ingredient catalog.",
                "Scan an ingredient with the camera, and swap any ingredient for a suggested substitute. Both were finished a while ago and accidentally left switched off.",
            ],
            improved: [
                "Every AI action in the chat now shows what it actually did, with a real name and icon instead of a generic card.",
                "When a key or model doesn't work, Settings tells you what the provider actually said, not just \"HTTP 400\".",
            ],
            fixed: [
                "Edit something twice quickly and both edits stick. The second one used to be quietly thrown away.",
                "Unlink a recipe from a side dish and it stays unlinked, instead of reappearing on the other phone.",
                "Editing an event no longer deletes a guest your partner added while you had the sheet open — and their plus-ones survive too.",
                "The Week screen no longer claims you're off your nutrition targets when it has no nutrition data at all.",
                "Removed buttons that never worked: Plan Shopping, the grocery feedback swipe, and a handful of settings that did nothing.",
            ]
        ),
        ReleaseNote(
            build: 154,
            version: "1.0.0",
            date: "July 14, 2026",
            headline: "Safety first",
            new: [],
            improved: [],
            fixed: [
                "A developer diagnostics screen could quietly reset your dietary goal, measurement units, and taste history. It can't touch your real data anymore.",
                "Removed a test-only sharing shortcut from beta builds — household sharing itself is unchanged.",
            ]
        ),
        ReleaseNote(
            build: 153,
            version: "1.0.0",
            date: "July 13, 2026",
            headline: "Housekeeping",
            new: [],
            improved: [],
            fixed: [
                "The “leftover empty household” warning is gone. SimmerSmith now clears out the empty leftovers older builds left behind, on its own — and it never touches a household with anything in it.",
            ]
        ),
        ReleaseNote(
            build: 152,
            version: "1.0.0",
            date: "July 13, 2026",
            headline: "Your kitchen remembers",
            new: [
                "Recipe memories — snap a photo and jot a note on anything you cook. They sync to everyone in the household.",
                "Ingredients now match right on your phone, so the grocery list sorts itself even with no signal.",
                "This screen. You'll see it once after each update, and it's always waiting in Settings under What's New.",
            ],
            improved: [
                "Rating a meal actually shapes next week's plan now — the ones you thumbs-down stop coming back.",
                "Settings → iCloud Sync shows you what's syncing, and says so plainly when something is stuck.",
                "Grocery edits you make over in the Reminders app find their way back to SimmerSmith even while it's closed.",
            ],
            fixed: [
                "Recipe memory photos appear the moment you add them, instead of only after leaving and reopening the recipe.",
                "Tonight's-meal and Saturday-planning reminders are arriving again.",
            ]
        ),
    ]
}
