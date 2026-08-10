import Foundation
import SwiftUI

extension Notification.Name {
    /// Posted whenever `PlaylistManager.savePlaylists()` runs (create,
    /// rename, delete, add/remove song, pin toggle, or a CloudKit merge
    /// applying remote changes). CloudKitSyncManager observes this to
    /// trigger a debounced push; see YTMusicApp.swift for the wiring.
    static let playlistsDidChange = Notification.Name("playlistsDidChange")
}

// MARK: - Playlist Manager

/// Manages local playlists, create, rename, delete, add/remove songs.
///
/// WHAT THIS DOES:
/// Users can create playlists to organize their favorite songs. Playlists
/// are stored locally on the device (no login required). Each playlist has
/// a name, creation date, and list of songs.
///
/// STORAGE:
/// Playlists are saved as a JSON file in the Documents directory.
/// Each playlist is a simple struct with a name and array of NowPlaying songs.
///
/// HOW IT WORKS:
/// 1. User taps "New Playlist" in the Library tab
/// 2. They enter a name and tap Create
/// 3. From any song's context menu, they tap "Add to Playlist"
/// 4. They select which playlist to add to
/// 5. The song is appended to that playlist and saved to disk
/// 6. Tapping a playlist shows its songs
/// 7. Tapping a song in the playlist starts playing from that playlist
///
/// This is a `class` (not a `struct`) so that a single shared instance's
/// data is visible everywhere in the app, SwiftUI views hold a reference
/// to this same object rather than getting their own disconnected copies.
/// `ObservableObject` lets SwiftUI views watch it and redraw automatically
/// when `@Published` data changes.
class PlaylistManager: ObservableObject {

    // MARK: - Published Properties

    /// All user-created playlists, sorted by creation date (newest first).
    ///
    /// `@Published` is a property wrapper that notifies any SwiftUI view
    /// observing this object whenever the array changes, so the UI
    /// automatically refreshes to show the new state.
    @Published var playlists: [Playlist] = []

    // MARK: - Private Properties

    /// File path for persisting playlists as JSON.
    private let playlistsPath: URL

    // MARK: - Initialization

    /// Create the playlist manager and load existing playlists from disk.
    init() {
        // The Documents directory is the app's private, sandboxed folder for
        // storing files that should persist between app launches.
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.playlistsPath = documents.appendingPathComponent("playlists.json")
        loadPlaylists()
    }

    // MARK: - Playlist CRUD

    /// Create a new empty playlist.
    ///
    /// - Parameter name: The playlist name (e.g. "Workout Mix")
    /// - Returns: The newly created playlist
    ///
    /// `@discardableResult` tells the compiler not to warn callers who
    /// ignore the returned `Playlist`, sometimes callers just want the
    /// side effect (a playlist gets created) without needing the value back.
    @discardableResult
    func createPlaylist(name: String) -> Playlist {
        let playlist = Playlist(
            id: UUID().uuidString, // A UUID is a randomly-generated unique ID, extremely unlikely to collide with any other playlist's ID.
            name: name,
            songs: [],
            createdAt: Date()
        )
        playlists.insert(playlist, at: 0) // Newest first
        savePlaylists()
        return playlist
    }

    /// Create a new playlist pre-populated with a list of songs, e.g. from
    /// QueueView's "Save Queue as Playlist" button.
    ///
    /// This exists as its own method (rather than callers doing
    /// `createPlaylist(name:)` followed by a loop of `addSong(_:to:)`)
    /// because that two-step version would trigger a disk save for every
    /// single song (each `addSong` call ends with `savePlaylists()`), for
    /// a 50-song queue that's 50 redundant JSON encode+write cycles when
    /// one will do.
    ///
    /// - Parameters:
    ///   - name: The playlist name
    ///   - songs: The initial songs, in order (duplicates by video ID are
    ///     dropped, same as `addSong(_:to:)`'s no-duplicates rule)
    /// - Returns: The newly created playlist
    @discardableResult
    func createPlaylist(name: String, songs: [NowPlaying]) -> Playlist {
        var uniqueSongs: [NowPlaying] = []
        var seenIds = Set<String>()
        for song in songs where !seenIds.contains(song.id) {
            uniqueSongs.append(song)
            seenIds.insert(song.id)
        }

        let playlist = Playlist(
            id: UUID().uuidString,
            name: name,
            songs: uniqueSongs,
            createdAt: Date()
        )
        playlists.insert(playlist, at: 0)
        savePlaylists()
        return playlist
    }

