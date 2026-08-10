// NowPlayingWidgetViews.swift, The actual per-size visual layouts for the
// Now Playing widget. Split out from NowPlayingWidget.swift (the
// configuration) so each layout stays small and easy to scan on its own,
// mirroring the "one small computed property per section" style used
// throughout Sources/YTMusicApp/Views.

import SwiftUI
import WidgetKit

// MARK: - Home Screen: Small

/// The `.systemSmall` layout, a square card: artwork fills the top, title
/// / artist / a thin progress bar sit below.
struct SmallNowPlayingView: View {
    let entry: NowPlayingEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            artwork
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(entry.snapshot.title)
                .font(.caption)
                .fontWeight(.semibold)
                .lineLimit(1)

            Text(entry.snapshot.artist)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if entry.snapshot.videoId != nil {
                ProgressBar(fraction: entry.snapshot.progressFraction)
            }
        }
        .widgetURL(NowPlayingWidgetLink.url)
    }

    private var artwork: some View {
        ArtworkImage(data: entry.artworkData, isPlaying: entry.snapshot.isPlaying)
    }
}

// MARK: - Home Screen: Medium

/// The `.systemMedium` layout, artwork on the left, song info + a play/pause
/// glyph and progress bar on the right (wider format, so text doesn't need
/// to be as tightly truncated as the small size).
struct MediumNowPlayingView: View {
    let entry: NowPlayingEntry

    var body: some View {
        HStack(spacing: 12) {
            ArtworkImage(data: entry.artworkData, isPlaying: entry.snapshot.isPlaying)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                Spacer(minLength: 0)

                Text(entry.snapshot.title)
                    .font(.headline)
                    .lineLimit(2)

                Text(entry.snapshot.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if entry.snapshot.videoId != nil {
                    ProgressBar(fraction: entry.snapshot.progressFraction)
                    HStack {
                        Text(TimeFormat.string(from: entry.snapshot.projectedElapsedSeconds))
                        Spacer()
                        Image(systemName: entry.snapshot.isPlaying ? "play.fill" : "pause.fill")
                        Spacer()
                        Text(TimeFormat.string(from: entry.snapshot.durationSeconds))
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .widgetURL(NowPlayingWidgetLink.url)
    }
}

// MARK: - Lock Screen: Rectangular

/// The `.accessoryRectangular` Lock Screen layout, text-only (system
/// renders Lock Screen widgets in a single tint color, so artwork wouldn't
/// read as anything but a gray blob; showing text + a glyph instead follows
/// Apple's own Lock Screen widget guidance).
struct LockScreenRectangularView: View {
    let entry: NowPlayingEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(entry.snapshot.title)
                    .lineLimit(1)
            } icon: {
                Image(systemName: entry.snapshot.isPlaying ? "waveform" : "pause.fill")
            }
            .font(.headline)

            Text(entry.snapshot.artist)
                .font(.caption)
                .lineLimit(1)

            if entry.snapshot.videoId != nil {
                ProgressBar(fraction: entry.snapshot.progressFraction)
                    .frame(height: 3)
            }
        }
        .widgetURL(NowPlayingWidgetLink.url)
    }
}

// MARK: - Lock Screen: Circular

/// The `.accessoryCircular` Lock Screen layout, a ring showing playback
/// progress around a play/pause glyph, similar to a battery/timer complication.
struct LockScreenCircularView: View {
    let entry: NowPlayingEntry

    var body: some View {
        Gauge(value: entry.snapshot.progressFraction) {
            Image(systemName: entry.snapshot.isPlaying ? "waveform" : "pause.fill")
        }
        .gaugeStyle(.accessoryCircular)
        .widgetURL(NowPlayingWidgetLink.url)
    }
}

// MARK: - Shared Pieces

/// Album artwork, or a stylized "no artwork" fallback (matches the app's
/// grey-box placeholder convention used elsewhere, e.g. DownloadRow's
/// thumbnail placeholder) when the entry has no image bytes, either
/// nothing is playing, or the fetch in NowPlayingProvider failed/timed out.
struct ArtworkImage: View {
    let data: Data?
    let isPlaying: Bool

    var body: some View {
        if let data, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.gray.opacity(0.3)
                Image(systemName: isPlaying ? "music.note" : "music.note.list")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A thin, rounded progress bar, the widget-sized equivalent of
/// PlayerView/CarModeView's GeometryReader-based progress bar, just without
/// needing draggable seeking (widgets can't host gesture-driven controls).
struct ProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.tertiary)
                RoundedRectangle(cornerRadius: 2)
                    .fill(.primary)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 3)
    }
}

/// Formats seconds as "M:SS", the widget-target equivalent of
/// PlayerView/CarModeView's private `formatTime(_:)` helpers. Pulled out as
/// a standalone enum (rather than duplicated as another private method)
/// since two view files in this target both need it.
enum TimeFormat {
    static func string(from seconds: Double) -> String {
        guard !seconds.isNaN, !seconds.isInfinite else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The deep link every widget size opens the app with when tapped. A single
/// shared constant so the URL string only needs to change in one place if
/// the app ever adds real `onOpenURL` routing (e.g. straight to the full
/// player) instead of just foregrounding to whatever's already on screen,
/// see the app-side scheme registration in
/// Sources/YTMusicApp/Resources/Info.plist (CFBundleURLTypes).
enum NowPlayingWidgetLink {
    static let url = URL(string: "ytmusic://nowplaying")
}
