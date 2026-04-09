import SwiftUI
import SimmerSmithKit

struct StepsEditor: View {
    @Binding var steps: [RecipeStep]

    let onAddStep: () -> Void
    let onRemoveStep: (String) -> Void
    let onMoveStep: (String, Int) -> Void
    let onAddSubstep: (String) -> Void
    let onRemoveSubstep: (String, String) -> Void
    let onMoveSubstep: (String, String, Int) -> Void

    var body: some View {
        Section("Instructions") {
            if steps.isEmpty {
                Text("Add main steps, then add optional lettered substeps underneath.")
                    .foregroundStyle(.secondary)
            }

            ForEach($steps) { $step in
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Step \(step.sortOrder)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Up") { onMoveStep(step.id, -1) }
                            .disabled(step.sortOrder == 1)
                        Button("Down") { onMoveStep(step.id, 1) }
                            .disabled(step.sortOrder == steps.count)
                    }

                    TextField("Main instruction", text: $step.instruction, axis: .vertical)

                    if !step.substeps.isEmpty {
                        ForEach($step.substeps) { $substep in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(substepLabel(for: substep.sortOrder))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Up") { onMoveSubstep(step.id, substep.id, -1) }
                                        .disabled(substep.sortOrder == 1)
                                    Button("Down") { onMoveSubstep(step.id, substep.id, 1) }
                                        .disabled(substep.sortOrder == step.substeps.count)
                                }

                                TextField("Optional substep", text: $substep.instruction, axis: .vertical)
                                    .padding(.leading, 12)

                                HStack {
                                    Spacer()
                                    Button("Remove substep", role: .destructive) {
                                        onRemoveSubstep(step.id, substep.id)
                                    }
                                    .font(.footnote)
                                }
                            }
                        }
                    }

                    HStack {
                        Button {
                            onAddSubstep(step.id)
                        } label: {
                            Label("Add substep", systemImage: "plus.circle")
                        }

                        Spacer()

                        Button("Remove step", role: .destructive) {
                            onRemoveStep(step.id)
                        }
                        .font(.footnote)
                    }
                }
                .padding(.vertical, 6)
            }

            Button {
                onAddStep()
            } label: {
                Label("Add step", systemImage: "plus.circle")
            }
        }
    }

    private func substepLabel(for sortOrder: Int) -> String {
        let scalar = UnicodeScalar(UInt32(96 + max(sortOrder, 1))) ?? UnicodeScalar(97)!
        return String(Character(scalar))
    }
}
