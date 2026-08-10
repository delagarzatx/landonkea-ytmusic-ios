import Foundation

// MARK: - Overview

/// Shared disk + memory cache for network responses and thumbnail images.
///
/// WHAT IS "CACHING" HERE?
/// Every time we hit the network, an API call, or `AsyncImage` downloading
/// an album cover, the response can optionally be saved locally (in RAM
/// and/or on disk). The next time we ask for that exact same URL, the
/// system can hand back the saved copy instead of downloading it again.
/// This is what `URLCache` does: it's Foundation's built-in HTTP cache,
/// the same mechanism a web browser uses to avoid re-downloading a page's
/// images on every visit.
///
/// WHY THIS FILE EXISTS:
/// Before this change, every `URLSession` in the app (InnerTubeClient,
/// LyricsClient, and SwiftUI's `AsyncImage`) used `URLSession.shared`,
/// which uses `URLCache.shared` with iOS's stock DEFAULT size, only
/// 512KB in memory and 10MB on disk. That's tiny: it can hold maybe a
/// few dozen thumbnail images before evicting older ones, so scrolling
/// back to an artist or album you already viewed re-downloads its
/// artwork from YouTube every single time, even seconds later. Across
/// app launches it's even worse, since anything not written to disk
/// vanishes when the process exits.
///
/// This file replaces that tiny default with a properly-sized cache and
/// makes sure both our own API client and `AsyncImage` share it.
///
/// WHAT GETS CACHED, AND WHAT DOESN'T (IMPORTANT, READ BEFORE CHANGING SIZES):
/// - Thumbnail images (GET requests to i.ytimg.com, lh3.googleusercontent.com,
///   etc.), the main beneficiary. Images are effectively immutable once
///   published (a given video ID's thumbnail doesn't silently change), so
///   caching them long-term is always correct.
/// - Lyrics lookups (LyricsClient, GET requests to lrclib.net), also
///   effectively immutable for a given track/artist pair.
/// - InnerTube API responses (search/browse/player) are POST requests.
///   `URLCache` does NOT automatically cache responses to POST requests,
///   even if the server sends `Cache-Control` headers, this is documented
///   Foundation behavior, not an oversight here. That's actually the
///   correct outcome for us: search results, the home feed, and artist
///   pages are supposed to reflect what YouTube has *right now*, not a
///   stale snapshot. We still route InnerTubeClient through this cache
///   (via `session`) so nothing needs to change if a future endpoint ever
///   uses GET, but no InnerTube JSON is being persisted to disk today.
/// - Player stream URLs (`PlayerInfo.audioUrl`) are NEVER touched by this
///   cache at all, they're handed directly to `AVPlayer`, which does its
///   own networking outside `URLSession`/`URLCache` entirely. That's good,
///   because those URLs expire after a few hours (see the comment on
///   `PlayerInfo` in Models.swift); if they were cached, playback could
///   fail after the cache served a stale, expired URL back to us.
enum NetworkCache {

    /// How much RAM the cache may use for hot (recently-touched) entries.
    ///
    /// WHY 20MB: this only needs to hold what's visible right now, the
    /// handful of album art thumbnails on screen plus a couple of screens
    /// of scrollback. Memory cache entries are cheap to evict (the disk
    /// copy is still there) and iOS reclaims this automatically under
    /// memory pressure, so we can afford to be generous without risking
    /// a low-memory jetsam.
    private static let memoryCapacityBytes = 20 * 1024 * 1024

    /// How much disk space the cache may use, total, forever.
    ///
    /// WHY 80MB: thumbnails from YouTube's `mqdefault.jpg` size are small
    /// (roughly 15-30KB each), so 80MB comfortably holds several thousand
    /// distinct thumbnails, enough for very heavy browsing across many
    /// sessions before anything needs to be evicted. At the same time it's
    /// a hard, small cap relative to typical modern phone storage (tens to
    /// hundreds of GB), so this cache can never become the thing that fills
    /// up someone's phone. `URLCache` evicts the least-recently-used entries
    /// automatically once this limit is hit, so we don't need to manage
    /// eviction ourselves.
    private static let diskCapacityBytes = 80 * 1024 * 1024

    /// The actual cache instance, and the point where it's installed.
    ///
    /// WHY A `static let` (LAZY, RUNS-ONCE) INSTEAD OF CODE IN THE APP'S
    /// `init()`:
    /// SwiftUI creates the app's `@StateObject` properties, including
    /// `APIClient`, which constructs `InnerTubeClient()`, as part of
    /// `YTMusicApp`'s own initialization, which happens BEFORE the body of
    /// a hand-written `init()` would run. By the time any of our own code
    /// could run in `init()`, `InnerTubeClient()` may already have been
    /// created and already grabbed `URLSession.shared` (and with it, the
    /// stock tiny `URLCache.shared`), too late to swap it out.
    ///
    /// Swift guarantees `static let` properties are initialized exactly
    /// once, lazily, the FIRST time they're touched, and that this
    /// initialization is thread-safe. So instead of hoping our setup code
    /// runs early enough, `InnerTubeClient` and `LyricsClient` reference
    /// `NetworkCache.session` directly as their default `URLSession`
    /// argument. That reference IS the trigger: the very first time either
    /// client is constructed, this closure runs, builds the sized cache,
    /// installs it as `URLCache.shared` (so `AsyncImage`, which only starts
    /// downloading once views actually appear on screen, always after app
    /// launch, picks it up too), and only then hands back a configured
    /// session. There's no ordering race to get wrong.
    static let session: URLSession = {
        // `URLCache(memoryCapacity:diskCapacity:directory:)` creates a new
        // cache backed by a folder inside the app's Caches directory.
        // WHY Caches (not Documents): Caches is explicitly meant for
        // regenerable data, iOS is allowed to delete it under low disk
        // space, and it's excluded from iCloud/iTunes backups. That's
        // exactly the right semantics for "downloaded thumbnails we can
        // always re-fetch," and means this cache never bloats a user's
        // device backup.
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        let diskURL = cachesDirectory?.appendingPathComponent("NetworkResponseCache", isDirectory: true)

        let cache = URLCache(
            memoryCapacity: memoryCapacityBytes,
            diskCapacity: diskCapacityBytes,
            directory: diskURL
        )

        // Installing this as `URLCache.shared` is what makes `AsyncImage`
        // (and anything else using `URLSession.shared`) benefit from the
        // bigger cache too, since `URLSessionConfiguration.default`, the
        // configuration `URLSession.shared` uses, reads `URLCache.shared`.
        URLCache.shared = cache

        // Build our own session on top of the same cache, explicitly
        // (rather than relying on `.shared` picking up the global we just
        // set) so InnerTubeClient/LyricsClient don't depend on this
        // ordering trick working for `.shared` too, belt and suspenders.
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = cache
        // `.useProtocolCachePolicy` (the default) means: cache/reuse a
        // response only when the server's own `Cache-Control`/`Expires`
        // headers say it's OK to. We don't want to force caching that
        // ignores what the server tells us, see the file-level comment
        // above for why that matters for InnerTube's POST responses.
        configuration.requestCachePolicy = .useProtocolCachePolicy

        return URLSession(configuration: configuration)
    }()
}
