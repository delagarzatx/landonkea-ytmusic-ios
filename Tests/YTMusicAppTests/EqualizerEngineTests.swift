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

    /// Synthesize a tiny (0.2s) mono WAV file on disk so the test has a
    /// real, playable local audio file, mirroring how AudioPlayer feeds
    /// EqualizerEngine a downloaded song's file URL.
    private func makeTestAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)

        let frameCount: AVAudioFrameCount = 4410 // 0.1s at 44.1kHz
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
}
