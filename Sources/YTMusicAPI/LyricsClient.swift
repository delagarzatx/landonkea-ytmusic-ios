import Foundation

/// Client for fetching song lyrics, trying multiple free/no-auth providers
/// in sequence.
///
/// PROVIDER CHAIN:
/// 1. lrclib.net, tried first. Free, no auth, and the only one of the two
///    that can return SYNCED (timestamped) lyrics for karaoke-style
///    highlighting, so it's strictly preferred when it has the song.
///    - `GET /api/get?track_name=X&artist_name=Y`, exact match lookup
///    - `GET /api/search?q=X`, fuzzy search (used as a fallback within
///      lrclib itself, before we ever fall through to provider #2)
/// 2. lyrics.ovh, tried only if lrclib has nothing at all (404s or
///    returns no lyrics for both the exact-match and search lookups).
///    Also free and no auth, but plain-text only, no timestamps, so
///    songs resolved through this path never get karaoke highlighting.
///    Still strictly better than showing nothing.
///    - `GET /v1/{artist}/{title}`
///
/// Both providers require NO LOGIN, everything here works anonymously.
class LyricsClient {

    // MARK: - Properties

    /// Base URL for the lrclib.net API (primary provider, supports synced lyrics).
    private let baseURL = "https://lrclib.net/api"

    /// Base URL for the lyrics.ovh API (fallback provider, plain text only).
    private let fallbackBaseURL = "https://api.lyrics.ovh/v1"

    /// URL session for making HTTP requests
    private let session: URLSession

    // MARK: - Initialization

    /// Create a new lyrics client.
    ///
    /// - Parameter session: URL session to use (for testing, pass a mock).
    ///   Defaults to `NetworkCache.session` so repeated lyrics lookups for
    ///   the same track/artist are served from disk instead of re-hitting
    ///   the lyrics providers, lyrics are GET requests and effectively
    ///   immutable for a given track, unlike InnerTube's POST-only API
    ///   responses. See NetworkCache.swift for details.
    init(session: URLSession = NetworkCache.session) {
        self.session = session
    }

    // MARK: - Public Methods

    /// Fetch lyrics for a song by track name and artist, trying each
    /// provider in the chain until one returns something usable.
    ///
    /// Order: lrclib exact match -> lrclib search -> lyrics.ovh. Each step
    /// only runs if the previous one came back empty (404, no lyrics field,
    /// decode failure, or a network error), this is a genuine fallback
    /// chain, not a replacement of one provider by another, so lrclib's
    /// synced lyrics are still preferred whenever it has the song.
    ///
    /// - Parameters:
    ///   - trackName: Song title (e.g. "Bohemian Rhapsody")
    ///   - artistName: Artist name (e.g. "Queen")
    /// - Returns: Lyrics data with plain and/or synced lyrics, or nil if no
    ///   provider had anything for this song.
    func fetchLyrics(trackName: String, artistName: String) async -> Lyrics? {
        // Step 1: Try exact match on lrclib (faster, more accurate, and the
        // only path that can yield synced lyrics).
        if let lyrics = await fetchExactMatch(trackName: trackName, artistName: artistName) {
            return lyrics
        }

        // Step 2: Fall back to lrclib's fuzzy search (handles slight name
        // differences within the same provider).
        if let lyrics = await searchLyrics(query: "\(trackName) \(artistName)") {
            return lyrics
        }

        // Step 3: lrclib had nothing at all, try the fallback provider.
        // Plain text only (no timestamps), but better than showing nothing.
        return await fetchFromFallbackProvider(trackName: trackName, artistName: artistName)
    }

    // MARK: - Private Methods
    
    /// Try to get an exact match for the song.
    ///
    /// Uses the `/api/get` endpoint which returns a single result
    /// if the track name and artist match exactly.
    private func fetchExactMatch(trackName: String, artistName: String) async -> Lyrics? {
        // Build the URL with query parameters
        // `.addingPercentEncoding` converts spaces to %20 for valid URLs
        guard let trackEncoded = trackName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let artistEncoded = artistName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        
        let urlString = "\(baseURL)/get?track_name=\(trackEncoded)&artist_name=\(artistEncoded)"
        
        guard let url = URL(string: urlString) else { return nil }
        
        do {
            let (data, response) = try await session.data(from: url)
            
            // Check for HTTP errors (404 = not found, which is expected for some songs)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }
            
            // Decode the response
            let lrclibResponse = try JSONDecoder().decode(LrclibResponse.self, from: data)
            return lrclibResponse.toLyrics()
        } catch {
            print("Lyrics exact match failed: \(error)")
            return nil
        }
    }
    
