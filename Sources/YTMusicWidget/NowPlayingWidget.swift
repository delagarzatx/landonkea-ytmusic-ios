// NowPlayingWidget.swift, The widget configuration: which sizes it
// supports and what to call it in the widget gallery.

import WidgetKit
import SwiftUI

struct NowPlayingWidget: Widget {
    // Must exactly match the `ofKind:` string AudioPlayer passes to
    // `WidgetCenter.shared.reloadTimelines(ofKind:)`, see
    // NowPlayingSnapshotStore.widgetKind in Sources/YTMusicShared.
    let kind: String = NowPlayingSnapshotStore.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Now Playing")
        .description("Shows the song currently playing in YT Music. Tap to jump back into the app.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .accessoryRectangular,
            .accessoryCircular,
        ])
    }
}

/// Picks the right layout for the widget's current family (size/placement).
/// Home Screen widgets (`.systemSmall`/`.systemMedium`) get a card with
/// artwork; Lock Screen widgets (`.accessoryRectangular`/`.accessoryCircular`)
/// are text/glyph-only per Apple's Lock Screen widget design guidance (no
/// full-color artwork there, the system tints everything monochrome).
struct NowPlayingWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NowPlayingEntry

    var body: some View {
        switch family {
        case .accessoryRectangular:
            LockScreenRectangularView(entry: entry)
        case .accessoryCircular:
            LockScreenCircularView(entry: entry)
        case .systemMedium:
            MediumNowPlayingView(entry: entry)
        default:
            SmallNowPlayingView(entry: entry)
        }
    }
}

#Preview(as: .systemSmall) {
    NowPlayingWidget()
} timeline: {
    NowPlayingEntry(date: .now, snapshot: .placeholderExample, artworkData: nil)
    NowPlayingEntry(date: .now, snapshot: .empty, artworkData: nil)
}

#Preview(as: .systemMedium) {
    NowPlayingWidget()
} timeline: {
    NowPlayingEntry(date: .now, snapshot: .placeholderExample, artworkData: nil)
}

#Preview(as: .accessoryRectangular) {
    NowPlayingWidget()
} timeline: {
    NowPlayingEntry(date: .now, snapshot: .placeholderExample, artworkData: nil)
}

#Preview(as: .accessoryCircular) {
    NowPlayingWidget()
} timeline: {
    NowPlayingEntry(date: .now, snapshot: .placeholderExample, artworkData: nil)
}
