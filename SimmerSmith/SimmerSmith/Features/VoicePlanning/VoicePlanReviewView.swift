import SwiftUI
import SimmerSmithKit

/// SP-C voice week-planning — the review screen. Shown AFTER parse + resolve, BEFORE any
/// CloudKit write (the user-locked "review before apply"). The user sees what was heard +
/// each proposed meal with a provenance badge, can remove wrong rows, then Apply commits via
/// the same `saveWeekMeals` path the assistant tool uses (grocery regen + CloudKit mirror).
struct VoicePlanReviewView: View {
    let weekId: String
    let transcript: String

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var rows: [ReviewRow]
    @State private var applying = false
    @State private var errorMessage: String?
    @State private var showTranscript = false

    init(weekId: String, transcript: String, proposal: [MealUpdateRequest]) {
        self.weekId = weekId
        self.transcript = transcript
        _rows = State(initialValue: proposal.map(ReviewRow.init))
    }

    private static let dayOrder = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"]
    private static let slotOrder = ["breakfast", "lunch", "dinner"]

    private var orderedDays: [String] {
        let present = Set(rows.map(\.meal.dayName))
        return Self.dayOrder.filter(present.contains)
    }

    private func rows(for day: String) -> [ReviewRow] {
        rows.filter { $0.meal.dayName == day }
            .sorted { (Self.slotOrder.firstIndex(of: $0.meal.slot) ?? 9) < (Self.slotOrder.firstIndex(of: $1.meal.slot) ?? 9) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !transcript.isEmpty {
                    Section {
                        DisclosureGroup(isExpanded: $showTranscript) {
                            Text(transcript)
                                .font(SMFont.caption)
                                .foregroundStyle(SMColor.textSecondary)
                        } label: {
                            Label("What I heard", systemImage: "waveform")
                                .font(SMFont.subheadline)
                        }
                    }
                }

                if rows.isEmpty {
                    Section {
                        Text("I didn't catch any meals. Tap Cancel and try again, speaking the day and dish for each meal.")
                            .font(SMFont.subheadline)
                            .foregroundStyle(SMColor.textSecondary)
                    }
                } else {
                    ForEach(orderedDays, id: \.self) { day in
                        Section(day) {
                            ForEach(rows(for: day)) { row in
                                mealRow(row)
                            }
                            .onDelete { offsets in delete(day: day, at: offsets) }
                        }
                    }
                }
            }
            .navigationTitle("Review your week")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(applying ? "Applying…" : "Apply") { Task { await apply() } }
                        .disabled(applying || rows.isEmpty)
                }
            }
            .alert("Couldn't apply", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    @ViewBuilder
    private func mealRow(_ row: ReviewRow) -> some View {
        HStack(spacing: SMSpacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.meal.slot.capitalized)
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textTertiary)
                Text(row.meal.recipeName)
                    .font(SMFont.subheadline)
                    .foregroundStyle(SMColor.textPrimary)
            }
            Spacer()
            badge(row.provenance)
        }
    }

    @ViewBuilder
    private func badge(_ p: ReviewRow.Provenance) -> some View {
        Text(p.label)
            .font(SMFont.caption)
            .foregroundStyle(p.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(p.tint.opacity(0.15), in: Capsule())
    }

    private func delete(day: String, at offsets: IndexSet) {
        let dayRows = rows(for: day)
        let ids = offsets.map { dayRows[$0].id }
        rows.removeAll { ids.contains($0.id) }
    }

    private func apply() async {
        applying = true
        defer { applying = false }
        // Proposed rows carry approved=false; Apply confirms them — flip to true so voice-planned
        // meals match the manually-added path (e.g. WeekView's "Eating Out" writes approved=true).
        let confirmed = rows.map { row in
            MealUpdateRequest(
                mealId: row.meal.mealId, dayName: row.meal.dayName, mealDate: row.meal.mealDate,
                slot: row.meal.slot, recipeId: row.meal.recipeId, recipeName: row.meal.recipeName,
                servings: row.meal.servings, scaleMultiplier: row.meal.scaleMultiplier,
                notes: row.meal.notes, approved: true
            )
        }
        // MERGE the voice meals into the week's existing ones and send the full desired week, so a
        // voice-only payload doesn't drop the rest. (saveWeekMeals is baseline-aware since eky — it
        // won't delete a concurrent add the snapshot never saw — but we still fold so the meals the
        // model DID know about stay put; `known` below is the exact snapshot we folded into.)
        let merged = VoicePlanResolver.merge(voice: confirmed, into: existingMeals)
        do {
            // knownMealIDs: `existingMeals` — the week snapshot voice merged into.
            let known = Set(existingMeals.compactMap { $0.mealId })
            _ = try await appState.saveWeekMeals(weekID: weekId, meals: merged, knownMealIDs: known)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The week's current meals (so Apply preserves everything voice didn't touch).
    private var existingMeals: [MealUpdateRequest] {
        let snap: WeekSnapshot? = appState.currentWeek?.weekId == weekId
            ? appState.currentWeek
            : (appState.browsedWeek?.weekId == weekId ? appState.browsedWeek : nil)
        return (snap?.meals ?? []).map { m in
            MealUpdateRequest(
                mealId: m.mealId, dayName: m.dayName, mealDate: m.mealDate, slot: m.slot,
                recipeId: m.recipeId, recipeName: m.recipeName, servings: m.servings,
                scaleMultiplier: m.scaleMultiplier, notes: m.notes, approved: m.approved
            )
        }
    }
}

/// One reviewable proposed meal + its provenance (drives the badge).
struct ReviewRow: Identifiable {
    let id = UUID()
    let meal: MealUpdateRequest
    let provenance: Provenance

    init(_ meal: MealUpdateRequest) {
        self.meal = meal
        self.provenance = Provenance(meal)
    }

    enum Provenance {
        case matched, freeText, eatOut, leftovers

        init(_ m: MealUpdateRequest) {
            if m.recipeName == "Eating Out" { self = .eatOut }
            else if m.recipeName == "Leftovers" || m.recipeName.hasSuffix("Leftovers") { self = .leftovers }
            else if m.recipeId != nil { self = .matched }
            else { self = .freeText }
        }

        var label: String {
            switch self {
            case .matched: return "matched"
            case .freeText: return "new"
            case .eatOut: return "eat out"
            case .leftovers: return "leftovers"
            }
        }

        var tint: Color {
            switch self {
            case .matched: return SMColor.accent
            case .freeText: return SMColor.textSecondary
            case .eatOut: return SMColor.textTertiary
            case .leftovers: return SMColor.textTertiary
            }
        }
    }
}
