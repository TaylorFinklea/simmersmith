import AuthenticationServices
import SwiftUI

struct SignInView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            VStack(spacing: 16) {
                Image("BrandLockup")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 240)

                Text("AI-powered meal planning.\nPlan your week. Build your list.")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Spacer()

            VStack(spacing: 12) {
                SignInWithAppleButton(.signIn, onRequest: configureAppleRequest) { result in
                    Task { await handleAppleResult(result) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                NavigationLink("Use a self-hosted server") {
                    ConnectionSetupView()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if let error = appState.lastErrorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
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
