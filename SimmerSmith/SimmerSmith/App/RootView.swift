import SwiftUI

/// SP-C identity slice: the launch gate.
///
/// Gates on CloudKit-household readiness (`householdLaunchPhase`) instead of the
/// Fly token (`hasSavedConnection`). Three states:
/// - `.resolving` — brief loading spinner while CloudKit discovers/creates the household.
/// - `.ready`     — household resolved; show `MainTabView`.
/// - `.iCloudUnavailable` — iCloud account not signed in; show a friendly prompt.
///
/// Sign in with Apple is removed from this gate — iCloud IS the identity now.
/// The dormant `signInWithApple` AppState method is preserved
/// (unreferenced from UI) for the future one-time Fly migration auth.
struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        Group {
            #if canImport(CloudKit)
            switch appState.householdLaunchPhase {
            case .ready:
                MainTabView()

            case .resolving:
                iCloudLoadingView

            case .iCloudUnavailable:
                iCloudUnavailableView
            }
            #else
            // Non-CloudKit platforms (should not occur on iOS) fall back to loading.
            iCloudLoadingView
            #endif
        }
        .sheet(item: $appState.pendingPaywall) { reason in
            PaywallSheet(reason: reason)
        }
        // simmersmith-224: What's New. `onDismiss` — not the presentation — is
        // what records the notes as seen, so a sheet she never actually read
        // (app killed, phone put down) comes back next launch.
        .sheet(
            item: $appState.pendingReleaseNotes,
            onDismiss: { appState.markReleaseNotesSeen() }
        ) { presentation in
            ReleaseNotesSheet(notes: presentation.notes)
        }
        #if canImport(CloudKit)
        // Only once the household is resolved — otherwise the sheet lands on top
        // of the loading spinner or the "Sign in to iCloud" prompt. This also
        // covers the user who signs into iCloud in Settings and comes back,
        // which the app's `.task` (cold launch only) would miss.
        .onChange(of: appState.householdLaunchPhase, initial: true) { _, phase in
            guard phase == .ready else { return }
            appState.evaluatePendingReleaseNotes()
        }
        #endif
    }

    // MARK: - Loading state

    private var iCloudLoadingView: some View {
        ZStack {
            SMColor.paper.ignoresSafeArea()
            PaperGrain().ignoresSafeArea()

            VStack(spacing: SMSpacing.lg) {
                FuMark(size: 56, color: SMColor.ink, ember: SMColor.ember)
                    .padding(.bottom, SMSpacing.sm)

                ProgressView()
                    .tint(SMColor.ember)

                Text("Opening your kitchen…")
                    .font(SMFont.subheadline)
                    .foregroundStyle(SMColor.textSecondary)

                // Review finding F3: a transient (non-auth) failure leaves us in
                // .resolving — don't spin forever. Surface the soft error + a manual
                // "Try again" that re-invokes the resolver (the scenePhase foreground
                // retry also covers this, but the user shouldn't have to background).
                if let message = appState.lastErrorMessage {
                    VStack(spacing: SMSpacing.md) {
                        Text(message)
                            .font(SMFont.caption)
                            .foregroundStyle(SMColor.textTertiary)
                            .multilineTextAlignment(.center)

                        Button {
                            #if canImport(CloudKit)
                            Task { await appState.ensureHouseholdSession() }
                            #endif
                        } label: {
                            Text("Try again")
                                .font(SMFont.caption.weight(.semibold))
                                .foregroundStyle(SMColor.ember)
                        }
                    }
                    .padding(.top, SMSpacing.sm)
                    .padding(.horizontal, SMSpacing.xxl)
                }
            }
        }
    }

    // MARK: - iCloud unavailable state

    private var iCloudUnavailableView: some View {
        // Review finding F4: one NavigationStack wrapping the whole view (the previous
        // build nested a NavigationStack mid-VStack just to host the debug link, which is
        // malformed — a NavigationStack can't sit inside a VStack as a sibling row and
        // host navigation correctly). The debug NavigationLink is now a normal row.
        NavigationStack {
            ZStack {
                SMColor.paper.ignoresSafeArea()
                PaperGrain().ignoresSafeArea()

                VStack(spacing: SMSpacing.xl) {
                    Spacer()

                    FuMark(size: 56, color: SMColor.ink, ember: SMColor.ember)

                    VStack(spacing: SMSpacing.md) {
                        Text("Sign in to iCloud")
                            .font(SMFont.headline)
                            .foregroundStyle(SMColor.textPrimary)

                        Text("SimmerSmith uses iCloud to store your recipes and household data. Open Settings → [Your Name] → iCloud and sign in, then come back.")
                            .font(SMFont.body)
                            .foregroundStyle(SMColor.textSecondary)
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text("Open Settings")
                            .font(SMFont.body)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                            .background(SMColor.ember)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                    }

                    if DebugGate.showsCloudKitChecks {
                        NavigationLink("CloudKit checks (debug)") {
                            CloudKitDebugView()
                        }
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.textTertiary)
                    }

                    Spacer()
                }
                .padding(SMSpacing.xxl)
            }
        }
    }
}
