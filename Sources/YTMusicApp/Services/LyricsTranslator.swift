import Foundation

// MARK: - Lyrics Translator

/// Translates lyrics text to another language using a free translation API.
///
/// WHAT THIS DOES:
/// Takes lyrics text (either a single string or synced lines) and translates
/// them to the target language. Users can toggle between original and translated
/// lyrics while listening to a song.
///
/// TRANSLATION API:
/// Uses MyMemory (mymemory.translated.net), a free, no-auth translation API.
/// It's based on Google Translate and other open-source translation engines.
/// Rate limit: 5000 characters/day for anonymous users (enough for ~10 songs).
///
/// HOW IT WORKS:
/// 1. User taps "Translate" in the lyrics view
/// 2. We send the lyrics text to the translation API
/// 3. API returns translated text
/// 4. We display the translated lyrics (or toggle between original/translated)
///
/// LIMITATIONS:
/// - Free API has daily character limits
/// - Song lyrics may not translate perfectly (poetic language, slang)
/// - Synced timestamps are preserved (we translate text, not timing)
///
/// WHAT IS "ObservableObject"?
/// A SwiftUI/Combine protocol. Conforming to it lets views "observe" this
/// object and auto-refresh whenever an `@Published` property changes, with
/// no manual UI-refresh code needed.
class LyricsTranslator: ObservableObject {

    // MARK: - Published Properties

    /// Whether a translation is currently in progress.
    /// `@Published` (a property wrapper, an annotation that adds extra
    /// behavior to a stored property) automatically notifies any SwiftUI
    /// view reading this value so it can, for example, show a spinner.
    @Published var isTranslating = false

    /// The translated lyrics text (nil if not yet translated).
    /// It's an Optional (`String?`) because "no translation yet" is a
    /// distinct, valid state, not an empty string.
    @Published var translatedText: String?

    /// Error message if translation failed (nil when there is no error).
    @Published var errorMessage: String?
    
    // MARK: - Private Properties
    
    /// The base URL for the MyMemory translation API
    private let apiBase = "https://api.mymemory.translated.net/get"
    
    // MARK: - Public Methods
    
    /// Translate lyrics text to the target language.
    ///
    /// - Parameters:
    ///   - text: The lyrics text to translate
    ///   - from: Source language code (e.g. "en" for English)
    ///   - to: Target language code (e.g. "es" for Spanish, "ja" for Japanese)
    func translate(_ text: String, from sourceLang: String = "en", to targetLang: String) {
        // Don't translate if already translating or text is empty.
        // `guard` exits the function immediately if the condition after it
        // is false, it reads as "require this to be true, or bail out."
        // `.trimmingCharacters(in: .whitespacesAndNewlines)` strips leading/
        // trailing spaces and newlines so a string of just blank space
        // still counts as "empty."
        guard !isTranslating, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        // Reset published state to "in progress" before kicking off the
        // network call, so the UI can immediately show a loading spinner.
        isTranslating = true
        errorMessage = nil
        translatedText = nil

        // WHAT IS "Task"? Swift's structured-concurrency way to start new
        // asynchronous work from ordinary (non-async) code. `translate(...)`
        // itself is a normal synchronous function, but network calls must
        // be `async`, so we wrap the async work in a `Task { ... }` block,
        // which runs concurrently and lets `translate` return immediately.
        Task {
            do {
                // `await` suspends this Task (without blocking any thread)
                // until the network call finishes.
                let translated = try await translateText(text, from: sourceLang, to: targetLang)
                await applyTranslationResult(.success(translated))
            } catch {
                await applyTranslationResult(.failure(error))
            }
        }
    }

    /// Apply the outcome of a translation attempt to the published
    /// properties. Pulled out of `translate` so the success/failure UI
    /// update logic lives in one small, single-purpose place.
    ///
    /// WHAT IS "MainActor.run"? Our `@Published` properties are read by
    /// SwiftUI on the main thread, but this method may be called from a
    /// background context after an `await`. `MainActor.run` hops back onto
    /// the main thread (actor isolation, a Swift mechanism that confines a
    /// piece of state to one specific thread/context to avoid data races)
    /// before touching them.
    private func applyTranslationResult(_ result: Result<String, Error>) async {
        await MainActor.run {
            switch result {
            case .success(let translated):
                self.translatedText = translated
            case .failure(let error):
                self.errorMessage = "Translation failed: \(error.localizedDescription)"
            }
            self.isTranslating = false
        }
    }
    
