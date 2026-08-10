import Foundation
import SwiftUI

// MARK: - Play Count Manager

/// Tracks how many times each song has been played and when it was last played.
///
/// WHAT THIS DOES:
/// Every time a song starts playing, we increment its play count and record
/// the timestamp. This data can be used to:
/// - Show "Most Played" section on the home screen
/// - Sort playlists by play count
/// - Show listening stats to the user
///
/// STORAGE:
/// Play counts are stored as a dictionary mapping video IDs to play counts.
/// Last played timestamps are stored separately. Both are persisted to JSON
/// files in the Documents directory.
///
/// HOW IT WORKS:
/// AudioPlayer calls recordPlay() whenever a new song starts playing.
/// The manager increments the count and saves to disk. Views can call
/// getPlayCount() or getMostPlayed() to display this data.
///
/// `class` vs `struct`: this is a `class` (a "reference type") rather than a
/// `struct` ("value type") because it needs to be shared, every part of the
/// app that holds a reference to this object sees the SAME data, and changes
/// made in one place are visible everywhere else. A `struct` would instead
/// get copied every time it's passed around, so different parts of the app
/// could end up with different, disconnected copies of the play counts.
///
/// `ObservableObject` is a SwiftUI protocol (a "contract" a type can agree to
/// follow). Conforming to it lets SwiftUI views watch this object and
/// automatically redraw themselves whenever a `@Published` property changes.
class PlayCountManager: ObservableObject {

    // MARK: - Static Reference

    /// Shared instance that AudioPlayer can access via PlayCountManager.shared.
    /// Set in YTMusicApp.init() after the PlayCountManager is created.
    ///
    /// This is a "singleton-style" reference: `static` means this property
    /// belongs to the `PlayCountManager` type itself rather than to any one
    /// instance, so there's exactly one `shared` value for the whole app to
    /// read. It's declared as an `Optional` (`PlayCountManager?`, i.e. it can
    /// be `nil`) because the real instance is created and owned by SwiftUI as
    /// a `@StateObject` in `YTMusicApp`, and only assigned here afterward,
    /// so callers must handle the brief window (and any misconfiguration)
    /// where it hasn't been set yet.
    static var shared: PlayCountManager?

    // MARK: - Published Properties

    /// Dictionary mapping video IDs to their play counts.
    /// Updated whenever a song is played.
    ///
    /// `@Published` is a SwiftUI "property wrapper", special syntax that
    /// wraps this property with extra behavior. Here, it automatically
    /// announces "this value changed!" to any SwiftUI view that's watching
    /// this object, so the UI can refresh itself. A `[String: Int]` is a
    /// dictionary, a lookup table of key/value pairs, here mapping a song's
    /// video ID (the key) to how many times it's been played (the value).
    @Published var playCounts: [String: Int] = [:]

    /// Dictionary mapping video IDs to their last played date.
    /// Used for "Recently Played" sorting and "Last Played" display.
    @Published var lastPlayedDates: [String: Date] = [:]

    // MARK: - Private Properties

    /// File paths for persisting play count data.
    /// `private` means only code inside this class can read these, outside
    /// code (like views) has no reason to know exactly where the files live.
    private let playCountsPath: URL
    private let lastPlayedPath: URL

    // MARK: - Initialization

    /// Create the play count manager and load saved data from disk.
    init() {
        // `FileManager` is Apple's API for working with the file system.
        // `.documentDirectory` in `.userDomainMask` is the app's private
        // "Documents" folder, a safe, sandboxed place to store files that
        // should survive app restarts (and get backed up by iCloud/iTunes).
        // The API returns an array of matching URLs; there's only ever one
        // for this combination, so we grab index `[0]`.
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.playCountsPath = documents.appendingPathComponent("play_counts.json")
        self.lastPlayedPath = documents.appendingPathComponent("last_played.json")

        loadPlayCounts()
        loadLastPlayedDates()
    }

    // MARK: - Public Methods

    /// Record that a song was played.
    ///
    /// Called by AudioPlayer when a new song starts playing.
    /// Increments the play count and updates the last played timestamp.
    ///
    /// - Parameter videoId: The YouTube video ID of the played song
    func recordPlay(videoId: String) {
        incrementPlayCount(for: videoId)
        updateLastPlayedDate(for: videoId)
        persistAll()
    }

    /// Get the play count for a specific song.
    ///
    /// - Parameter videoId: The YouTube video ID
    /// - Returns: Number of times the song was played (0 if never played)
    func getPlayCount(videoId: String) -> Int {
        // `playCounts[videoId]` looks up the value for that key and returns
        // an Optional (it might not exist yet). `?? 0` is the "nil-coalescing
        // operator", if the lookup found nothing (nil), fall back to 0.
        return playCounts[videoId] ?? 0
    }

    /// Get the last played date for a specific song.
    ///
    /// - Parameter videoId: The YouTube video ID
    /// - Returns: The date the song was last played, or nil if never played
    func getLastPlayedDate(videoId: String) -> Date? {
        return lastPlayedDates[videoId]
    }

