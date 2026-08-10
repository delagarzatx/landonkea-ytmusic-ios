// NowPlayingSnapshot.swift, Shared "what's playing right now" state.
//
// WHY THIS FILE LIVES IN ITS OWN MODULE FOLDER (Sources/YTMusicShared):
// The Home Screen / Lock Screen widget (Sources/YTMusicWidget) runs in a
// separate OS process from the main app (Sources/YTMusicApp), it's a
// distinct extension target with its own sandbox. It cannot read
// AudioPlayer's @Published properties directly. Both targets compile this
// same file (see project.yml's `sources:` for each target), so they share
// one definition of the data that crosses the process boundary, instead of
// two independently-maintained copies that could drift out of sync.
//
// HOW DATA CROSSES THE PROCESS BOUNDARY:
// The app and the widget extension both belong to the same "App Group",
// a sandboxed container both processes are allowed to read/write (declared
// in YTMusicApp.entitlements and YTMusicWidget.entitlements). We use
// UserDefaults(suiteName:) scoped to that App Group as a lightweight
// key-value store: cheap to write on every playback-state change, no file
// locking to worry about, and small enough (one song's worth of text) that
// JSON-encoding it into a single UserDefaults key is simpler than managing
// a shared file.

import Foundation

/// A snapshot of "what's playing right now," written by the main app
/// (AudioPlayer.updateWidgetSnapshot(song:)) and read by the widget
/// extension's TimelineProvider.
///
/// SCOPE (v1): just enough to render a compact now-playing card, title,
/// artist, artwork URL, play/pause state, and enough timing info to draw a
/// progress bar. No queue, no lyrics, those would be their own widgets.
struct NowPlayingSnapshot: Codable, Equatable {
    /// YouTube video ID (mirrors `NowPlaying.id`). `nil` means nothing is
    /// currently loaded, the widget shows its "not playing" state.
    let videoId: String?
    let title: String
    let artist: String
    let thumbnailUrl: String
    let isPlaying: Bool
    /// Elapsed playback position, in seconds, as of `updatedAt`.
    let elapsedSeconds: Double
    let durationSeconds: Double
    /// When this snapshot was written. Combined with `elapsedSeconds` this
    /// lets the widget keep a *playing* song's progress bar advancing in
    /// between app-pushed updates (see `projectedElapsedSeconds`) without
    /// the app needing to write a new snapshot every second, it only
    /// writes when the song or play/pause state actually changes.
    let updatedAt: Date

    /// The "nothing is playing" state, shown on fresh installs (before the
    /// app has ever written a snapshot) and after playback stops.
    static let empty = NowPlayingSnapshot(
        videoId: nil,
        title: "Not Playing",
        artist: "",
        thumbnailUrl: "",
        isPlaying: false,
        elapsedSeconds: 0,
        durationSeconds: 0,
        updatedAt: Date()
    )

    /// Sample data for widget gallery previews / SwiftUI previews, so the
    /// widget picker shows something realistic rather than "Not Playing."
    static let placeholderExample = NowPlayingSnapshot(
        videoId: "preview",
        title: "Bohemian Rhapsody",
        artist: "Queen",
        thumbnailUrl: "",
        isPlaying: true,
        elapsedSeconds: 92,
        durationSeconds: 355,
        updatedAt: Date()
    )

    /// Elapsed time projected forward from `updatedAt` to "now."
    ///
    /// A *paused* song stays frozen at `elapsedSeconds` (no time passes
    /// while paused). A *playing* song's elapsed time keeps advancing with
    /// the wall clock, clamped to `[0, durationSeconds]` so a stale
    /// snapshot (e.g. the app hasn't refreshed in a while) can't project
    /// past the end of the song or go negative.
    var projectedElapsedSeconds: Double {
        guard isPlaying else { return elapsedSeconds }
        let projected = elapsedSeconds + Date().timeIntervalSince(updatedAt)
        let upperBound = durationSeconds > 0 ? durationSeconds : max(projected, 0)
        return min(max(projected, 0), upperBound)
    }

    /// Progress fraction (0.0 to 1.0) for a progress bar. 0 when duration
    /// is unknown/zero, rather than dividing by zero.
    var progressFraction: Double {
        guard durationSeconds > 0 else { return 0 }
        return min(max(projectedElapsedSeconds / durationSeconds, 0), 1)
    }
}

/// Reads/writes `NowPlayingSnapshot` through the App Group shared
/// container so the main app and the widget extension can exchange
/// "what's playing" state across the process boundary.
enum NowPlayingSnapshotStore {
    /// Must exactly match the App Group string configured in both targets'
    /// entitlements files (see project.yml → CODE_SIGN_ENTITLEMENTS).
    static let appGroupID = "group.com.landonkea.ytmusic"

    /// The WidgetKit "kind" identifier shared between the widget's
    /// `StaticConfiguration(kind:)` and the app's
    /// `WidgetCenter.reloadTimelines(ofKind:)` call, both must agree on
    /// this string or the reload silently targets nothing.
    static let widgetKind = "NowPlayingWidget"

    private static let storageKey = "nowPlayingSnapshot"

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    /// Persist the current snapshot. Safe to call frequently, it's a small
    /// JSON blob written to UserDefaults, not a disk file write.
    ///
    /// If the App Group is unavailable (e.g. a build with no code-signing
    /// team configured, so the shared container can't be resolved),
    /// `UserDefaults(suiteName:)` returns `nil` and this silently no-ops,
    /// the main app's own playback is unaffected either way; only the
    /// widget would show stale/empty data.
    static func save(_ snapshot: NowPlayingSnapshot) {
        guard let defaults, let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// Read the last-saved snapshot, or `.empty` if nothing has ever been
    /// written, the App Group is unavailable, or the stored data is somehow
    /// corrupt/undecodable, the widget always has *something* safe to draw.
    static func load() -> NowPlayingSnapshot {
        guard let defaults, let data = defaults.data(forKey: storageKey) else {
            return .empty
        }
        return (try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data)) ?? .empty
    }

    /// Clear the snapshot, called when playback stops entirely (no current
    /// song), so the widget falls back to its "not playing" state instead
    /// of showing the last song forever.
    static func clear() {
        defaults?.removeObject(forKey: storageKey)
    }
}
