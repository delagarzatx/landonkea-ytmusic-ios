// NowPlayingSnapshotTests.swift, Unit tests for the App-Group-shared
// "now playing" snapshot used by the Home Screen / Lock Screen widget.
//
// WHAT'S TESTED HERE vs. NOT:
// NowPlayingSnapshot.swift (Sources/YTMusicShared) is compiled into the
// YTMusicApp target (see project.yml), so `@testable import YTMusicApp`
// gives these tests direct access to it, same pattern as
// EqualizerEngineTests.swift testing EqualizerEngine.
//
// The widget extension's SwiftUI views (NowPlayingWidgetViews.swift) are
// NOT covered here, they live in a separate `app-extension` target with
// no test target of its own, and SwiftUI view bodies aren't meaningfully
// unit-testable anyway (no assertions to make beyond "did it compile,"
// which xcodebuild already covers). What IS worth testing, and easy to get
// wrong, is the pure logic: JSON round-tripping through UserDefaults, and
// the elapsed-time projection math that keeps a playing song's progress
// bar advancing between widget refreshes.
import XCTest
@testable import YTMusicApp

final class NowPlayingSnapshotTests: XCTestCase {

    // MARK: - Store round-trip

    /// Saving a snapshot and loading it back should return the same values.
    /// This is the core contract AudioPlayer and the widget's
    /// TimelineProvider both depend on.
    func testSaveThenLoadRoundTrips() {
        NowPlayingSnapshotStore.clear()

        let snapshot = NowPlayingSnapshot(
            videoId: "abc123",
            title: "Test Song",
            artist: "Test Artist",
            thumbnailUrl: "https://example.com/art.jpg",
            isPlaying: true,
            elapsedSeconds: 42,
            durationSeconds: 200,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        NowPlayingSnapshotStore.save(snapshot)

        let loaded = NowPlayingSnapshotStore.load()
        XCTAssertEqual(loaded, snapshot)

        NowPlayingSnapshotStore.clear()
    }

    /// A fresh install (nothing ever saved) must load `.empty`, not crash
    /// or return garbage, this is what the widget shows before the app
    /// has ever played a song.
    func testLoadWithNothingSavedReturnsEmpty() {
        NowPlayingSnapshotStore.clear()
        XCTAssertEqual(NowPlayingSnapshotStore.load(), .empty)
    }

    /// After `clear()`, load() must fall back to `.empty`, this is the
    /// path AudioPlayer.updateWidgetSnapshot(song:) takes when playback
    /// stops entirely, so the widget doesn't keep showing a stale song
    /// forever.
    func testClearResetsToEmpty() {
        let snapshot = NowPlayingSnapshot(
            videoId: "xyz",
            title: "Song",
            artist: "Artist",
            thumbnailUrl: "",
            isPlaying: false,
            elapsedSeconds: 10,
            durationSeconds: 100,
            updatedAt: Date()
        )
        NowPlayingSnapshotStore.save(snapshot)
        XCTAssertEqual(NowPlayingSnapshotStore.load(), snapshot)

        NowPlayingSnapshotStore.clear()
        XCTAssertEqual(NowPlayingSnapshotStore.load(), .empty)
    }

    // MARK: - projectedElapsedSeconds

    /// A paused song's elapsed time must stay frozen, no time should pass
    /// just because the widget happens to redraw later.
    func testProjectedElapsedSecondsWhenPausedStaysFrozen() {
        let snapshot = NowPlayingSnapshot(
            videoId: "abc",
            title: "Song",
            artist: "Artist",
            thumbnailUrl: "",
            isPlaying: false,
            elapsedSeconds: 90,
            durationSeconds: 200,
            // Written well in the past, if pause-freezing were broken,
            // this would project forward by a huge amount.
            updatedAt: Date(timeIntervalSinceNow: -3600)
        )
        XCTAssertEqual(snapshot.projectedElapsedSeconds, 90, accuracy: 0.001)
    }

    /// A playing song's elapsed time should advance roughly in step with
    /// the wall clock since `updatedAt`.
    func testProjectedElapsedSecondsWhenPlayingAdvances() {
        let snapshot = NowPlayingSnapshot(
            videoId: "abc",
            title: "Song",
            artist: "Artist",
            thumbnailUrl: "",
            isPlaying: true,
            elapsedSeconds: 10,
            durationSeconds: 200,
            updatedAt: Date(timeIntervalSinceNow: -5)
        )
        // ~10 + 5 = ~15 seconds elapsed; allow slack for test execution time.
        XCTAssertEqual(snapshot.projectedElapsedSeconds, 15, accuracy: 1.0)
    }

    /// A stale "playing" snapshot must never project past the song's
    /// duration, otherwise a widget that hasn't refreshed in a while
    /// could show >100% progress or a negative "time remaining."
    func testProjectedElapsedSecondsClampsToDuration() {
        let snapshot = NowPlayingSnapshot(
            videoId: "abc",
            title: "Song",
            artist: "Artist",
            thumbnailUrl: "",
            isPlaying: true,
            elapsedSeconds: 195,
            durationSeconds: 200,
            // Written 10 minutes ago, naive math would project ~795s.
            updatedAt: Date(timeIntervalSinceNow: -600)
        )
        XCTAssertEqual(snapshot.projectedElapsedSeconds, 200, accuracy: 0.001)
    }

    // MARK: - progressFraction

    /// A song with zero/unknown duration must report 0 progress rather
    /// than dividing by zero (which in Swift's Double math yields NaN or
    /// infinity, either would make the widget's progress bar draw
    /// nonsense-width rectangles).
    func testProgressFractionWithZeroDurationIsZero() {
        let snapshot = NowPlayingSnapshot(
            videoId: "abc",
            title: "Song",
            artist: "Artist",
            thumbnailUrl: "",
            isPlaying: true,
            elapsedSeconds: 5,
            durationSeconds: 0,
            updatedAt: Date()
        )
        XCTAssertEqual(snapshot.progressFraction, 0)
    }

    /// Basic sanity check: halfway through a song reports ~0.5 progress.
    func testProgressFractionHalfway() {
        let snapshot = NowPlayingSnapshot(
            videoId: "abc",
            title: "Song",
            artist: "Artist",
            thumbnailUrl: "",
            isPlaying: false,
            elapsedSeconds: 100,
            durationSeconds: 200,
            updatedAt: Date()
        )
        XCTAssertEqual(snapshot.progressFraction, 0.5, accuracy: 0.001)
    }

    /// Progress must never exceed 1.0 even if elapsedSeconds somehow
    /// exceeds durationSeconds (e.g. a slightly stale snapshot).
    func testProgressFractionClampsToOne() {
        let snapshot = NowPlayingSnapshot(
            videoId: "abc",
            title: "Song",
            artist: "Artist",
            thumbnailUrl: "",
            isPlaying: false,
            elapsedSeconds: 250,
            durationSeconds: 200,
            updatedAt: Date()
        )
        XCTAssertEqual(snapshot.progressFraction, 1.0, accuracy: 0.001)
    }

    // MARK: - Codable

    /// The exact JSON encode/decode path NowPlayingSnapshotStore relies on,
    /// tested directly (independent of UserDefaults) so a failure here
    /// points straight at the model rather than the storage layer.
    func testCodableRoundTrip() throws {
        let snapshot = NowPlayingSnapshot.placeholderExample
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
    }

    /// `videoId == nil` (the "nothing playing" case) must also round-trip
    /// correctly through JSON, Optional<String> encoding is exactly the
    /// kind of thing that's easy to silently break with a hand-rolled
    /// Codable implementation, though this one relies on the compiler-
    /// synthesized conformance.
    func testCodableRoundTripWithNilVideoId() throws {
        let data = try JSONEncoder().encode(NowPlayingSnapshot.empty)
        let decoded = try JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
        XCTAssertNil(decoded.videoId)
        XCTAssertEqual(decoded, NowPlayingSnapshot.empty)
    }
}