    /// Translate synced lyrics (preserving line structure).
    ///
    /// - Parameters:
    ///   - lines: Array of synced lyric lines with timestamps
    ///   - from: Source language code
    ///   - to: Target language code
    /// - Returns: Array of translated lines with same timestamps
    func translateSyncedLines(
        _ lines: [SyncedLine],
        from sourceLang: String = "en",
        to targetLang: String
    ) async -> [SyncedLine] {
        // Combine all line texts into one string (separated by newlines).
        // This is more efficient than translating each line individually,
        // one network request instead of dozens.
        // `lines.map(\.text)` extracts just the `text` field from every
        // SyncedLine (this `\.text` syntax is a "key path", a shorthand
        // way to say "for each element, read its .text property").
        let combinedText = lines.map(\.text).joined(separator: "\n")

        do {
            let translated = try await translateText(combinedText, from: sourceLang, to: targetLang)
            return pairTranslatedLines(translated, with: lines)
        } catch {
            // On error, return the original lines unchanged so the lyrics
            // view still has something to display instead of going blank.
            print("Translation failed: \(error)")
            return lines
        }
    }

    /// Re-pair a block of translated text (one line per original lyric
    /// line, separated by "\n") with the original lines' timestamps.
    ///
    /// Pulled out of `translateSyncedLines` because "call the API" and
    /// "reassemble the result" are two distinct responsibilities.
    ///
    /// - Parameters:
    ///   - translatedText: The API's translated text, still newline-joined.
    ///   - originalLines: The original synced lines (for their timestamps).
    /// - Returns: New SyncedLine values with translated text but original timing.
    private func pairTranslatedLines(_ translatedText: String, with originalLines: [SyncedLine]) -> [SyncedLine] {
        // Split the translated text back into individual lines.
        let translatedLines = translatedText.components(separatedBy: "\n")

        // `enumerated()` pairs each element with its index (0, 1, 2, ...)
        // so we can look up the matching translated line by position.
        // If the translation API returns fewer lines than we sent (it
        // sometimes merges short lines), we fall back to the original text
        // for any line past the end, rather than crashing on an
        // out-of-bounds index.
        return originalLines.enumerated().map { index, line in
            let text = index < translatedLines.count ? translatedLines[index] : line.text
            return SyncedLine(time: line.time, text: text)
        }
    }
    
    /// Clear the current translation.
    func clearTranslation() {
        translatedText = nil
        errorMessage = nil
    }
    
    // MARK: - Private Methods
    
    /// Call the MyMemory translation API.
    ///
    /// - Parameters:
    ///   - text: Text to translate
    ///   - from: Source language code (e.g. "en")
    ///   - to: Target language code (e.g. "es")
    /// - Returns: Translated text string
    private func translateText(_ text: String, from sourceLang: String, to targetLang: String) async throws -> String {
        let url = try buildTranslationURL(text: text, sourceLang: sourceLang, targetLang: targetLang)
        let data = try await fetchTranslationData(from: url)
        return try decodeTranslatedText(from: data)
    }

    /// Build the MyMemory API request URL for a given piece of text.
    /// Split out so URL construction (which can fail) is testable and
    /// readable on its own, separate from the network call.
    private func buildTranslationURL(text: String, sourceLang: String, targetLang: String) throws -> URL {
        // URL-encode the text for the query parameter. Percent-encoding
        // replaces characters that aren't safe in a URL (spaces, "&", "?",
        // accented letters, etc.) with a "%XX" escape sequence so the URL
        // stays valid no matter what the lyrics contain.
        guard let encodedText = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            throw TranslationError.encodingFailed
        }

        // Build the full URL with query parameters using Swift string
        // interpolation (`\(...)` splices a value into the string).
        let urlString = "\(apiBase)?q=\(encodedText)&langpair=\(sourceLang)|\(targetLang)"