    /// Get the top N most played songs.
    ///
    /// - Parameter limit: Maximum number of songs to return (default: 10)
    /// - Returns: Array of (videoId, playCount) tuples sorted by play count
    func getMostPlayed(limit: Int = 10) -> [(videoId: String, count: Int)] {
        // This chain reads like a pipeline, each step transforming the data:
        // 1. `sorted { ... }`, sort the dictionary's key/value pairs using
        //    a "closure" (an inline, unnamed function) that compares two
        //    entries' `.value` (play count) and puts bigger counts first.
        // 2. `.prefix(limit)`, take only the first `limit` entries.
        // 3. `.map { ... }`, convert each (key, value) pair into a named
        //    tuple `(videoId:, count:)` that's easier for callers to read.
        return playCounts
            .sorted { $0.value > $1.value } // Sort by count descending
            .prefix(limit) // Take top N
            .map { (videoId: $0.key, count: $0.value) }
    }

    /// Get the total number of songs that have been played.
    var totalSongsPlayed: Int {
        playCounts.count
    }

    /// Get the total number of plays across all songs.
    var totalPlays: Int {
        // `reduce(0, +)` walks the dictionary's values and folds them into a
        // single number by repeatedly applying `+` (addition), starting
        // from 0. It's a compact way of writing "sum everything up".
        playCounts.values.reduce(0, +)
    }

    // MARK: - Private Helpers

    /// Increments the stored play count for one song by 1.
    private func incrementPlayCount(for videoId: String) {
        // `playCounts[videoId, default: 0]` reads the current count, or 0 if
        // this song has never been played before, then `+= 1` adds one to it
        // and writes the result back into the dictionary, all in one line.
        playCounts[videoId, default: 0] += 1
    }

    /// Records "now" as the last played moment for one song.
    private func updateLastPlayedDate(for videoId: String) {
        lastPlayedDates[videoId] = Date()
    }

    /// Persists both play counts and last played dates to disk.
    /// Grouped into one helper so `recordPlay` doesn't need to know about
    /// two separate save calls.
    private func persistAll() {
        savePlayCounts()
        saveLastPlayedDates()
    }

    // MARK: - Persistence

    /// Save play counts to disk.
    private func savePlayCounts() {
        // `do`/`catch` is Swift's error-handling mechanism: code inside `do`
        // that's marked with `try` might "throw" an error, and if it does,
        // execution jumps straight to the matching `catch` block instead of
        // crashing the app.
        do {
            // `JSONEncoder` converts Swift values into JSON-formatted binary
            // `Data`. This only works for types that conform to `Codable`,
            // a protocol meaning "I know how to convert myself to and from
            // JSON (or similar formats)". `[String: Int]` already conforms
            // to `Codable` automatically because both `String` and `Int` do.
            let encoder = JSONEncoder()
            let data = try encoder.encode(playCounts)
            try data.write(to: playCountsPath)
        } catch {
            // We deliberately don't crash the app over a failed save,
            // losing play-count history is much less bad than a crash.
            print("Failed to save play counts: \(error)")
        }
    }

    /// Load play counts from disk.
    private func loadPlayCounts() {
        // `guard ... else { return }` checks a condition and exits the
        // function early if it's false. Here: if the file doesn't exist yet
        // (e.g. first launch), there's nothing to load, so just stop.
        guard FileManager.default.fileExists(atPath: playCountsPath.path) else { return }

        do {
            let data = try Data(contentsOf: playCountsPath)
            // `JSONDecoder` is the reverse of `JSONEncoder`: it turns JSON
            // `Data` back into a real Swift value of the requested type.
            playCounts = try JSONDecoder().decode([String: Int].self, from: data)
        } catch {
            print("Failed to load play counts: \(error)")
            playCounts = [:]
        }
    }

    /// Save last played dates to disk.
    private func saveLastPlayedDates() {
        do {
            let encoder = JSONEncoder()
            // `Date` doesn't have one single "correct" text representation,
            // so we must tell the encoder how to write it. `.iso8601` is a
            // widely-used, human-readable standard format (e.g.
            // "2026-08-02T10:00:00Z") that also round-trips exactly when we
            // decode it back later.
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(lastPlayedDates)
            try data.write(to: lastPlayedPath)
        } catch {
            print("Failed to save last played dates: \(error)")
        }
    }

    /// Load last played dates from disk.
    private func loadLastPlayedDates() {
        guard FileManager.default.fileExists(atPath: lastPlayedPath.path) else { return }

        do {
            let data = try Data(contentsOf: lastPlayedPath)
            let decoder = JSONDecoder()
            // Must match the `.iso8601` strategy used when saving, or dates
            // won't decode correctly.
            decoder.dateDecodingStrategy = .iso8601
            lastPlayedDates = try decoder.decode([String: Date].self, from: data)
        } catch {
            print("Failed to load last played dates: \(error)")
            lastPlayedDates = [:]
        }
    }
}
