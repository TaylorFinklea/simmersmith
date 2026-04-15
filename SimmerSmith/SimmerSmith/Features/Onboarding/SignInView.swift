import AuthenticationServices
import GoogleSignIn
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

                    Button {
                        Task { await handleGoogleSignIn() }
                    } label: {
                        HStack {
                            Image(systemName: "g.circle.fill")
                            Text("Sign in with Google")
                                .font(.system(size: 17, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(SMColor.surfaceCard)
                        .foregroundStyle(SMColor.textPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: SMRadius.md, style: .continuous)
                                .strokeBorder(SMColor.divider, lineWidth: 1)
                        )
                    }

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

    private func handleGoogleSignIn() async {
        guard let windowScene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
              let rootVC = windowScene.windows.first?.rootViewController else {
            appState.lastErrorMessage = "Cannot find root view controller for Google Sign-In."
            return
        }

        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: rootVC)
            guard let idToken = result.user.idToken?.tokenString else {
                appState.lastErrorMessage = "Could not read Google identity token."
                return
            }
            await appState.signInWithGoogle(identityToken: idToken)
        } catch {
            let nsError = error as NSError
            if nsError.domain == "com.google.GIDSignIn" && nsError.code == -5 { return } // user cancelled
            appState.lastErrorMessage = "Google sign in failed: \(error.localizedDescription)"
        }
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
