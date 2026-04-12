import SwiftUI
import WebKit
import SimmerSmithKit

struct RecipeWebImportView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let url: String
    let onImported: (RecipeDraft) -> Void

    @State private var isLoading = true
    @State private var isImporting = false
    @State private var pageTitle = ""
    @State private var errorMessage: String?
    @State private var webView: WKWebView?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                WebViewRepresentable(
                    url: URL(string: url)!,
                    isLoading: $isLoading,
                    pageTitle: $pageTitle,
                    onWebViewCreated: { webView = $0 }
                )

                // Bottom import bar
                VStack(spacing: 8) {
                    if let error = errorMessage {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        Task { await extractAndImport() }
                    } label: {
                        if isImporting {
                            HStack {
                                ProgressView()
                                Text("Importing...")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Label("Import This Recipe", systemImage: "square.and.arrow.down")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoading || isImporting)
                }
                .padding()
                .background(.thinMaterial)
            }
            .navigationTitle(pageTitle.isEmpty ? "Loading..." : pageTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func extractAndImport() async {
        guard let webView else {
            errorMessage = "Web view not ready."
            return
        }

        isImporting = true
        errorMessage = nil

        do {
            let html = try await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String ?? ""
            if html.count < 100 {
                errorMessage = "Could not extract page content."
                isImporting = false
                return
            }

            let currentURL = webView.url?.absoluteString ?? url
            let draft = try await appState.importRecipeDraft(
                fromHTML: html,
                sourceURL: currentURL,
                sourceLabel: pageTitle
            )
            onImported(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }

        isImporting = false
    }
}

// MARK: - WKWebView wrapper

private struct WebViewRepresentable: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var pageTitle: String
    let onWebViewCreated: (WKWebView) -> Void

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        onWebViewCreated(webView)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebViewRepresentable

        init(parent: WebViewRepresentable) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in
                parent.isLoading = true
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                parent.isLoading = false
                parent.pageTitle = webView.title ?? ""
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                parent.isLoading = false
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in
                parent.isLoading = false
            }
        }
    }
}
