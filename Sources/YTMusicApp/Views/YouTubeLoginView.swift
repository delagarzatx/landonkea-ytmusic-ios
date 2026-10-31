import SwiftUI
import WebKit

/// YouTube's own page, inside the app, so the user can answer the
/// "confirm you're not a bot" check by signing in. As soon as the
/// session cookie appears in the WebView's cookie store, the session
/// is saved to YouTubeSessionManager and this sheet dismisses itself.
struct YouTubeLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = YouTubeSessionManager.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("YouTube asks you to sign in to confirm you're not a bot. Use a secondary account — once signed in, songs play normally.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .padding()

                YouTubeWebView()
            }
            .navigationTitle("YouTube Sign-In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        session.needsSignIn = false
                        dismiss()
                    }
                }
            }
            .onChange(of: session.isSignedIn) { _, signedIn in
                if signedIn {
                    dismiss()
                }
            }
        }
    }
}

/// The WebView itself. A full Safari user agent is required: Google
/// refuses sign-in inside WebViews that present an obvious
/// embedded-app agent string.
private struct YouTubeWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Mobile/15E148 Safari/604.1"
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: URL(string: "https://music.youtube.com/")!))
        context.coordinator.startPolling(webView)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stopPolling()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private var timer: Timer?

        /// Poll the cookie store: the sign-in completes across
        /// several redirects (Google accounts → YouTube), and the
        /// session cookie can land between page loads.
        func startPolling(_ webView: WKWebView) {
            timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                Self.checkCookies(in: webView)
            }
        }

        func stopPolling() {
            timer?.invalidate()
            timer = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Self.checkCookies(in: webView)
        }

        private static func checkCookies(in webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                if cookies.contains(where: { $0.name == "SAPISID" }) {
                    YouTubeSessionManager.shared.saveSession(cookies: cookies)
                }
            }
        }
    }
}
