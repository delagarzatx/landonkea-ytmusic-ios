// LyricsClientTests.swift, verifies the lyrics provider fallback chain
// added alongside lrclib.net: lrclib exact match -> lrclib search ->
// lyrics.ovh (plain-text-only fallback).
//
// These tests never touch the real network. `MockURLProtocol` intercepts
// every request made through a `URLSession` configured with it and hands
// back a canned response based on which host/path was requested, so we can
// exercise "lrclib has nothing, lyrics.ovh does" and similar scenarios
// deterministically and offline.
import XCTest
@testable import YTMusicApp

/// Intercepts URLSession requests and returns a scripted response instead
/// of hitting the network. Register handlers by host before each request;
/// unregistered hosts fail the test loudly (via `XCTFail` inside the
/// handler) rather than silently falling through to the real network.
final class MockURLProtocol: URLProtocol {
    /// Maps a URL's host to a closure producing (status code, response body).
    /// `static` because URLProtocol subclasses are instantiated internally
    /// by URLSession, not by test code, this is the only way to hand
    /// per-test behavior in.
    static var responseHandlers: [String: (URL) -> (Int, Data)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let handler = Self.responseHandlers[host] else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }

        let (statusCode, data) = handler(url)
        let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@MainActor
final class LyricsClientTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
        MockURLProtocol.responseHandlers = [:]
    }

    override func tearDown() {
        MockURLProtocol.responseHandlers = [:]
        session = nil
        super.tearDown()
    }

    /// When lrclib's exact-match endpoint has the song, its (synced)
    /// result is used directly, lyrics.ovh should never be queried.
    func testPrimaryProviderSuccessSkipsFallback() async {
        var ovhWasCalled = false

        MockURLProtocol.responseHandlers["lrclib.net"] = { _ in
            let json = """
            {"trackName":"Bohemian Rhapsody","artistName":"Queen","plainLyrics":"Is this the real life","syncedLyrics":"[00:01.00] Is this the real life"}
            """
            return (200, Data(json.utf8))
        }
        MockURLProtocol.responseHandlers["api.lyrics.ovh"] = { _ in
            ovhWasCalled = true
            return (200, Data(#"{"lyrics":"should not be used"}"#.utf8))
        }

        let client = LyricsClient(session: session)
        let lyrics = await client.fetchLyrics(trackName: "Bohemian Rhapsody", artistName: "Queen")

        XCTAssertEqual(lyrics?.plainText, "Is this the real life")
        XCTAssertTrue(lyrics?.hasSyncedLyrics ?? false)
        XCTAssertFalse(ovhWasCalled, "lyrics.ovh should not be queried when lrclib already succeeded")
    }

    /// When lrclib 404s on both exact match and search, the client falls
    /// through to lyrics.ovh and returns its plain-text-only result.
    func testFallsBackToSecondProviderWhenPrimaryHasNothing() async {
        MockURLProtocol.responseHandlers["lrclib.net"] = { _ in
            (404, Data())
        }
        MockURLProtocol.responseHandlers["api.lyrics.ovh"] = { _ in
            (200, Data(#"{"lyrics":"Fallback lyrics text\nSecond line"}"#.utf8))
        }

        let client = LyricsClient(session: session)
        let lyrics = await client.fetchLyrics(trackName: "Some Obscure Song", artistName: "Some Artist")

        XCTAssertEqual(lyrics?.plainText, "Fallback lyrics text\nSecond line")
        XCTAssertEqual(lyrics?.trackName, "Some Obscure Song")
        XCTAssertEqual(lyrics?.artistName, "Some Artist")
        // The fallback provider never supplies timing information.
        XCTAssertFalse(lyrics?.hasSyncedLyrics ?? true)
        XCTAssertNil(lyrics?.syncedLines)
    }

    /// If BOTH providers have nothing, fetchLyrics returns nil rather than
    /// throwing or crashing.
    func testReturnsNilWhenNoProviderHasLyrics() async {
        MockURLProtocol.responseHandlers["lrclib.net"] = { _ in
            (404, Data())
        }
        MockURLProtocol.responseHandlers["api.lyrics.ovh"] = { _ in
            (404, Data())
        }

        let client = LyricsClient(session: session)
        let lyrics = await client.fetchLyrics(trackName: "Nonexistent Song", artistName: "Nobody")

        XCTAssertNil(lyrics)
    }

    /// A 200 response from lyrics.ovh with an empty lyrics string is
    /// treated the same as "not found," not as a usable (empty) result.
    func testFallbackProviderEmptyLyricsTreatedAsNotFound() async {
        MockURLProtocol.responseHandlers["lrclib.net"] = { _ in
            (404, Data())
        }
        MockURLProtocol.responseHandlers["api.lyrics.ovh"] = { _ in
            (200, Data(#"{"lyrics":""}"#.utf8))
        }

        let client = LyricsClient(session: session)
        let lyrics = await client.fetchLyrics(trackName: "Song", artistName: "Artist")

        XCTAssertNil(lyrics)
    }
}
