import Foundation

/// Fetches Proof-of-Origin (PO) tokens from the token provider
/// running on the home server (bgutil, Docker) over Tailscale.
///
/// WHY THIS EXISTS:
/// YouTube refuses anonymous /player requests with LOGIN_REQUIRED
/// ("Sign in to confirm you're not a bot"). A PO token — generated
/// by running YouTube's own BotGuard check, with NO account — is
/// the proof the player endpoint accepts. The app asks the provider
/// for one token per song (tokens are bound to the video ID) and
/// sends it in the player request.
///
/// The provider is reachable only over Tailscale at the home
/// server's Tailscale address; if it can't be reached (Tailscale
/// off, server down), token() returns nil and the player request
/// goes out without a token, exactly like the app behaved before.
final class PoTokenManager {
    static let shared = PoTokenManager()

    /// Provider base URL. Overridable in UserDefaults under
    /// "potProviderURL" if the server ever moves.
    private var providerBaseURL: String {
        UserDefaults.standard.string(forKey: "potProviderURL") ?? "http://100.85.23.30:4416"
    }

    private var cache: [String: (token: String, expiresAt: Date)] = [:]
    private let cacheLifetime: TimeInterval = 5 * 60 * 60  // provider tokens live ~6 h; stay under it

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30  // minting a fresh token can take ~15 s
        return URLSession(configuration: config)
    }()

    private init() {}

    /// A PO token bound to this video, or nil if the provider is
    /// unreachable. Cached per video for `cacheLifetime` unless
    /// `bypassCache` is set (used by the retry after a refusal,
    /// which must present a FRESH token).
    func token(for videoId: String, bypassCache: Bool = false) async -> String? {
        if !bypassCache, let entry = cache[videoId], entry.expiresAt > Date() {
            return entry.token
        }

        guard let url = URL(string: "\(providerBaseURL)/get_pot") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = ["content_binding": videoId]
        if bypassCache {
            payload["bypass_cache"] = true
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            struct ProviderResponse: Decodable {
                let poToken: String
            }
            let decoded = try JSONDecoder().decode(ProviderResponse.self, from: data)
            cache[videoId] = (decoded.poToken, Date().addingTimeInterval(cacheLifetime))
            return decoded.poToken
        } catch {
            // Provider unreachable or answered garbage: no token.
            // The caller proceeds without one (best effort).
            return nil
        }
    }
}
