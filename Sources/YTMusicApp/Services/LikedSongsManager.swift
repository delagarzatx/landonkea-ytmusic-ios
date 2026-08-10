import Foundation
import SwiftUI

extension Notification.Name {
    /// Posted whenever `LikedSongsManager.save()` runs (like, unlike, or a
    /// CloudKit merge applying remote changes). CloudKitSyncManager
    /// observes this to trigger a debounced push; see YTMusicApp.swift.
    static let likedSongsDidChange = Notification.Name("likedSongsDidChange")
}

// MARK: - Liked Songs Manager

/// Manages the user's liked songs locally.
///
/// HOW IT WORKS:
/// - Stores liked song video IDs in UserDefaults as a Set<String>
/// - Persists on device (no account needed)
/// - Views check `isLiked(videoId:)` to show heart/filled heart icons
///
/// LIMITATIONS:
/// - Liked songs are LOCAL only, they don't sync with YouTube Music
/// - If the user logs into YouTube Music in the future, we'd need to
///   change this to use the API's `like/like` and `like/removelike` endpoints
///
/// WHAT IS "@MainActor"?
/// This is a concurrency annotation (a rule about which thread code runs on)
/// that pins every method and property of this class to the app's main
/// thread, the same thread that draws the UI. It's required here because
/// this class is an `ObservableObject` whose `@Published` property is read
/// directly by SwiftUI views, and UI updates must always happen on the main
/// thread. Marking the whole class `@MainActor` means the compiler checks
/// this for us and stops us from accidentally calling these methods from a
/// background thread.
@MainActor
class LikedSongsManager: ObservableObject {

    // MARK: - Properties

    /// Set of liked song video IDs.
    ///
    /// WHAT IS A "Set"? Unlike an Array, a Set stores each value at most
    /// once (no duplicates) and has no particular order. That's a good fit
    /// here because "is this song liked" is a yes/no membership question,
    /// we never need duplicates or ordering, and `Set.contains` is much
    /// faster than searching through an Array.
    ///
    /// `@Published` (see EqualizerManager.swift for a fuller explanation)
    /// makes SwiftUI views re-render whenever this changes. `private(set)`
    /// means code outside this class can READ `likedIds` but can't assign
    /// to it directly, all writes must go through the methods below, so
    /// every change is guaranteed to also call `save()`.
    @Published private(set) var likedIds: Set<String> = []

    /// When each currently-liked song was liked, keyed by video ID. This
    /// exists alongside `likedIds` purely to support CloudKit sync's
    /// conflict resolution (see `LikedSongConflictResolver` in
    /// CloudKitSyncManager.swift), a plain Set has no way to tell which of
    /// two devices' "liked" state is newer when merging, so each like is
    /// timestamped. `likedIds` remains the source of truth every existing
    /// view reads from; this dict is sync-only bookkeeping.
    private var likedTimestamps: [String: Date] = [:]

    /// Shared instance so AudioPlayer can read/toggle like state from the
    /// lock screen / Control Center "like" and "dislike" buttons, which
    /// only have access to AudioPlayer's MPRemoteCommandCenter handlers,
    /// not the SwiftUI environment. Mirrors the PlayCountManager.shared /
    /// EqualizerManager.shared pattern used elsewhere in the app.
    static var shared: LikedSongsManager?

    /// The key under which we store the liked IDs in UserDefaults.
    /// UserDefaults is a simple built-in key-value store iOS provides for
    /// small pieces of app data (settings, preferences) that should persist
    /// between app launches without needing a full database.
    private let defaultsKey = "likedSongIds"

    /// Key for the parallel `likedTimestamps` dict (stored as
    /// `[String: TimeInterval]`, UserDefaults' property-list storage
    /// doesn't support `Date` values directly inside a dictionary the way
    /// `stringArray(forKey:)` supports arrays of `String`, so timestamps
    /// are stored as `timeIntervalSince1970` doubles instead).
    private let timestampsDefaultsKey = "likedSongTimestamps"

    // MARK: - Initialization

    init() {
        // Populate `likedIds` from disk as soon as the manager is created,
        // so the UI shows the correct heart icons immediately on launch.
        load()
    }

    // MARK: - Public Methods

