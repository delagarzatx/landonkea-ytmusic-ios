// NowPlayingProvider.swift, Supplies timeline entries to NowPlayingWidget.
//
// HOW WIDGETKIT TIMELINES WORK:
// A widget doesn't run continuously like the main app, the system asks a
// `TimelineProvider` for a `Timeline` (a list of entries, each with a date),
// then renders whichever entry's date has most recently passed, on its own
// schedule. Widgets don't "poll"; instead the app proactively calls
// `WidgetCenter.shared.reloadTimelines(ofKind:)` (see
// AudioPlayer.updateWidgetSnapshot(song:)) whenever the song or play/pause
// state changes, which makes WidgetKit re-invoke `getTimeline` here.
//
// Because the app already pushes a reload on every meaningful change, this
// provider only ever needs to hand back a single-entry timeline with
// `.never` as the refresh policy, "never refresh on your own; wait for the
// app to tell you." The one exception is a *playing* song's progress bar,
// which needs to keep moving between app-driven reloads, that's handled by
// `NowPlayingSnapshot.projectedElapsedSeconds` computing from the wall
// clock rather than needing a new timeline entry every second.

import WidgetKit

/// One rendered instant of the Now Playing widget: the shared snapshot plus
/// (if available) already-downloaded artwork image bytes.
struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: NowPlayingSnapshot
    let artworkData: Data?
}

struct NowPlayingProvider: TimelineProvider {
    /// Shown instantly while the widget is loading its first real entry,
    /// SwiftUI previews and the widget gallery also use this indirectly via
    /// `getSnapshot(in:completion:)`'s `context.isPreview` branch.
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: Date(), snapshot: .placeholderExample, artworkData: nil)
    }

    /// A quick, representative entry, used by the widget gallery/picker UI
    /// and for transient system snapshots. Skips the network fetch so the
    /// gallery renders instantly; real placements get real artwork via
    /// `getTimeline`.
    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) {
        if context.isPreview {
            completion(NowPlayingEntry(date: Date(), snapshot: .placeholderExample, artworkData: nil))
            return
        }
        let snapshot = NowPlayingSnapshotStore.load()
        completion(NowPlayingEntry(date: Date(), snapshot: snapshot, artworkData: nil))
    }

    /// The real timeline shown on the Home Screen / Lock Screen.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        Task {
            let snapshot = NowPlayingSnapshotStore.load()
            let artworkData = await Self.fetchArtwork(for: snapshot)
            let entry = NowPlayingEntry(date: Date(), snapshot: snapshot, artworkData: artworkData)
            // .never: the app pushes fresh timelines via
            // WidgetCenter.reloadTimelines(ofKind:) whenever the song or
            // play state changes, so there's nothing for WidgetKit to
            // pre-schedule on its own.
            completion(Timeline(entries: [entry], policy: .never))
        }
    }

    /// Downloads the current song's artwork directly from `thumbnailUrl`.
    ///
    /// WHY THE WIDGET FETCHES ITS OWN ARTWORK (instead of the app pushing
    /// image bytes through the App Group alongside the snapshot): keeps
    /// `NowPlayingSnapshot` a tiny, cheap-to-write JSON blob instead of a
    /// multi-KB image blob written on every play/pause toggle. The
    /// trade-off is a short network fetch each time the widget's timeline
    /// refreshes, bounded by a 5s timeout so a slow/broken connection
    /// still yields a widget (with a placeholder icon instead of art)
    /// rather than the OS-imposed timeline-generation deadline killing the
    /// whole update.
    private static func fetchArtwork(for snapshot: NowPlayingSnapshot) async -> Data? {
        guard !snapshot.thumbnailUrl.isEmpty, let url = URL(string: snapshot.thumbnailUrl) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        return try? await URLSession.shared.data(for: request).0
    }
}
