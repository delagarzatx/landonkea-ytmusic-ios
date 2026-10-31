import Foundation
import CryptoKit
import Security
import WebKit

/// Holds the YouTube session the user creates by signing in inside
/// the app (YouTube's "Sign in to confirm you're not a bot" page).
///
/// WHY THIS EXISTS:
/// YouTube refuses anonymous /player requests with LOGIN_REQUIRED
/// ("Sign in to confirm you're not a bot"), so playback is impossible
/// without a session. When that answer comes back, `needsSignIn`
/// flips to true and ContentView presents the sign-in sheet; when the
/// user completes it, the session cookies are stored here and every
/// InnerTube request starts carrying them.
///
/// STORAGE: the session lives in the Keychain, never in
/// UserDefaults, and is only ever sent to YouTube's own API host.
final class YouTubeSessionManager: ObservableObject {
    static let shared = YouTubeSessionManager()

    /// True when session cookies are stored.
    @Published private(set) var isSignedIn: Bool = false

    /// Observed by ContentView: when true, the sign-in sheet shows.
    /// Set by `noteSignInRequired()` (YouTube refused a request) or
    /// by the Sign In button in Settings.
    @Published var needsSignIn: Bool = false

    private var cookieHeader: String?
    private var sapisid: String?

    private let keychainService = "com.delagarza.ytmusic.youtube-session"
    private let keychainAccount = "session"

    private init() {
        loadFromKeychain()
    }

    // MARK: - Session intake

    /// Called by the login WebView as soon as a SAPISID cookie shows
    /// up in YouTube's pages: the sign-in / bot check is complete.
    func saveSession(cookies: [HTTPCookie]) {
        let relevant = cookies.filter {
            $0.domain.contains("youtube.com") || $0.domain.contains("google.com")
        }
        guard !relevant.isEmpty else { return }

        let header = relevant
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
        let sapisidValue = relevant.first { $0.name == "SAPISID" }?.value
            ?? relevant.first { $0.name == "__Secure-3PAPISID" }?.value
            ?? relevant.first { $0.name == "__Secure-1PAPISID" }?.value

        DispatchQueue.main.async {
            self.cookieHeader = header
            self.sapisid = sapisidValue
            self.isSignedIn = true
            self.needsSignIn = false
            self.persistToKeychain()
        }
    }

    /// YouTube refused an anonymous request (LOGIN_REQUIRED).
    /// Ask the UI to present the sign-in sheet.
    func noteSignInRequired() {
        DispatchQueue.main.async {
            if !self.isSignedIn {
                self.needsSignIn = true
            }
        }
    }

    /// Forget the session everywhere: Keychain, memory, and the
    /// WebView's own cookie store, so the next sign-in starts from a
    /// logged-out YouTube page.
    func signOut() {
        DispatchQueue.main.async {
            self.cookieHeader = nil
            self.sapisid = nil
            self.isSignedIn = false
            self.deleteFromKeychain()
        }
        let store = WKWebsiteDataStore.default().httpCookieStore
        store.getAllCookies { cookies in
            for cookie in cookies
            where cookie.domain.contains("youtube.com") || cookie.domain.contains("google.com") {
                store.delete(cookie)
            }
        }
    }

    // MARK: - Headers for InnerTube requests

    /// The Cookie header value for API requests, if signed in.
    var cookieHeaderValue: String? {
        cookieHeader
    }

    /// The Authorization header InnerTube expects next to the
    /// session cookies:
    /// `SAPISIDHASH <timestamp>_<sha1("<timestamp> <SAPISID> <origin>")>`
    func authorizationHeader(origin: String) -> String? {
        guard let sapisid = sapisid else { return nil }
        let timestamp = Int(Date().timeIntervalSince1970)
        let payload = "\(timestamp) \(sapisid) \(origin)"
        let digest = Insecure.SHA1.hash(data: Data(payload.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(timestamp)_\(hex)"
    }

    // MARK: - Keychain storage

    private func persistToKeychain() {
        guard let cookieHeader = cookieHeader else { return }
        var payload: [String: String] = ["cookie": cookieHeader]
        if let sapisid = sapisid {
            payload["sapisid"] = sapisid
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private func loadFromKeychain() {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let cookie = payload["cookie"] else {
            return
        }
        cookieHeader = cookie
        sapisid = payload["sapisid"]
        isSignedIn = true
    }

    private func deleteFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }
}
