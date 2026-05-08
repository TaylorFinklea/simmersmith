import SwiftUI

/// Build 63 — Fusion filter sheet for the Forge (Recipes) tab.
/// Replaces the four inline filter rows (difficulty / quick /
/// cleanup) with a single "Filters" button on the toolbar that
/// presents this paper-backed sheet. Meal-type stays as a visible
/// chip row at the top of the Forge scroll because it's the most-
/// used filter. Search uses the system `.searchable` modifier.
///
/// State is bound back to the parent (`RecipesView`) so dismissing
/// the sheet doesn't lose the user's selections, and clearing here
/// clears there.
struct RecipeFilterSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var difficulty: DifficultyFilter
    @Binding var quickOnly: Bool
    @Binding var cleanup: RecipeCleanupFilter

    var activeCount: Int {
        var n = 0
        if difficulty != .any { n += 1 }
        if quickOnly { n += 1 }
        if cleanup != .none { n += 1 }
        return n
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    titlePlate
                        .padding(.horizontal, SMSpacing.lg)
                        .padding(.top, SMSpacing.lg)
                        .padding(.bottom, SMSpacing.md)

                    section(label: "difficulty") {
                        chipRow(DifficultyFilter.allCases.map { f in (
                            label: f.shortLabel,
                            selected: difficulty == f,
                            action: { difficulty = f }
                        )})
                    }

                    HandRule(color: SMColor.rule, height: 5, lineWidth: 0.8)
                        .padding(.horizontal, SMSpacing.lg)
                        .padding(.vertical, SMSpacing.sm)

                    section(label: "speed") {
                        FuOutlinedPill(
                            label: "quick (≤30 min)",
                            color: SMColor.ember,
                            filled: quickOnly,
                            rotation: 0
                        )
                        .onTapGesture { quickOnly.toggle() }
                    }

                    HandRule(color: SMColor.rule, height: 5, lineWidth: 0.8)
                        .padding(.horizontal, SMSpacing.lg)
                        .padding(.vertical, SMSpacing.sm)

                    section(label: "cleanup") {
                        chipRow(RecipeCleanupFilter.allCases.map { filter in (
                            label: filter.label.lowercased(),
                            selected: cleanup == filter,
                            action: { cleanup = (cleanup == filter && filter != .none) ? .none : filter }
                        )})
                    }
                }
                .padding(.bottom, SMSpacing.xxl)
            }
            .paperBackground()
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            difficulty = .any
                            quickOnly = false
                            cleanup = .none
                        }
                    }
                    .foregroundStyle(activeCount == 0 ? SMColor.inkFaint : SMColor.ember)
                    .disabled(activeCount == 0)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(SMColor.ember)
                }
            }
            .smithToolbar()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Title plate (washi-tape index card)

    private var titlePlate: some View {
        FuIndexCard(rotation: -0.3, washi: SMColor.risoYellow, rivets: false) {
            VStack(alignment: .leading, spacing: 4) {
                FuEyebrow(text: activeCount == 0 ? "no filters set" : "\(activeCount) active", ember: activeCount > 0)
                Text("narrow the forge")
                    .font(SMFont.serifDisplay(22))
                    .foregroundStyle(SMColor.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Section + chip row helpers

    @ViewBuilder
    private func section<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: SMSpacing.sm) {
            HStack(spacing: SMSpacing.sm) {
                Text(label)
                    .font(SMFont.handwritten(18, bold: true))
                    .foregroundStyle(SMColor.ink)
                HandUnderline(color: SMColor.ember, width: 28)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SMSpacing.lg)
        .padding(.vertical, SMSpacing.sm)
    }

    private struct ChipSpec {
        let label: String
        let selected: Bool
        let action: () -> Void
    }

    @ViewBuilder
    private func chipRow(_ specs: [(label: String, selected: Bool, action: () -> Void)]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: SMSpacing.sm) {
                ForEach(Array(specs.enumerated()), id: \.offset) { idx, spec in
                    Button(action: spec.action) {
                        FuOutlinedPill(
                            label: spec.label,
                            color: SMColor.ember,
                            filled: spec.selected,
                            rotation: idx.isMultiple(of: 2) ? -0.5 : 0.5
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private extension DifficultyFilter {
    /// Short label for chip display — drops the "Any difficulty"
    /// → "any" so chips fit on one row without horizontal scroll
    /// being required.
    var shortLabel: String {
        switch self {
        case .any: return "any"
        case .easy: return "easy"
        case .medium: return "medium"
        case .hard: return "hard"
        case .kidFriendly: return "kid-friendly"
        }
    }
}
