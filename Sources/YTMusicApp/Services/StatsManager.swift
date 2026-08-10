import Foundation
import SwiftUI

// MARK: - Stats Manager

/// Tracks listening statistics, total time, top songs, daily streaks, etc.
///
/// HOW IT WORKS:
/// - Records a "listen session" every time a song is played
/// - Each session stores: videoId, title, artist, duration played, timestamp
/// - Aggregates are computed from the raw session data
///
/// DATA STORED:
/// - Total time listened (in seconds)
/// - Total songs played
/// - Most-played songs (by play count)
/// - Listening history (last 500 sessions)
///
/// PERSISTENCE:
/// - Stored as JSON in the Documents directory
/// - Capped at the most recent 500 sessions (see `trimToMaxSessions()`),
///   older sessions are dropped by count, not by age, to keep the saved
///   file small.
@MainActor
class StatsManager: ObservableObject {
    
    // MARK: - Types
    
    /// A single listen session, recorded when a song is played for >10 seconds.
    ///
    /// - `Codable` means Swift can automatically convert this struct to/from
    ///   JSON (used below to save/load sessions to a file).
    /// - `Identifiable` means it has a unique `id`, which SwiftUI lists use
    ///   to tell rows apart (e.g. in a "recently played" screen).
    struct ListenSession: Codable, Identifiable {
        // UUID = "Universally Unique Identifier", a randomly generated ID
        // that's essentially guaranteed not to collide with any other UUID
        // ever generated, so it's a safe stand-in for a database row ID.
        let id: UUID
        let videoId: String
        let title: String
        let artist: String
        let durationPlayed: Double  // seconds actually listened
        let timestamp: Date
        // Whether this session ended because the user skipped away rather
        // than the song finishing naturally. `= false` default means old,
        // already-saved sessions (recorded before this field existed) decode
        // fine without needing a migration, `Codable`'s synthesized decoder
        // treats a defaulted `var`/`let` as optional-if-missing as long as we
        // give it an explicit `init(from:)` below, since a plain default
        // value doesn't apply to JSON decoding automatically.
        let wasSkipped: Bool

        init(id: UUID, videoId: String, title: String, artist: String, durationPlayed: Double, timestamp: Date, wasSkipped: Bool = false) {
            self.id = id
            self.videoId = videoId
            self.title = title
            self.artist = artist
            self.durationPlayed = durationPlayed
            self.timestamp = timestamp
            self.wasSkipped = wasSkipped
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(UUID.self, forKey: .id)
            videoId = try container.decode(String.self, forKey: .videoId)
            title = try container.decode(String.self, forKey: .title)
            artist = try container.decode(String.self, forKey: .artist)
            durationPlayed = try container.decode(Double.self, forKey: .durationPlayed)
            timestamp = try container.decode(Date.self, forKey: .timestamp)
            // Sessions saved before skip-tracking existed simply won't have
            // this key, default to `false` (treat old data as "completed")
            // rather than failing to decode the whole history file.
            wasSkipped = try container.decodeIfPresent(Bool.self, forKey: .wasSkipped) ?? false
        }
    }

    // MARK: - Published Properties

    /// All recorded listen sessions (limited to last 500).
    @Published private(set) var sessions: [ListenSession] = []
    
    // MARK: - Computed Properties
    
    /// Total time listened in seconds.
    var totalTimeListened: TimeInterval {
        // `reduce` walks the array and combines every element into a single
        // value: starting from 0, it repeatedly adds each session's
        // `durationPlayed` to the running total ($0), producing one final sum.
        sessions.reduce(0) { $0 + $1.durationPlayed }
    }
    
    /// Total number of songs played.
    var totalSongsPlayed: Int {
        sessions.count
    }
    
    /// Average time listened per song in seconds.
    var averageListenTime: TimeInterval {
        guard !sessions.isEmpty else { return 0 }
        return totalTimeListened / Double(sessions.count)
    }

    /// Total number of sessions that ended in a skip rather than a natural finish.
    var totalSkips: Int {
        sessions.filter { $0.wasSkipped }.count
    }

    /// Fraction (0.0–1.0) of all recorded sessions that were skips.
    var skipRate: Double {
        guard !sessions.isEmpty else { return 0 }
        return Double(totalSkips) / Double(sessions.count)
    }
    
