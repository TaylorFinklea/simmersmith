import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        Group {
            if appState.hasSavedConnection {
                MainTabView()
                    .sheet(isPresented: $appState.showOnboardingInterview) {
                        NavigationStack {
                            OnboardingInterviewView()
                        }
                    }
            } else {
                NavigationStack {
                    SignInView()
                }
            }
        }
    }
}
