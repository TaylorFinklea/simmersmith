import SimmerSmithKit
import SwiftUI

/// Memory-log section for `RecipeDetailView`. Shows a chronological
/// list of memory entries (newest first) with a "+" affordance to
/// open the compose sheet, and a swipe-to-delete on each row. Phase
/// 1 ships text-only; Phase 2 will render a thumbnail and viewer
/// when the entry has a photo.
struct RecipeMemoriesSection: View {
    let recipeID: String

    @Environment(AppState.self) private var appState
    @State private var isComposing = false
    @State private var loadError: String?
    @State private var pendingDelete: RecipeMemory?

    private var memories: [RecipeMemory] {
        appState.recipeMemoriesCached(recipeID: recipeID) ?? []
    }

    var body: some View {
        SMCard {
            VStack(alignment: .leading, spacing: SMSpacing.md) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Memories", systemImage: "brain")
                        .font(SMFont.label)
                        .foregroundStyle(SMColor.textTertiary)
                    Spacer()
                    Button {
                        isComposing = true
                    } label: {
                        Label("Add", systemImage: "plus.circle.fill")
                            .labelStyle(.iconOnly)
                            .font(.title3)
                            .foregroundStyle(SMColor.primary)
                    }
                    .accessibilityLabel("Add memory")
                }

                if memories.isEmpty {
                    Text("No memories yet. Tap + to log a cook.")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textTertiary)
                } else {
                    ForEach(memories) { memory in
                        memoryRow(memory)
                        if memory.id != memories.last?.id {
                            Divider().background(SMColor.divider)
                        }
                    }
                }

                if let loadError {
                    Text(loadError)
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.destructive)
                }
            }
        }
        .task(id: recipeID) {
            await load()
        }
        .sheet(isPresented: $isComposing) {
            MemoryComposeSheet(recipeID: recipeID)
        }
        .confirmationDialog(
            "Delete this memory?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { memory in
            Button("Delete", role: .destructive) {
                Task { await delete(memory) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    @ViewBuilder
    private func memoryRow(_ memory: RecipeMemory) -> some View {
        VStack(alignment: .leading, spacing: SMSpacing.xs) {
            Text(memory.body)
                .font(SMFont.body)
                .foregroundStyle(SMColor.textPrimary)
            HStack {
                Text(memory.createdAt.formatted(.relative(presentation: .named)))
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textTertiary)
                Spacer()
                Button {
                    pendingDelete = memory
                } label: {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(SMColor.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Delete memory")
            }
        }
        .padding(.vertical, SMSpacing.xs)
    }

    private func load() async {
        do {
            _ = try await appState.refreshRecipeMemories(recipeID: recipeID)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func delete(_ memory: RecipeMemory) async {
        do {
            try await appState.deleteRecipeMemory(recipeID: recipeID, memoryID: memory.id)
        } catch {
            loadError = error.localizedDescription
        }
    }
}