    /// Get the top N most played songs.
    ///
    /// HOW: builds a dictionary keyed by videoId that tallies how many times
    /// each song appears in `sessions`, then sorts that tally by count.
    /// A dictionary is used (rather than, say, filtering the array per song)
    /// so every session is only looked at once, an O(n) pass instead of
    /// O(n²) for large listening histories.
    func mostPlayedSongs(limit: Int = 20) -> [(videoId: String, title: String, artist: String, count: Int)] {
        // Each dictionary value bundles the song's display info alongside its
        // running play count, so we don't need a second lookup later to find
        // the title/artist that go with a given count.
        var counts: [String: (title: String, artist: String, count: Int)] = [:]

        for session in sessions {
            if var entry = counts[session.videoId] {
                // We've seen this song before, bump its count.
                // `var entry` makes a local mutable copy (dictionary values
                // are structs/tuples here, which are value types), so we have
                // to write it back into the dictionary explicitly below.
                entry.count += 1
                counts[session.videoId] = entry
            } else {
                // First time seeing this song, start its count at 1.
                counts[session.videoId] = (session.title, session.artist, 1)
            }
        }

        return counts
            .sorted { $0.value.count > $1.value.count } // Highest play count first
            .prefix(limit) // Keep only the top `limit` entries
            .map { (videoId: $0.key, title: $0.value.title, artist: $0.value.artist, count: $0.value.count) }
    }

