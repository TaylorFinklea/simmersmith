import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack {
            SMColor.surface.ignoresSafeArea()

            VStack(spacing: SMSpacing.xxl) {
                Spacer()

                VStack(spacing: SMSpacing.lg) {
                    Image("BrandLockup")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 240)

                    Text("AI-powered meal planning.\nPlan your week. Build your list.")
                        .font(SMFont.headline)
                        .foregroundStyle(SMColor.textSecondary)
                        .multilineTextAlignment(.center)
                }

                Spacer()

                VStack(spacing: SMSpacing.md) {
                    SignInWithAppleButton(.signIn, onRequest: configureAppleRequest) { result in
                        Task { await handleAppleResult(result) }
                    }
                    .signInWithAppleButtonStyle(.white)
                    .frame(height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))

                    NavigationLink("Use a self-hosted server") {
                        ConnectionSetupView()
                    }
                    .font(SMFont.caption)
                    .foregroundStyle(SMColor.textTertiary)
                }

                if let error = appState.lastErrorMessage {
                    Text(error)
                        .font(SMFont.caption)
                        .foregroundStyle(SMColor.destructive)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(SMSpacing.xxl)
        }
        .navigationTitle("")
        .navigationBarHidden(true)
    }

    private func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        request.requestedScopes = [.fullName, .email]
    }

    private func handleAppleResult(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = credential.identityToken,
                  let identityToken = String(data: tokenData, encoding: .utf8) else {
                appState.lastErrorMessage = "Could not read Apple identity token."
                return
            }
            await appState.signInWithApple(identityToken: identityToken)

        case .failure(let error):
            if (error as? ASAuthorizationError)?.code == .canceled { return }
            appState.lastErrorMessage = error.localizedDescription
        }
    }
}
