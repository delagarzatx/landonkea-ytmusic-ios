// SleepTimerQueueEndTests.swift, verifies the "smart" sleep timer added
// alongside the existing fixed-duration presets: `startSleepTimerAtEndOfQueue()`
// should stop playback once the LAST song in the current queue finishes,
// rather than after a fixed amount of time, and must override repeatMode
// (otherwise `.all`/`.one` would mean the timer never actually stops
// anything).
import XCTest
import AVFoundation
@testable import YTMusicApp

@MainActor
final class SleepTimerQueueEndTests: XCTestCase {

    /// `AudioPlayer.queue`/`currentIndex` persist to `queue_state.json` in
    /// the real Documents directory on every `didSet` (see
    /// `saveQueueState()`/`loadQueueState()` in AudioPlayer.swift), so a
    /// fresh `AudioPlayer()` in one test will silently restore whatever
    /// queue a PREVIOUS test (or a real app run on this simulator) left
    /// behind. Deleting the file before/after each test keeps these tests
    /// isolated and deterministic instead of depending on run order.
    private func removePersistedQueueState() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: documents.appendingPathComponent("queue_state.json"))
    }

    override func setUp() {
        super.setUp()
        removePersistedQueueState()
    }

    override func tearDown() {
        removePersistedQueueState()
        super.tearDown()
    }

    /// Synthesize a tiny (~0.3s) mono WAV file on disk so tests can drive
    /// AudioPlayer through REAL playback (AVPlayer + its periodic time
    /// observer) all the way to a natural "song ended".
    ///
    /// NOTE: this deliberately does NOT reuse
    /// `AVAudioFormat(standardFormatWithSampleRate:channels:)` the way
    /// EqualizerEngineTests does, that "standard" format is 32-bit float,
    /// non-interleaved PCM, which AVAudioEngine's `scheduleFile` handles
    /// fine but which AVPlayer/AVURLAsset's Fig decoder does not reliably
    /// play in this environment (observed as a
    /// "FigFilePlayer ... signalled err=-12864" failure, the item never
    /// progresses, so it never reaches end-of-item). This path goes
    /// through `AVPlayer` (see `playSongFromLocal` in AudioPlayer.swift),
    /// so the file needs to be a canonical, widely-supported WAV: 16-bit
    /// integer, interleaved PCM.
    private func makeTestAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 44100,
            channels: 1,
            interleaved: true
        ) else {
            throw NSError(domain: "SleepTimerQueueEndTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create audio format"])
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)

        let frameCount: AVAudioFrameCount = 13230 // ~0.3s at 44.1kHz
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        if let channelData = buffer.int16ChannelData {
            for frame in 0..<Int(frameCount) {
                let sample = sin(Float(frame) * 0.05) * 0.1
                channelData[0][frame] = Int16(sample * Float(Int16.max))
            }
        }
        try file.write(from: buffer)

        return url
    }

    /// Unit-level check of the countdown estimate: with a known current
    /// song's remaining time and known durations for the songs still
    /// queued after it, `sleepTimerRemaining` should equal their sum,
    /// this is the number shown in the Sleep Timer UI.
    func testQueueEndEstimateSumsRemainingAndUpcomingDurations() {
        let player = AudioPlayer()

        let song1 = NowPlaying(id: "1", title: "One", artist: "A", thumbnailUrl: "", duration: 200, audioUrl: "x")
        let song2 = NowPlaying(id: "2", title: "Two", artist: "A", thumbnailUrl: "", duration: 180, audioUrl: "x")
        let song3 = NowPlaying(id: "3", title: "Three", artist: "A", thumbnailUrl: "", duration: 90, audioUrl: "x")

        player.queue = [song1, song2, song3]
        player.currentIndex = 0
        player.currentSong = song1
        player.duration = 200
        player.currentTime = 150 // 50s left in song1

        player.startSleepTimerAtEndOfQueue()

        XCTAssertTrue(player.isSleepTimerActive)
        XCTAssertTrue(player.sleepTimerStopsAtQueueEnd)
        // 50s left in song1 + 180 (song2) + 90 (song3) = 320
        XCTAssertEqual(player.sleepTimerRemaining, 320, accuracy: 0.5)

        player.stopSleepTimer()
        XCTAssertFalse(player.isSleepTimerActive)
        XCTAssertFalse(player.sleepTimerStopsAtQueueEnd)
    }

    /// `startSleepTimerAtEndOfQueue()` does nothing if there's no current
    /// song to anchor to (e.g. an empty queue), there's nothing sensible
    /// to count down or wait for.
    func testQueueEndTimerNoOpWithoutCurrentSong() {
        let player = AudioPlayer()
        XCTAssertEqual(player.currentIndex, -1)

        player.startSleepTimerAtEndOfQueue()

        XCTAssertFalse(player.isSleepTimerActive)
        XCTAssertFalse(player.sleepTimerStopsAtQueueEnd)
    }

    /// Full integration path: play a real (tiny) local file as the LAST
    /// song of a two-song queue, arm the queue-end sleep timer, and let
    /// playback run to a genuine natural end, then confirm handleSongEnded()
    /// stopped playback instead of advancing/looping.
    ///
    /// This routes playback through EqualizerEngine (by enabling
    /// EqualizerManager.shared.isEnabled) rather than the plain AVPlayer
    /// path AudioPlayer normally uses for local files. Both are genuine,
    /// non-mocked playback engines that call the same handleSongEnded(),
    /// but AVPlayer's "FigFilePlayer" decoder does not reliably play ANY
    /// synthesized WAV in this sandboxed test environment (fails with
    /// "signalled err=-12864" regardless of PCM format, reproducible even
    /// via a minimal AVPlayer smoke test) while EqualizerEngine's
    /// AVAudioEngine-based playback works fine here, as proven by the
    /// pre-existing EqualizerEngineTests. Using the EQ path keeps this a
    /// real playback integration test (not a fake), just via the playback
    /// engine that's actually exercisable in this environment; the code
    /// path being tested (queue-end override in handleSongEnded()) is
    /// identical either way, see the "Forward 'song finished'" comment in
    /// AudioPlayer.startEQPlayback().
    func testStopsPlaybackAfterLastSongInQueueEnds() async throws {
        let audioURL = try makeTestAudioFile()
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let eq = EqualizerManager()
        eq.isEnabled = true
        let previousSharedEQ = EqualizerManager.shared
        EqualizerManager.shared = eq
        defer { EqualizerManager.shared = previousSharedEQ }

        let player = AudioPlayer()

        await player.playLocal(
            videoId: "last-song",
            title: "Last Song",
            artist: "Test Artist",
            thumbnailUrl: "",
            localURL: audioURL,
            duration: 0
        )

        // playLocal() replaces the queue with just this one song at index
        // 0, reshape it into a two-song queue where the song actually
        // playing is the LAST one, so the "was that the last song?" check
        // in handleSongEnded() is genuinely exercised.
        let priorSong = NowPlaying(id: "prior-song", title: "Prior", artist: "Test Artist", thumbnailUrl: "", duration: 200, audioUrl: "x")
        guard let nowPlayingSong = player.currentSong else {
            return XCTFail("Expected playLocal to set currentSong")
        }
        player.queue = [priorSong, nowPlayingSong]
        player.currentIndex = 1

        // Deliberately set repeatMode to `.all`, without the queue-end
        // override in handleSongEnded(), this would loop back to index 0
        // forever instead of stopping.
        player.repeatMode = .all

        player.startSleepTimerAtEndOfQueue()
        XCTAssertTrue(player.isSleepTimerActive)

        // Poll for the song to reach its natural end (periodic time
        // observer fires every 0.5s; file is ~0.3s), same general pattern
        // as waiting on an XCTestExpectation, but state-based since
        // AudioPlayer doesn't expose a "song did end" callback to tests.
        let deadline = Date().addingTimeInterval(8)
        while player.state != .paused && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }

        XCTAssertEqual(player.state, .paused, "Playback should pause once the last song in the queue ends")
        XCTAssertFalse(player.isSleepTimerActive, "The queue-end sleep timer should deactivate once it fires")
        XCTAssertFalse(player.sleepTimerStopsAtQueueEnd)
        XCTAssertEqual(player.currentIndex, 1, "Should NOT have advanced/looped past the last song despite repeatMode == .all")
    }
}