    /// Top artists by listen count.
    ///
    /// Same aggregate-then-sort approach as `mostPlayedSongs`, but keyed by
    /// artist name instead of videoId, and the count is the only thing we
    /// need to track per artist (so a plain `Int` dictionary value is enough).
    func topArtists(limit: Int = 10) -> [(artist: String, count: Int)] {
        var counts: [String: Int] = [:]

        for session in sessions {
            // `default: 0` means: if `session.artist` isn't a key yet, treat
            // its current count as 0 before adding 1, avoids writing a
            // separate "if this is the first time" branch like above.
            counts[session.artist, default: 0] += 1
        }

        return counts
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (artist: $0.key, count: $0.value) }
    }
    
    // MARK: - Skip Signal (item #4: skip-tracking as a first-class signal)

    /// How many times this song's sessions ended in a skip (as opposed to
    /// playing through naturally).
    func skipCount(for videoId: String) -> Int {
        sessions.filter { $0.videoId == videoId && $0.wasSkipped }.count
    }

    /// Whether a song is skipped often enough that recommendation logic
    /// should down-weight or exclude it.
    ///
    /// HEURISTIC: needs at least 3 sessions to have an opinion (so one bad
    /// mood/one accidental skip doesn't blacklist a song), and skips at
    /// least 60% of the time it's played.
    func isFrequentlySkipped(videoId: String) -> Bool {
        let songSessions = sessions.filter { $0.videoId == videoId }
        guard songSessions.count >= 3 else { return false }
        let skipped = songSessions.filter { $0.wasSkipped }.count
        return Double(skipped) / Double(songSessions.count) >= 0.6
    }

    // MARK: - "On Repeat" / "Recently Discovered" (item #2)
    //
    // Both are different slices of the same `sessions` substrate as
    // `mostPlayedSongs`/`topArtists` above, no new data collection needed,
    // just a different lens on it. This is the "cheap to build once #3 is
    // done" payoff mentioned in the original research: because sessions now
    // include skipped plays too, these slices reflect genuine listening
    // behavior rather than only naturally-completed plays.

    /// Songs in "heavy rotation" recently, played (and NOT mostly skipped)
    /// several times within the last `withinDays` days.
    ///
    /// This is distinct from `mostPlayedSongs`, which is all-time and
    /// doesn't care about recency, a song played 40 times two years ago
    /// but never since would top `mostPlayedSongs` forever. `onRepeatSongs`
    /// only looks at recent behavior, so it reflects what's on repeat *now*.
    func onRepeatSongs(limit: Int = 20, withinDays: Int = 21, minPlays: Int = 3) -> [(videoId: String, title: String, artist: String, count: Int)] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -withinDays, to: Date()) ?? .distantPast
        let recent = sessions.filter { $0.timestamp >= cutoff && !$0.wasSkipped }

        var counts: [String: (title: String, artist: String, count: Int)] = [:]
        for session in recent {
            if var entry = counts[session.videoId] {
                entry.count += 1
                counts[session.videoId] = entry
            } else {
                counts[session.videoId] = (session.title, session.artist, 1)
            }
        }

        return counts
            .filter { $0.value.count >= minPlays }
            .sorted { $0.value.count > $1.value.count }
            .prefix(limit)
            .map { (videoId: $0.key, title: $0.value.title, artist: $0.value.artist, count: $0.value.count) }
    }

    /// Songs the user started listening to for the first time recently,
    /// i.e. their earliest recorded session falls within `withinDays` days.
    ///
    /// Sorted newest-discovery-first. Songs the user has since skipped every
    /// time are excluded, a song someone tried once and bailed on isn't a
    /// "discovery" worth resurfacing.
    func recentlyDiscoveredSongs(limit: Int = 20, withinDays: Int = 14) -> [(videoId: String, title: String, artist: String, firstPlayed: Date)] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -withinDays, to: Date()) ?? .distantPast

        // Earliest session per videoId (sessions are appended in
        // chronological order, so the first match walking forward is the
        // earliest, but we sort defensively rather than relying on that).
        var earliestByVideo: [String: ListenSession] = [:]
        for session in sessions {
            if let existing = earliestByVideo[session.videoId] {
                if session.timestamp < existing.timestamp {
                    earliestByVideo[session.videoId] = session
                }
            } else {
                earliestByVideo[session.videoId] = session
            }
        }

        return earliestByVideo.values
            .filter { $0.timestamp >= cutoff && !isFrequentlySkipped(videoId: $0.videoId) }
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(limit)
            .map { (videoId: $0.videoId, title: $0.title, artist: $0.artist, firstPlayed: $0.timestamp) }
    }

    /// Human-readable total listening time (e.g. "12h 34m").
    var formattedTotalTime: String {
        let totalSeconds = Int(totalTimeListened)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
    
    // MARK: - Private Properties
    
    /// File URL for the sessions JSON.
    private let fileURL: URL
    
    // MARK: - Initialization
    
    init() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = documents.appendingPathComponent("listen_sessions.json")
        load()

        // NotificationCenter is a system-wide message bus: any object can
        // "post" a named notification, and any object can "observe" (listen
        // for) it without the two knowing about each other directly. This is
        // how AudioPlayer tells StatsManager "a song just finished" without
        // AudioPlayer needing to hold a reference to StatsManager at all.
        //
        // `selector:` points at the method to call when the notification
        // fires, `#selector(songDidFinish(_:))` refers to the `@objc` method
        // below. `@objc` is required here because this old-style
        // target/selector API comes from Objective-C and needs the method to
        // be visible to the Objective-C runtime.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(songDidFinish(_:)),
            name: .songDidFinishPlaying,
            object: nil
        )
    }

    deinit {
        // NotificationCenter keeps a reference to `self` as long as it's
        // registered as an observer. Removing it here ensures that reference
        // is dropped and that this object doesn't keep receiving
        // notifications (which would crash, since `self` would already be
        // deallocated) after it goes away.
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Notification Handler

    /// Called whenever a listen session ends, either the song finished
    /// naturally OR the user skipped away from it partway through.
    ///
    /// RECONCILIATION NOTE: this used to only fire on natural completion, so
    /// StatsManager never learned about songs the user skipped, silently
    /// biasing "most played"/recommendation data toward whatever happened to
    /// autoplay to the end. AudioPlayer now reports every session exactly
    /// once (see `finalizeCurrentSession` there), skipped or not, with the
    /// real elapsed listening time.
    @objc private func songDidFinish(_ notification: Notification) {
        // Notifications carry an optional, untyped `userInfo` dictionary,
        // the poster (AudioPlayer) packs values into it as `[String: Any]`,
        // and we have to unpack and type-check each one here. The single
        // `guard ... else { return }` bails out silently if any expected key
        // is missing or the wrong type, which shouldn't normally happen but
        // protects us from a crash if the posting side ever changes.
        guard let userInfo = notification.userInfo,
              let videoId = userInfo["videoId"] as? String,
              let title = userInfo["title"] as? String,
              let artist = userInfo["artist"] as? String,
              let durationPlayed = userInfo["durationPlayed"] as? Double else {
            return
        }
        let wasSkipped = userInfo["wasSkipped"] as? Bool ?? false

        recordPlay(videoId: videoId, title: title, artist: artist, durationPlayed: durationPlayed, wasSkipped: wasSkipped)
    }

    // MARK: - Recording

    /// Record a listen session.
    ///
    /// Only records if the song was played for at least 10 seconds (filters
    /// out accidental taps), this threshold now also applies to skips, so a
    /// song tapped and immediately skipped after 2 seconds still isn't
    /// counted as a "listen" (though it's still visible via `.songWasSkipped`
    /// to any future skip-specific consumer that wants finer granularity).
    func recordPlay(videoId: String, title: String, artist: String, durationPlayed: Double, wasSkipped: Bool = false) {
        guard durationPlayed >= 10 else { return }

        let session = ListenSession(
            id: UUID(),
            videoId: videoId,
            title: title,
            artist: artist,
            durationPlayed: durationPlayed,
            timestamp: Date(),
            wasSkipped: wasSkipped
        )

        sessions.append(session)
        trimToMaxSessions()
        save()
    }

    /// Cap `sessions` at the last 500 entries so the history file doesn't
    /// grow without bound. Pulled out of `recordPlay` so each method does
    /// exactly one thing: `recordPlay` records, this trims.
    private func trimToMaxSessions() {
        let maxSessions = 500
        guard sessions.count > maxSessions else { return }
        // `.suffix(500)` keeps the most recent 500 (sessions are appended in
        // chronological order, so the tail of the array is the newest).
        sessions = Array(sessions.suffix(maxSessions))
    }
    
    // MARK: - Persistence
    
    /// Save sessions to disk.
    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(sessions)
            try data.write(to: fileURL)
        } catch {
            print("Failed to save listen sessions: \(error)")
        }
    }
    
    /// Load sessions from disk.
    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            sessions = try decoder.decode([ListenSession].self, from: data)
        } catch {
            print("Failed to load listen sessions: \(error)")
        }
    }
}