    /// Search for lyrics using a query string.
    ///
    /// Uses the `/api/search` endpoint which returns multiple results.
    /// We take the first result as the best match.
    private func searchLyrics(query: String) async -> Lyrics? {
        guard let queryEncoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else {
            return nil
        }
        
        let urlString = "\(baseURL)/search?q=\(queryEncoded)"
        
        guard let url = URL(string: urlString) else { return nil }
        
        do {
            let (data, response) = try await session.data(from: url)
            
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }
            
            // Search returns an array of results, take the first one
            let results = try JSONDecoder().decode([LrclibResponse].self, from: data)
            return results.first?.toLyrics()
        } catch {
            print("Lyrics search failed: \(error)")
            return nil
        }
    }

    /// Fall back to lyrics.ovh when lrclib has nothing for this song.
    ///
    /// lyrics.ovh's API is a single, simple GET endpoint, no exact-match
    /// vs. search distinction like lrclib, just `/v1/{artist}/{title}`,
    /// and it only ever returns plain text, never timestamps. That means
    /// a song resolved through this path shows lyrics but never gets
    /// karaoke-style line highlighting; `Lyrics.hasSyncedLyrics` will be
    /// `false` for it, which `LyricsView` already handles by falling back
    /// to a plain scrolling view.
    private func fetchFromFallbackProvider(trackName: String, artistName: String) async -> Lyrics? {
        // lyrics.ovh takes artist/title as raw PATH components (not query
        // params), so `/` and other path-breaking characters need
        // percent-encoding via `.urlPathAllowed` rather than `.urlQueryAllowed`.
        guard let artistEncoded = artistName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let trackEncoded = trackName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }

        let urlString = "\(fallbackBaseURL)/\(artistEncoded)/\(trackEncoded)"
        guard let url = URL(string: urlString) else { return nil }

        do {
            let (data, response) = try await session.data(from: url)

            // lyrics.ovh returns 404 for songs it doesn't have, same as
            // lrclib, that's an expected "not found," not an error to log.
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            let ovhResponse = try JSONDecoder().decode(LyricsOvhResponse.self, from: data)
            return ovhResponse.toLyrics(trackName: trackName, artistName: artistName)
        } catch {
            print("Lyrics fallback provider (lyrics.ovh) failed: \(error)")
            return nil
        }
    }
}

// MARK: - lyrics.ovh Response Model

/// The JSON response from lyrics.ovh's API: `{"lyrics": "..."}`.
///
/// lyrics.ovh doesn't echo back the track/artist name or offer any synced
/// timing, so `toLyrics(trackName:artistName:)` takes those from the
/// caller's original request instead (unlike `LrclibResponse`, which gets
/// them from the response body).
struct LyricsOvhResponse: Codable {
    let lyrics: String?

    /// Convert to our app's Lyrics model. Returns nil if the response has
    /// no usable lyrics text (an empty string shows up for some songs that
    /// technically 200'd but have nothing indexed).
    func toLyrics(trackName: String, artistName: String) -> Lyrics? {
        guard let plainText = lyrics?.trimmingCharacters(in: .whitespacesAndNewlines),
              !plainText.isEmpty else {
            return nil
        }

        return Lyrics(
            trackName: trackName,
            artistName: artistName,
            plainText: plainText,
            // lyrics.ovh never provides timestamps, this provider is a
            // plain-text-only fallback by design.
            syncedLines: nil
        )
    }
}

// MARK: - lrclib.net Response Models

/// The JSON response from lrclib.net's API.
///
/// Fields:
/// - `trackName`: Song title
/// - `artistName`: Artist name
/// - `plainLyrics`: Full lyrics as plain text (newlines between lines)
/// - `syncedLyrics`: Lyrics with timestamps in `[MM:SS.xx]` format (optional)
struct LrclibResponse: Codable {
    let trackName: String?
    let artistName: String?
    let plainLyrics: String?
    let syncedLyrics: String?
    
    /// Convert to our app's Lyrics model.
    ///
    /// Returns nil if there are no lyrics at all (both plain and synced are nil/empty).
    func toLyrics() -> Lyrics? {
        // Need at least plain lyrics to be useful
        guard let plainText = plainLyrics, !plainText.isEmpty else {
            return nil
        }
        
        // Parse synced lyrics if available
        let syncedLines = syncedLyrics.flatMap { parseSyncedLyrics($0) }
        
        return Lyrics(
            trackName: trackName ?? "Unknown",
            artistName: artistName ?? "Unknown",
            plainText: plainText,
            syncedLines: syncedLines
        )
    }
    