        guard let url = URL(string: urlString) else {
            throw TranslationError.invalidURL
        }
        return url
    }

    /// Perform the actual network request and return the raw response body.
    ///
    /// WHAT IS "URLSession"? It's iOS's built-in HTTP client, the object
    /// responsible for actually sending requests over the network and
    /// receiving responses. `.shared` is a ready-to-use default instance
    /// suitable for simple one-off requests like this.
    /// `data(from:)` is an `async` function: it suspends this function
    /// (without blocking a thread) until the server responds, then hands
    /// back the raw bytes (`data`) and metadata about the HTTP response
    /// (`response`).
    private func fetchTranslationData(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)

        // `response` is typed generically as `URLResponse`; `as?` attempts
        // to downcast it to the more specific `HTTPURLResponse`, which
        // exposes `statusCode` (200 = success, 4xx/5xx = error). The cast
        // returns nil (and we throw) if this somehow wasn't an HTTP response.
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw TranslationError.apiError
        }
        return data
    }

    /// Decode the API's JSON response and extract the translated string.
    ///
    /// WHAT IS "Codable"/"JSONDecoder"? `Codable` is a protocol that lets
    /// Swift automatically convert between JSON and Swift structs
    /// (`TranslationResponse`/`TranslationData` below are declared
    /// `Codable`). `JSONDecoder().decode(_:from:)` reads the raw JSON bytes
    /// and builds a `TranslationResponse` value from them, matching field
    /// names to JSON keys automatically.
    private func decodeTranslatedText(from data: Data) throws -> String {
        let result = try JSONDecoder().decode(TranslationResponse.self, from: data)

        // The API can return HTTP 200 but still signal failure inside the
        // JSON body (responseStatus != 200), or omit the translated text
        // entirely, both are treated as "no usable result."
        guard result.responseStatus == 200,
              let translatedText = result.responseData?.translatedText else {
            throw TranslationError.noResult
        }

        return translatedText
    }
    
    // MARK: - Supported Languages
    
    /// Available target languages for translation.
    /// Each entry is (language code, display name).
    static let supportedLanguages: [(code: String, name: String, flag: String)] = [
        ("en", "English", "🇺🇸"),
        ("es", "Spanish", "🇪🇸"),
        ("fr", "French", "🇫🇷"),
        ("de", "German", "🇩🇪"),
        ("it", "Italian", "🇮🇹"),
        ("pt", "Portuguese", "🇧🇷"),
        ("ja", "Japanese", "🇯🇵"),
        ("ko", "Korean", "🇰🇷"),
        ("zh", "Chinese", "🇨🇳"),
        ("ru", "Russian", "🇷🇺"),
        ("ar", "Arabic", "🇸🇦"),
        ("hi", "Hindi", "🇮🇳"),
        ("tr", "Turkish", "🇹🇷"),
        ("nl", "Dutch", "🇳🇱"),
        ("sv", "Swedish", "🇸🇪")
    ]
}

// MARK: - API Response Models

/// Response from the MyMemory translation API.
///
/// These two structs mirror the JSON shape MyMemory sends back, e.g.:
/// `{"responseData": {"translatedText": "...", "match": 0.9}, "responseStatus": 200}`
/// Conforming to `Codable` means `JSONDecoder` can build one of these
/// automatically from raw JSON bytes, we don't have to parse it by hand.
struct TranslationResponse: Codable {
    let responseData: TranslationData?
    let responseStatus: Int
}

/// The actual translation data nested inside the API response.
struct TranslationData: Codable {
    let translatedText: String
    let match: Double?
}

// MARK: - Translation Errors

/// Errors that can occur during translation.
///
/// WHAT IS "Error, LocalizedError"? `Error` is the base protocol any Swift
/// error type must conform to so it can be `throw`n and `catch`n. Using an
/// `enum` here lists every failure mode this code can produce as a fixed,
/// exhaustive set of cases (as opposed to a generic/untyped error).
/// `LocalizedError` adds the `errorDescription` property below, which is
/// what `error.localizedDescription` (used in `applyTranslationResult`
/// above) actually reads to build a human-readable message for the UI.
enum TranslationError: Error, LocalizedError {
    case encodingFailed
    case invalidURL
    case apiError
    case noResult

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode text for translation"
        case .invalidURL:
            return "Invalid translation URL"
        case .apiError:
            return "Translation API returned an error"
        case .noResult:
            return "No translation result returned"
        }
    }
}
