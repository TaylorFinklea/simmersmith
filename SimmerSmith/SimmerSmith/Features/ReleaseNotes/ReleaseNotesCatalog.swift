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