    /// The regex pattern that matches one synced-lyrics line, e.g.
    /// `"[00:25.29] I'm just a poor boy"`.
    ///
    /// Regex explanation (a "regular expression" is a mini pattern-matching
    /// language for finding/extracting pieces of text):
    /// \[        = literal opening bracket
    /// (\d{2})   = 2 digits for minutes (captured, "captured" means this
    ///             piece gets remembered so we can pull it out afterward)
    /// :         = literal colon
    /// (\d{2})   = 2 digits for seconds (captured)
    /// \.(\d+)   = dot followed by digits for milliseconds (captured)
    /// \]        = literal closing bracket
    /// (.*)      = the rest of the line (the lyrics text, captured)
    ///
    /// This is declared once as a `static let` (shared by all instances,
    /// computed only the first time it's needed) instead of being rebuilt
    /// inside the per-line loop below, compiling a regex pattern has a
    /// real cost, and re-doing it for every single lyric line would be
    /// wasteful when the pattern never changes.
    private static let syncedLinePattern = try? NSRegularExpression(
        pattern: #"\[(\d{2}):(\d{2})\.(\d+)\](.*)"#
    )

    /// Parse synced lyrics from the `[MM:SS.xx] line text` format.
    ///
    /// Splits the raw multi-line string into individual lines, then hands
    /// each one to `parseSyncedLine(_:)` to do the actual pattern matching.
    /// Keeping the "loop over lines" logic separate from the "parse one
    /// line" logic makes each function easier to read and test on its own.
    ///
    /// Returns nil if no lines could be parsed (e.g. if the format is
    /// completely unexpected).
    private func parseSyncedLyrics(_ text: String) -> [SyncedLine]? {
        // `compactMap` transforms each element and drops any nil results,
        // exactly what we want here, since parseSyncedLine returns nil for
        // lines that don't match the expected timestamp format.
        let lines = text
            .components(separatedBy: .newlines)
            .compactMap { parseSyncedLine($0) }

        return lines.isEmpty ? nil : lines
    }

    /// Parse a single line of synced lyrics, e.g. `"[00:25.29] I'm just a poor boy"`.
    ///
    /// - Returns: A `SyncedLine` with the timestamp converted to seconds,
    ///   or nil if this line doesn't match the expected format (blank line,
    ///   header line, malformed timestamp, etc.).
    private func parseSyncedLine(_ rawLine: String) -> SyncedLine? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Run the shared regex against this one line. `NSRange(trimmed.startIndex..., in: trimmed)`
        // converts Swift's native String range into the legacy NSString-style
        // range that NSRegularExpression (an Objective-C-based API) expects.
        guard let regex = Self.syncedLinePattern,
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) else {
            return nil
        }

        // Pull out the 4 captured groups (minutes, seconds, milliseconds, text).
        // `match.range(at:)` gives an NSRange; `Range(_:in:)` converts that
        // back into a Swift String range so we can subscript `trimmed` with it.
        guard let minutesRange = Range(match.range(at: 1), in: trimmed),
              let secondsRange = Range(match.range(at: 2), in: trimmed),
              let msRange = Range(match.range(at: 3), in: trimmed),
              let textRange = Range(match.range(at: 4), in: trimmed) else {
            return nil
        }

        let minutes = Double(trimmed[minutesRange]) ?? 0
        let seconds = Double(trimmed[secondsRange]) ?? 0
        let milliseconds = Double(trimmed[msRange]) ?? 0

        // Calculate total seconds: minutes×60 + seconds + milliseconds/1000.
        // The milliseconds group can be 2 or 3 digits (".29" vs ".290"), so
        // we divide by 10^(digit count) rather than a fixed 1000 to scale
        // it correctly either way.
        let time = minutes * 60 + seconds + milliseconds / pow(10, Double(trimmed[msRange].count))

        let lineText = String(trimmed[textRange]).trimmingCharacters(in: .whitespaces)

        // Skip empty lines (instrumental breaks have a timestamp but no text)
        guard !lineText.isEmpty else { return nil }

        return SyncedLine(time: time, text: lineText)
    }
}

// MARK: - Lyrics Models

/// Lyrics data for a song.
///
/// Contains both plain text lyrics (always available if the song has lyrics)
/// and optionally synced (timestamped) lyrics for karaoke-style display.
struct Lyrics {
    /// Song title (from the lyrics API, may differ slightly from YouTube's title)
    let trackName: String
    /// Artist name (from the lyrics API)
    let artistName: String
    /// Full lyrics as plain text, with newlines between lines
    let plainText: String
    /// Synced lyrics with timestamps (nil if not available)
    /// When available, allows karaoke-style highlighting that follows playback
    let syncedLines: [SyncedLine]?
    
    /// Whether synced (timestamped) lyrics are available
    var hasSyncedLyrics: Bool {
        return syncedLines != nil && !(syncedLines?.isEmpty ?? true)
    }
}

/// A single line of synced lyrics with a timestamp.
///
/// The timestamp indicates when this line should be highlighted
/// during playback (karaoke-style).
struct SyncedLine {
    /// When this line starts, in seconds (e.g. 25.29 = 25 seconds and 290ms)
    let time: Double
    /// The lyrics text for this line
    let text: String
}
