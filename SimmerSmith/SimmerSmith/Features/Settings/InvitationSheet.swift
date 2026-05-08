import SwiftUI
import UIKit

/// Sheet that surfaces a freshly-minted household invitation code so
/// the owner can copy or share it. M21 Phase 4.
struct InvitationSheet: View {
    let code: String
    let expiresAt: Date?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: SMSpacing.xl) {
                Spacer()

                Text("Share this code")
                    .font(SMFont.subheadline)
                    .foregroundStyle(SMColor.textSecondary)

                Text(code)
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .tracking(2)
                    .foregroundStyle(SMColor.textPrimary)
                    .padding(.horizontal, SMSpacing.xl)
                    .padding(.vertical, SMSpacing.lg)
                    .background(SMColor.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))

                if let expiresAt {
                    Text("Expires \(expiresAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textTertiary)
                }

                HStack(spacing: SMSpacing.md) {
                    Button {
                        UIPasteboard.general.string = code
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                            .font(SMFont.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, SMSpacing.lg)
                            .background(SMColor.surfaceCard)
                            .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    ShareLink(item: shareMessage) {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .font(SMFont.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, SMSpacing.lg)
                            .foregroundStyle(.white)
                            .background(SMColor.primary)
                            .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, SMSpacing.xl)

                Text("The invitee enters this code in Settings → Household → Join a household. After they join, your weeks, recipes, staples, events, and guests are shared with them.")
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, SMSpacing.xl)

                Spacer()
            }
            .paperBackground()
            .navigationTitle("Invite a member")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(SMColor.ember)
                }
            }
            .smithToolbar()
        }
        .presentationDetents([.medium, .large])
    }

    private var shareMessage: String {
        "Join my SimmerSmith household with code \(code)"
    }
}

/// Sheet for entering a household invitation code received from another user.
struct JoinHouseholdSheet: View {
    let onJoin: (String) async -> Bool
    @State private var codeInput: String = ""
    @State private var isJoining = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: SMSpacing.lg) {
                Text("Enter the code from the household owner")
                    .font(SMFont.subheadline)
                    .foregroundStyle(SMColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, SMSpacing.xl)

                TextField("ABCD1234", text: $codeInput)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .padding(.vertical, SMSpacing.lg)
                    .background(SMColor.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                    .padding(.horizontal, SMSpacing.xl)

                Text("Joining will merge your existing weeks, recipes, and pantry into the new household. There's no undo.")
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, SMSpacing.xl)

                if let errorMessage {
                    Text(errorMessage)
                        .font(SMFont.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, SMSpacing.xl)
                }

                Button {
                    Task { await submit() }
                } label: {
                    Text(isJoining ? "Joining…" : "Join")
                        .font(SMFont.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SMSpacing.lg)
                        .background(canSubmit ? SMColor.primary : SMColor.primary.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .padding(.horizontal, SMSpacing.xl)

                Spacer()
            }
            .paperBackground()
            .navigationTitle("Join a household")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(SMColor.ember)
                }
            }
            .smithToolbar()
        }
        .presentationDetents([.medium])
    }

    private var canSubmit: Bool {
        !isJoining
            && !codeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submit() async {
        errorMessage = nil
        isJoining = true
        let ok = await onJoin(codeInput)
        isJoining = false
        if ok {
            dismiss()
        } else {
            errorMessage = "We couldn't verify that code. It may have expired or already been used."
        }
    }
}
