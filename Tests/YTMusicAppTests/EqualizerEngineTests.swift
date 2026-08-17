// EqualizerEngineTests.swift, Runtime regression test for the
// EqualizerEngine crash bug that a prior cleanup pass fixed.
//
// THE BUG: EqualizerEngine used to call engine.connect(node, to: ...)
// in buildGraph() WITHOUT ever calling engine.attach(node) first.
// AVAudioEngine.connect(_:to:format:) throws an uncaught Objective-C
// exception (NSInternalInconsistencyException), not a catchable Swift
// error, if either node hasn't been attached to the engine first. That
// exception crashes the process. It reproduced every time a user turned
// the equalizer on and played a downloaded (local-file) song, because
// that's the only path that calls EqualizerEngine.playFile(), which
// calls buildGraph(), which calls engine.connect().
//
// THE FIX: attach playerNode/timePitch/eqNode to the engine exactly once,
// in init(), before any connect() call can happen.
//
// THIS TEST exercises the real runtime path: it creates an actual local
// audio file on disk (a synthesized WAV, no bundled fixture needed),
// instantiates a real EqualizerEngine, and calls playFile() on it. This
// runs the exact sequence that used to crash: buildGraph() ->
// engine.connect(playerNode, to: timePitch, ...) etc. If attach() were
// ever removed again, this test would crash the test process (an
// uncaught NSException isn't something XCTest can catch as a normal
// assertion failure, the test run would abort/fail), which is exactly
// the regression this test exists to catch.
import XCTest
import AVFoundation
@testable import YTMusicApp

@MainActor
final class EqualizerEngineTests: XCTestCase {

    /// Synthesize a tiny (0.2s by default) mono WAV file on disk so the
    /// test has a real, playable local audio file, mirroring how
    /// AudioPlayer feeds EqualizerEngine a downloaded song's file URL.
    private func makeTestAudioFile(seconds: Double = 0.1) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        let frameCount = AVAudioFrameCount(seconds * 44100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        // Fill with a quiet sine wave so it's a valid, non-silent buffer.
        if let channelData = buffer.floatChannelData {
            for frame in 0..<Int(frameCount) {
                let sample = sin(Float(frame) * 0.05) * 0.1
                channelData[0][frame] = sample
            }
        }
        try file.write(from: buffer)

        return url
    }

    /// Regression test: playing a local file through EqualizerEngine must
    /// not crash. This drives the exact init() -> playFile() ->
    /// buildGraph() -> engine.connect() sequence that crashed before the
    /// attach()-before-connect() fix.
    func testPlayFileDoesNotCrashAndReportsDuration() throws {
        let url = try makeTestAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = EqualizerEngine()

        let expectation = expectation(description: "playFile completion")
        var reportedDuration: Double = -1

        engine.playFile(
            url: url,
            rate: 1.0,
            volume: 1.0,
            gains: Array(repeating: 0.0, count: 10),
            frequencies: EqualizerManager.bandFrequencies,
            completion: { duration in
                reportedDuration = duration
                expectation.fulfill()
            }
        )

        wait(for: [expectation], timeout: 5)

        // A duration of 0 would mean setup failed (e.g. file couldn't be
        // opened); a positive duration means the full graph, attach,
        // connect, prepare, start, playerNode.play(), ran successfully
        // without throwing/crashing.
        XCTAssertGreaterThan(reportedDuration, 0)

        engine.stop()
    }

    /// Replaying on the SAME engine instance re-runs buildGraph() (and
    /// therefore engine.connect()) a second time. Nodes must only be
    /// attach()-ed once (done in init()), so this also verifies init()
    /// isn't accidentally re-attaching (which itself throws).
    func testReplayOnSameEngineDoesNotCrash() throws {
        let url = try makeTestAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = EqualizerEngine()

        for _ in 0..<2 {
            let expectation = expectation(description: "playFile completion")
            var reportedDuration: Double = -1

            engine.playFile(
                url: url,
                rate: 1.0,
                volume: 1.0,
                gains: Array(repeating: 0.0, count: 10),
                frequencies: EqualizerManager.bandFrequencies,
                completion: { duration in
                    reportedDuration = duration
                    expectation.fulfill()
                }
            )

            wait(for: [expectation], timeout: 5)
            XCTAssertGreaterThan(reportedDuration, 0)
        }

        engine.stop()
    }

    /// Regression test: seeking used to report elapsed time SINCE the
    /// seek instead of the actual position in the file. Root cause:
    /// AVAudioPlayerNode.playerTime(forNodeTime:) resets to 0 on every
    /// stop()/play() cycle, and seek() does exactly that, so a later
    /// position-polling tick would report ~elapsed-since-seek (starting
    /// near 0 again) rather than seek-target + elapsed.
    func testSeekReportsAbsolutePositionNotTimeSinceSeek() throws {
        let url = try makeTestAudioFile(seconds: 3.0)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = EqualizerEngine()

        let playExpectation = expectation(description: "playFile completion")
        engine.playFile(
            url: url,
            rate: 1.0,
            volume: 0.0,
            gains: Array(repeating: 0.0, count: 10),
            frequencies: EqualizerManager.bandFrequencies,
            completion: { _ in playExpectation.fulfill() }
        )
        wait(for: [playExpectation], timeout: 5)

        var latestReportedTime: Double = -1
        engine.onTimeUpdate = { time in
            latestReportedTime = time
        }

        // Seek well past where a reset-relative clock would still be
        // after the wait below (0.6s), so the two hypotheses (absolute
        // position vs. time-since-seek) land in clearly separate ranges.
        engine.seek(toSeconds: 2.0)
        XCTAssertEqual(latestReportedTime, 2.0, accuracy: 0.01)

        // Let the 0.25s position-polling timer tick at least once past
        // the seek before checking what it reports.
        let tickExpectation = expectation(description: "wait for a timer tick past the seek")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            tickExpectation.fulfill()
        }
        wait(for: [tickExpectation], timeout: 2)

        // Correct (absolute position): ~2.0-2.7s. Buggy (time-since-seek,
        // clock reset by the seek's stop()/play()): ~0.0-0.6s.
        XCTAssertGreaterThan(latestReportedTime, 1.9)

        engine.stop()
    }
}