    /// Toggle like status for a song: likes it if currently unliked, and
    /// vice versa.
    ///
    /// `@discardableResult` tells the compiler not to warn callers who
    /// ignore the return value (e.g. a plain "heart tap" that doesn't care
    /// about the new state, versus code that wants to know whether the song
    /// ended up liked or not).
    ///
    /// - Returns: The new state (true = liked, false = unliked).
    @discardableResult
    func toggle(_ videoId: String) -> Bool {
        // Delegate to `like`/`unlike` so there's only one place that
        // actually mutates `likedIds` and saves, keeps this function
        // focused purely on "which direction do we flip."
        if isLiked(videoId) {
            unlike(videoId)
            return false
        } else {
            like(videoId)
            return true
        }
    }

    /// Like a specific song (adds its video ID to the set and persists).
    func like(_ videoId: String) {
        likedIds.insert(videoId)
        likedTimestamps[videoId] = Date()
        save()
    }

    /// Unlike a specific song (removes its video ID from the set and persists).
    func unlike(_ videoId: String) {
        likedIds.remove(videoId)
        likedTimestamps.removeValue(forKey: videoId)
        save()
    }

    /// Check if a song is liked.
    func isLiked(_ videoId: String) -> Bool {
        likedIds.contains(videoId)
    }

    /// Get all liked song IDs as an Array (useful for iterating in a fixed
    /// order, e.g. to build a "Liked Songs" playlist screen).
    func allLikedIds() -> [String] {
        Array(likedIds)
    }

    /// The total number of liked songs.
    var count: Int {
        likedIds.count
    }

    // MARK: - Persistence

    /// Save liked IDs to UserDefaults.
    ///
    /// UserDefaults can't store a Set directly, so we convert it to an
    /// Array first. `Array(likedIds)` copies the Set's contents into a new
    /// Array value (order is not guaranteed, but that's fine, we only
    /// care about membership, not order).
    private func save() {
        UserDefaults.standard.set(Array(likedIds), forKey: defaultsKey)
        let timestampsAsIntervals = likedTimestamps.mapValues { $0.timeIntervalSince1970 }
        UserDefaults.standard.set(timestampsAsIntervals, forKey: timestampsDefaultsKey)

        // Let CloudKitSyncManager (if wired up) know liked songs changed,
        // see the matching comment in PlaylistManager.savePlaylists().
        NotificationCenter.default.post(name: .likedSongsDidChange, object: nil)
    }

    /// Load liked IDs from UserDefaults.
    ///
    /// `stringArray(forKey:)` returns `nil` if nothing was ever saved under
    /// this key (e.g. first launch), in which case we simply keep the
    /// empty Set that `likedIds` was initialized with. `if let` unwraps the
    /// optional only when a saved array actually exists.
    private func load() {
        if let ids = UserDefaults.standard.stringArray(forKey: defaultsKey) {
            likedIds = Set(ids)
        }
        if let intervals = UserDefaults.standard.dictionary(forKey: timestampsDefaultsKey) as? [String: Double] {
            likedTimestamps = intervals.mapValues { Date(timeIntervalSince1970: $0) }
        }
        // Backward compatibility: songs liked before timestamps existed
        // (or any ID that's somehow missing a timestamp) get "now" so they
        // still participate correctly in a CloudKit merge rather than being
        // dropped or crashing a lookup.
        for id in likedIds where likedTimestamps[id] == nil {
            likedTimestamps[id] = Date()
        }
    }

    // MARK: - CloudKit Sync Support

    /// Current liked songs as timestamped entries, for CloudKitSyncManager
    /// to encode into CKRecords and compare against the cloud's copy.
    func currentLikedEntries() -> [LikedSongEntry] {
        likedIds.map { LikedSongEntry(videoId: $0, likedAt: likedTimestamps[$0] ?? Date()) }
    }

    /// Replaces local liked-song state with a CloudKit-merged result and
    /// persists, without bumping timestamps (the merge already picked the
    /// newer entry for each ID, see `LikedSongConflictResolver`). Called
    /// only by CloudKitSyncManager.
    func applyMergedLikedEntries(_ merged: [LikedSongEntry]) {
        likedIds = Set(merged.map { $0.videoId })
        likedTimestamps = Dictionary(uniqueKeysWithValues: merged.map { ($0.videoId, $0.likedAt) })
        save()
    }
}