    /// Rename an existing playlist.
    ///
    /// - Parameters:
    ///   - playlist: The playlist to rename
    ///   - newName: The new name
    func renamePlaylist(_ playlist: Playlist, newName: String) {
        guard let index = index(of: playlist) else { return }
        playlists[index].name = newName
        playlists[index].modifiedAt = Date()
        savePlaylists()
    }

    /// Delete a playlist.
    ///
    /// - Parameter playlist: The playlist to delete
    func deletePlaylist(_ playlist: Playlist) {
        // `removeAll(where:)` removes every element that matches the
        // closure's condition, here, any playlist whose `id` matches.
        playlists.removeAll { $0.id == playlist.id }
        savePlaylists()
    }

    /// Toggle whether a playlist is pinned (appears at top of the list).
    func togglePin(_ playlist: Playlist) {
        guard let index = index(of: playlist) else { return }
        playlists[index].isPinned.toggle()
        playlists[index].modifiedAt = Date()

        // Re-sort BEFORE saving, so the order written to disk always
        // matches what's shown on screen. (Previously this saved first and
        // sorted after, so the file on disk briefly held a stale order,
        // harmless today because loadPlaylists() always re-sorts on launch,
        // but easy to get wrong if that assumption ever changes, so it's
        // fixed here to do the obviously-correct thing.)
        sortPlaylistsByPinThenDate()
        savePlaylists()
    }

    // MARK: - Song Management

    /// Add a song to a playlist.
    ///
    /// Prevents duplicates, if the song is already in the playlist, it won't be added again.
    ///
    /// - Parameters:
    ///   - song: The NowPlaying song to add
    ///   - playlist: The playlist to add it to
    func addSong(_ song: NowPlaying, to playlist: Playlist) {
        guard let index = index(of: playlist) else { return }
        guard !playlists[index].songs.contains(where: { $0.id == song.id }) else { return }

        playlists[index].songs.append(song)
        playlists[index].modifiedAt = Date()
        savePlaylists()
    }

    /// Remove a song from a playlist.
    ///
    /// - Parameters:
    ///   - song: The song to remove
    ///   - playlist: The playlist to remove it from
    func removeSong(_ song: NowPlaying, from playlist: Playlist) {
        guard let index = index(of: playlist) else { return }
        playlists[index].songs.removeAll { $0.id == song.id }
        playlists[index].modifiedAt = Date()
        savePlaylists()
    }

    /// Check if a song is in a playlist.
    ///
    /// - Parameters:
    ///   - song: The song to check
    ///   - playlist: The playlist to check in
    /// - Returns: true if the song is already in the playlist
    func containsSong(_ song: NowPlaying, in playlist: Playlist) -> Bool {
        guard let index = index(of: playlist) else { return false }
        return playlists[index].songs.contains(where: { $0.id == song.id })
    }

    /// Get all playlists that contain a specific song.
    ///
    /// Used by the "Add to Playlist" menu to show checkmarks next to playlists
    /// that already contain the song.
    func playlistsContaining(_ song: NowPlaying) -> [Playlist] {
        // `filter` builds a new array containing only the elements for which
        // the closure returns `true`.
        return playlists.filter { playlist in
            playlist.songs.contains(where: { $0.id == song.id })
        }
    }

    // MARK: - Private Helpers

    /// Finds the index of a playlist within `playlists` by matching its `id`.
    ///
    /// Centralizing this lookup means every CRUD method above shares one
    /// implementation instead of repeating the same `firstIndex(where:)`
    /// closure, and it protects against a stale array index being used if
    /// this logic ever changes.
    private func index(of playlist: Playlist) -> Int? {
        playlists.firstIndex(where: { $0.id == playlist.id })
    }

    /// Sorts `playlists` in place: pinned playlists first, then by creation
    /// date with the newest first. Shared by both `loadPlaylists()` and
    /// `togglePin()` so the ordering rule only has to be written once.
    private func sortPlaylistsByPinThenDate() {
        playlists.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                // Pinned playlists (isPinned == true) sort before unpinned ones.
                return lhs.isPinned && !rhs.isPinned
            }
            // Both pinned or both unpinned: fall back to newest-first.
            return lhs.createdAt > rhs.createdAt
        }
    }

    // MARK: - Persistence

    /// Save all playlists to disk as JSON.
    /// Marked as internal (not private) so PlaylistDetailView can call it after reordering.
    func savePlaylists() {
        do {
            let encoder = JSONEncoder()
            // Dates don't have one canonical text form, so we pick ISO 8601
            // (e.g. "2026-08-02T10:00:00Z"), readable and precise, and it
            // must match the strategy used in loadPlaylists() below or dates
            // won't decode back correctly.
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(playlists)
            try data.write(to: playlistsPath)
        } catch {
            // Swallow the error rather than crash, a failed save just means
            // the user's playlist changes won't survive an app restart,
            // which is unfortunate but not catastrophic.
            print("Failed to save playlists: \(error)")
        }

        // Let CloudKitSyncManager (if wired up) know playlists changed, so
        // it can push the update. Posted unconditionally (even if CloudKit
        // sync is unavailable/unconfigured), NotificationCenter posts with
        // no observers are a no-op, so this has zero cost when sync isn't
        // set up, e.g. in unit tests that construct PlaylistManager alone.
        NotificationCenter.default.post(name: .playlistsDidChange, object: nil)
    }

    /// Replaces `playlists` with a CloudKit-merged result and saves, without
    /// re-touching `modifiedAt` on anything (the merge already picked the
    /// newer copy of each playlist, bumping timestamps again here would
    /// make every future sync think local just changed, defeating the
    /// point). Called only by CloudKitSyncManager.
    func applyMergedPlaylists(_ merged: [Playlist]) {
        playlists = merged
        sortPlaylistsByPinThenDate()
        savePlaylists()
    }

    /// Load playlists from disk.
    private func loadPlaylists() {
        guard FileManager.default.fileExists(atPath: playlistsPath.path) else {
            return
        }

        do {
            let data = try Data(contentsOf: playlistsPath)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            // `Codable` conformance (declared on the `Playlist` struct below)
            // is what allows `JSONDecoder` to turn raw JSON `Data` straight
            // into an array of `Playlist` values.
            playlists = try decoder.decode([Playlist].self, from: data)

            sortPlaylistsByPinThenDate()
        } catch {
            print("Failed to load playlists: \(error)")
            playlists = []
        }
    }
}

// MARK: - Playlist Model

/// A local playlist containing a list of songs.
///
/// `Identifiable` lets SwiftUI lists tell each playlist apart using its
/// `id`. `Codable` means Swift can automatically convert this struct to and
/// from JSON, which is how `PlaylistManager` saves/loads it above, as long
/// as every stored property is itself `Codable` (String, [NowPlaying], Date,
/// and Bool all are).
struct Playlist: Identifiable, Codable, Equatable {
    /// Unique identifier for this playlist
    let id: String

    /// User-given name (e.g. "Workout Mix", "Chill Vibes")
    var name: String

    /// The songs in this playlist, in order
    var songs: [NowPlaying]

    /// When this playlist was created
    let createdAt: Date

    /// Whether this playlist is pinned to the top of the list.
    /// Default false for backward compatibility with existing playlists.
    ///
    /// Giving this a default value (`= false`) means old playlist JSON files
    /// saved before this property existed can still be decoded, the
    /// decoder fills in `false` for any playlist whose saved JSON doesn't
    /// contain an "isPinned" field.
    var isPinned: Bool = false

    /// When this playlist was last changed (renamed, reordered, songs
    /// added/removed, pin toggled). Defaults to `createdAt`-equivalent
    /// "now" for backward compatibility with playlist JSON saved before
    /// CloudKit sync existed, same pattern as `isPinned` above.
    ///
    /// This is CloudKitSyncManager's conflict-resolution key: when the same
    /// playlist has diverged between two devices, whichever copy has the
    /// newer `modifiedAt` wins the merge (see `PlaylistConflictResolver` in
    /// CloudKitSyncManager.swift). It is NOT used for anything else,
    /// PlaylistManager's own sort order is by `createdAt`/`isPinned` only,
    /// unchanged from before sync existed.
    var modifiedAt: Date = Date()

    /// Number of songs in the playlist (computed convenience property)
    var songCount: Int {
        songs.count
    }

    /// Total duration of all songs in the playlist (computed).
    /// Returns a human-readable string like "45 min" or "1 hr 23 min".
    var totalDuration: String {
        // `reduce(0) { ... }` sums up every song's `duration` (in seconds)
        // into a single running total, starting from 0.
        let totalSeconds = songs.reduce(0) { $0 + $1.duration }
        // Integer division (`/`) truncates any remainder, so this gives
        // whole hours. `%` (modulo) gives the leftover seconds after
        // removing whole hours, which we then convert to whole minutes.
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60

        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        } else {
            return "\(minutes) min"
        }
    }
}
