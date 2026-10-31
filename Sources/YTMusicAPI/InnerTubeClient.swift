import Foundation

/// The main client for talking to YouTube's InnerTube API
/// Based on Metrolist's approach - uses WEB_REMIX for most operations
/// All methods are async and return parsed Swift objects
class InnerTubeClient {
    
    // MARK: - Properties
    
    /// Base URL for all InnerTube API requests (YouTube Music)
    private let baseURL = "https://music.youtube.com/youtubei/v1"
    
    /// InnerTube WEB_REMIX client API key, required on every request URL.
    ///
    /// NOT hardcoded here on purpose: even though this specific key is
    /// YouTube's well-known PUBLIC "InnerTube WEB client" identifier (the
    /// same constant Google embeds client-side in every youtube.com page,
    /// and that yt-dlp/ytmusicapi/Metrolist/etc. all use identically, it's
    /// a client-type identifier, not a billed or account-linked credential),
    /// this project's policy is that anything key/token/credential-shaped
    /// gets pulled out of source into build-time config, no exceptions.
    ///
    /// The real value is injected via Config/Secrets.xcconfig (gitignored)
    /// → INFOPLIST_KEY_INNERTUBE_API_KEY (project.yml) → the app's
    /// Info.plist → read here at runtime. See Config/Secrets.example.xcconfig
    /// for the value and setup instructions.
    private let apiKey: String = {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "INNERTUBE_API_KEY") as? String,
              !key.isEmpty,
              key != "YOUR_INNERTUBE_API_KEY_HERE" else {
            fatalError("""
                Missing INNERTUBE_API_KEY. Copy Config/Secrets.example.xcconfig \
                to Config/Secrets.xcconfig, fill in the real key, then run \
                `xcodegen generate` and rebuild.
                """)
        }
        return key
    }()
    
    /// URL session for making HTTP requests
    private let session: URLSession
    
    /// Visitor data (obtained from YouTube, used for tracking)
    private var visitorData: String?
    
    /// Cookie for authentication (optional - only needed for logged-in features)
    private var cookie: String?
    
    // MARK: - Client Configurations
    
    /// WEB_REMIX - The main YouTube Music web client
    /// Used for: search, browse, get suggestions
    /// This is what the YouTube Music website uses
    private let webRemixClient = YouTubeClient(
        clientName: "WEB_REMIX",
        clientVersion: "1.20260114.03.00",
        clientId: "67",
        userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0",
        osVersion: nil,
        loginSupported: true
    )
    
    /// IOS - The iOS YouTube client
    /// Used for: player (getting streaming URLs)
    /// This pretends to be the official iOS YouTube app
    private let iosClient = YouTubeClient(
        clientName: "IOS",
        clientVersion: "21.03.1",
        clientId: "5",
        userAgent: "com.google.ios.youtube/21.03.1 (iPhone16,2; U; CPU iOS 18_2 like Mac OS X;)",
        osVersion: "18.2.22C152",
        loginSupported: false
    )
    
    /// TVHTML5 - TV client (fallback for player)
    /// Used when IOS client fails
    private let tvClient = YouTubeClient(
        clientName: "TVHTML5",
        clientVersion: "7.20260114.12.00",
        clientId: "7",
        userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)",
        osVersion: nil,
        loginSupported: true
    )
    
    // MARK: - Initialization
    
    /// Create a new InnerTube client
    /// - Parameter session: URL session to use (for testing, you can pass a mock).
    ///   Defaults to `NetworkCache.session`, a `URLSession` backed by a
    ///   properly-sized disk+memory cache instead of the tiny 10MB default
    ///   `URLSession.shared` normally uses. See NetworkCache.swift for what
    ///   this does (and, importantly, doesn't) cache and why.
    init(session: URLSession = NetworkCache.session) {
        self.session = session
    }
    
    // MARK: - Search
    
    /// Search for songs, albums, artists, or playlists
    /// - Parameter query: The search term (e.g. "Bohemian Rhapsody")
    /// - Returns: Array of search result items
    /// Search for songs, videos, albums, or artists on YouTube Music.
    ///
    /// - Parameters:
    ///   - query: The search text (e.g. "Bohemian Rhapsody")
    ///   - filter: Optional filter, "songs", "videos", "albums", or nil for all results
    /// - Returns: Array of search results matching the filter
    ///
    /// FILTERS:
    /// YouTube Music uses a `params` field with base64-encoded protobuf to filter results.
    /// Each filter has a different protobuf value that tells YouTube which tab to return.
    func search(query: String, filter: String? = nil) async throws -> [SearchResult] {
        // Map filter names to YouTube's protobuf params
        let params: String?
        switch filter {
        case "songs":
            params = "EgWKAQIIAWoMEA4QChADEAQQCRAF"      // Songs filter
        case "videos":
            params = "EgWKAQIQAWoMEA4QChADEAQQCRAF"      // Videos filter
        case "albums":
            params = "EgWKAQIYAWoMEA4QChADEAQQCRAF"      // Albums filter
        case "artists":
            params = "EgWKAQIgAWoMEA4QChADEAQQCRAF"      // Artists filter
        default:
            params = nil              // No filter, show all results
        }
        
        // Build the request body with WEB_REMIX client
        let body = SearchBody(
            context: webRemixClient.toContext(visitorData: visitorData),
            query: query,
            params: params
        )
        
        // Make the request to YouTube
        let response: SearchResponse = try await POST(
            endpoint: "/search",
            client: webRemixClient,
            body: body
        )
        
        // Parse the response into our simple SearchResult model
        return parseSearchResults(from: response)
    }
    
    // MARK: - Player
    
    /// Get streaming URLs for a video/song
    /// - Parameters:
    ///   - videoId: The YouTube video ID (e.g. "dQw4w9WgXcQ")
    ///   - quality: Audio quality preference ("low", "medium", "high", or "auto" for best)
    /// - Returns: Player info including stream URLs and video details
    func getPlayer(videoId: String, quality: String = "high") async throws -> PlayerInfo {
        // Try IOS client first (best for audio)
        do {
            return try await getPlayerWithClient(videoId: videoId, client: iosClient, quality: quality)
        } catch {
            // If IOS fails, try TV client as fallback
            print("IOS client failed, trying TV client: \(error)")
            return try await getPlayerWithClient(videoId: videoId, client: tvClient, quality: quality)
        }
    }
    
    /// Get player info with a specific client
    private func getPlayerWithClient(videoId: String, client: YouTubeClient, quality: String = "high") async throws -> PlayerInfo {
        do {
            return try await playerAttempt(videoId: videoId, client: client, quality: quality, bypassTokenCache: false)
        } catch let InnerTubeError.videoUnplayable(reason) where reason.localizedCaseInsensitiveContains("bot") {
            // "Sign in to confirm you're not a bot": one retry with a
            // freshly minted PO token before giving up on this
            // client (the caller then falls back to the TV client).
            return try await playerAttempt(videoId: videoId, client: client, quality: quality, bypassTokenCache: true)
        }
    }

    /// One player request, carrying a PO token from the home token
    /// provider when one is available (see PoTokenManager).
    private func playerAttempt(videoId: String, client: YouTubeClient, quality: String, bypassTokenCache: Bool) async throws -> PlayerInfo {
        let token = await PoTokenManager.shared.token(for: videoId, bypassCache: bypassTokenCache)

        let body = PlayerBody(
            context: client.toContext(visitorData: visitorData),
            videoId: videoId,
            serviceIntegrityDimensions: token.map { ServiceIntegrityDimensions(poToken: $0) }
        )

        let response: PlayerResponse = try await POST(
            endpoint: "/player",
            client: client,
            body: body
        )

        return try parsePlayerInfo(from: response, quality: quality)
    }
    
    // MARK: - Browse (Home, Trending, etc.)
    
    /// Browse a YouTube Music page (home, trending, charts, etc.)
    /// - Parameter browseId: The browse ID (e.g. "FEmusic_home" for home)
    /// - Returns: Array of content sections
    func browse(browseId: String, params: String? = nil) async throws -> [BrowseSection] {
        let body = BrowseBody(
            context: webRemixClient.toContext(visitorData: visitorData),
            browseId: browseId,
            params: params
        )
        
        let response: BrowseResponse = try await POST(
            endpoint: "/browse",
            client: webRemixClient,
            body: body
        )
        
        return parseBrowseSections(from: response)
    }
    
    // MARK: - Get Home Feed
    
    /// Get the YouTube Music home page
    /// - Returns: Array of content sections (quick picks, trending, etc.)
    func getHome() async throws -> [BrowseSection] {
        return try await browse(browseId: "FEmusic_home")
    }
    
    /// Get the YouTube Music charts/trending page
    /// - Returns: Array of content sections (top songs, trending videos, etc.)
    func getCharts() async throws -> [BrowseSection] {
        return try await browse(browseId: "FEmusic_charts")
    }
    
    /// Get related/recommended songs for a video.
    ///
    /// Uses the `next` endpoint which returns content related to the current video,
    /// including recommended songs, playlists, and music videos.
    ///
    /// - Parameter videoId: The YouTube video ID to get recommendations for
    /// - Returns: Array of SearchResult items (related songs)
    func getRelated(videoId: String) async throws -> [SearchResult] {
        let body = NextBody(
            context: webRemixClient.toContext(visitorData: visitorData),
            videoId: videoId
        )
        
        let response: NextResponse = try await POST(
            endpoint: "/next",
            client: webRemixClient,
            body: body
        )
        
        return parseRelatedContent(from: response)
    }
    
    // MARK: - Parse Related Content
    
    // MARK: - Get Search Suggestions
    
    /// Get autocomplete suggestions as user types
    /// - Parameter query: The partial search query
    /// - Returns: Array of suggestion strings
    func getSearchSuggestions(query: String) async throws -> [String] {
        let body = GetSearchSuggestionsBody(
            context: webRemixClient.toContext(visitorData: visitorData),
            input: query
        )
        
        let response: GetSearchSuggestionsResponse = try await POST(
            endpoint: "/music/get_search_suggestions",
            client: webRemixClient,
            body: body
        )
        
        // Parse suggestions from response
        return response.contents?
            .first?
            .searchSuggestionsSectionRenderer?
            .contents?
            .compactMap { $0.searchSuggestionRenderer?.suggestion?.runs?.map(\.text).joined() }
            ?? []
    }
    
    // MARK: - Artist Page
    
    /// Get full artist page data including top songs, albums, and related artists.
    ///
    /// - Parameter channelId: YouTube channel ID (e.g. "UC...")
    /// - Returns: ArtistInfo with songs, albums, and related artists
    func getArtist(channelId: String) async throws -> ArtistInfo {
        let sections = try await browse(browseId: channelId)
        
        // Parse header from the raw response
        let response: BrowseResponse = try await POST(
            endpoint: "/browse",
            client: webRemixClient,
            body: BrowseBody(
                context: webRemixClient.toContext(visitorData: visitorData),
                browseId: channelId,
                params: nil
            )
        )
        
        // Extract artist name and thumbnail from header
        let name: String
        let thumbnailUrl: String
        let subscriberCount: String?
        let description: String?
        
        if let immersiveHeader = response.header?.musicImmersiveHeaderRenderer {
            name = immersiveHeader.title?.text ?? "Unknown Artist"
            thumbnailUrl = immersiveHeader.thumbnail?.musicThumbnailRenderer?.thumbnail?.thumbnails?.last?.url ?? ""
            subscriberCount = immersiveHeader.subtitle?.text
            description = immersiveHeader.description?.text
        } else if let visualHeader = response.header?.musicVisualHeaderRenderer {
            name = visualHeader.title?.text ?? "Unknown Artist"
            thumbnailUrl = visualHeader.thumbnail?.musicThumbnailRenderer?.thumbnail?.thumbnails?.last?.url ?? ""
            subscriberCount = nil
            description = nil
        } else {
            name = "Unknown Artist"
            thumbnailUrl = ""
            subscriberCount = nil
            description = nil
        }
        
        // Parse sections into albums, top songs, and related artists
        var topSongs: [SearchResult] = []
        var albums: [AlbumInfo] = []
        var relatedArtists: [ArtistInfo] = []
        
        for section in sections {
            let sectionTitle = section.title.lowercased()
            
            if sectionTitle.contains("top") || sectionTitle.contains("popular") {
                // Top songs section, convert BrowseItems to SearchResults
                for item in section.items {
                    topSongs.append(SearchResult(
                        id: item.id,
                        title: item.title,
                        artist: item.subtitle,
                        thumbnailUrl: item.thumbnailUrl,
                        duration: nil
                    ))
                }
            } else if sectionTitle.contains("album") || sectionTitle.contains("single") || sectionTitle.contains("release") {
                // Albums / Singles section
                for item in section.items {
                    albums.append(AlbumInfo(
                        id: item.id,
                        title: item.title,
                        artist: item.subtitle,
                        year: nil,
                        thumbnailUrl: item.thumbnailUrl,
                        trackCount: nil,
                        tracks: nil
                    ))
                }
            } else if sectionTitle.contains("related") || sectionTitle.contains("similar") || sectionTitle.contains("fans") {
                // Related artists section
                for item in section.items {
                    relatedArtists.append(ArtistInfo(
                        id: item.id,
                        name: item.title,
                        thumbnailUrl: item.thumbnailUrl,
                        subscriberCount: nil,
                        description: nil,
                        topSongs: [],
                        albums: [],
                        relatedArtists: []
                    ))
                }
            } else {
                // Default: treat as songs (for sections like "Singles")
                for item in section.items {
                    if item.type == .song {
                        topSongs.append(SearchResult(
                            id: item.id,
                            title: item.title,
                            artist: item.subtitle,
                            thumbnailUrl: item.thumbnailUrl,
                            duration: nil
                        ))
                    } else {
                        albums.append(AlbumInfo(
                            id: item.id,
                            title: item.title,
                            artist: item.subtitle,
                            year: nil,
                            thumbnailUrl: item.thumbnailUrl,
                            trackCount: nil,
                            tracks: nil
                        ))
                    }
                }
            }
        }
        
        return ArtistInfo(
            id: channelId,
            name: name,
            thumbnailUrl: thumbnailUrl,
            subscriberCount: subscriberCount,
            description: description,
            topSongs: topSongs,
            albums: albums,
            relatedArtists: relatedArtists
        )
    }
    
    // MARK: - Album Page
    
    /// Get full album data including track list.
    ///
    /// - Parameter browseId: YouTube browse ID for the album (e.g. "MPREb_...")
    /// - Returns: AlbumInfo with full track list
    func getAlbum(browseId: String) async throws -> AlbumInfo {
        let sections = try await browse(browseId: browseId)
        
        // Parse header from raw response
        let response: BrowseResponse = try await POST(
            endpoint: "/browse",
            client: webRemixClient,
            body: BrowseBody(
                context: webRemixClient.toContext(visitorData: visitorData),
                browseId: browseId,
                params: nil
            )
        )
        
        // Extract album info from header
        let title: String
        let artist: String
        let thumbnailUrl: String
        var trackCount: Int? = nil
        var year: Int? = nil
        
        if let playlistHeader = response.header?.musicEditablePlaylistDetailHeaderRenderer?.header {
            title = playlistHeader.title?.text ?? "Unknown Album"
            
            // Subtitle is usually "Artist • Year • Track Count"
            let subtitle = playlistHeader.subtitle?.text ?? ""
            let parts = subtitle.components(separatedBy: "•").map { $0.trimmingCharacters(in: .whitespaces) }
            artist = parts.first ?? "Unknown Artist"
            if parts.count >= 2, let albumYear = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                year = albumYear
            }
            if parts.count >= 3, let count = Int(parts[2].trimmingCharacters(in: .whitespaces)) {
                trackCount = count
            }
            
            thumbnailUrl = playlistHeader.thumbnail?.musicThumbnailRenderer?.thumbnail?.thumbnails?.last?.url ?? ""
            
            // If header has song count, use it
            if let countText = playlistHeader.songCount?.text {
                let digits = countText.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                trackCount = Int(digits)
            }
        } else if let detailHeader = response.header?.musicDetailHeaderRenderer {
            title = detailHeader.title?.text ?? "Unknown Album"
            artist = detailHeader.subtitle?.text ?? "Unknown Artist"
            thumbnailUrl = detailHeader.thumbnail?.musicThumbnailRenderer?.thumbnail?.thumbnails?.last?.url ?? ""
        } else {
            title = "Unknown Album"
            artist = "Unknown Artist"
            thumbnailUrl = ""
        }
        
        // Parse tracks from the first section
        var tracks: [SearchResult] = []
        for section in sections {
            for item in section.items {
                tracks.append(SearchResult(
                    id: item.id,
                    title: item.title,
                    artist: item.subtitle,
                    thumbnailUrl: item.thumbnailUrl,
                    duration: nil
                ))
            }
        }
        
        return AlbumInfo(
            id: browseId,
            title: title,
            artist: artist,
            year: year,
            thumbnailUrl: thumbnailUrl,
            trackCount: tracks.isEmpty ? trackCount : tracks.count,
            tracks: tracks
        )
    }
    
    // MARK: - Explore / New Releases / Moods
    
    /// Get the YouTube Music explore page (new releases, moods, genres).
    ///
    /// - Returns: Array of explore categories
    func getExplore() async throws -> [ExploreCategory] {
        let sections = try await browse(browseId: "FEmusic_explore")
        
        return sections.map { section in
            ExploreCategory(title: section.title, items: section.items)
        }
    }
    
    /// Get new releases from YouTube Music.
    ///
    /// - Returns: Array of explore categories with new albums and singles
    func getNewReleases() async throws -> [ExploreCategory] {
        let sections = try await browse(browseId: "FEmusic_new_releases")
        
        return sections.map { section in
            ExploreCategory(title: section.title, items: section.items)
        }
    }
    
    /// Get mood and genre categories from YouTube Music.
    ///
    /// - Returns: Array of mood/genre categories
    func getMoodCategories() async throws -> [ExploreCategory] {
        let sections = try await browse(browseId: "FEmusic_moods_and_genres")
        
        return sections.map { section in
            ExploreCategory(title: section.title, items: section.items)
        }
    }
    
    /// Get playlists for a specific mood or genre.
    ///
    /// - Parameter params: The browse params for the mood category
    /// - Returns: Array of browse items (playlists)
    func getMoodPlaylists(params: String) async throws -> [BrowseItem] {
        let sections = try await browse(browseId: "FEmusic_moods_and_genres", params: params)
        
        // Flatten all items from all sections
        return sections.flatMap { $0.items }
    }
    
    // MARK: - Private Helpers
    
    /// Make a POST request to an InnerTube endpoint.
    ///
    /// This is a GENERIC function, `<T: Decodable>` means it can return
    /// any type that conforms to Decodable (our Codable models).
    /// The caller specifies what type they expect, and Swift decodes the
    /// JSON response into that type.
    ///
    /// `some Encodable` means the body can be any Encodable type.
    /// This is Swift's "opaque type" syntax (available in Swift 5.7+).
    ///
    /// - Parameters:
    ///   - endpoint: The API endpoint (e.g. "/search")
    ///   - client: The YouTube client to use (determines headers)
    ///   - body: The request body (will be encoded to JSON)
    /// - Returns: The decoded response of type T
    private func POST<T: Decodable>(endpoint: String, client: YouTubeClient, body: some Encodable) async throws -> T {
        // Build the URL with API key
        let urlString = "\(baseURL)\(endpoint)?key=\(apiKey)&prettyPrint=false"
        // Force-unwrap (!) is safe here because:
        // 1. baseURL is a static valid URL ("https://music.youtube.com/youtubei/v1")
        // 2. endpoint is always a valid path (e.g. "/search")
        // 3. apiKey is always a valid key
        // The resulting URL string is always valid. If this ever failed,
        // it would indicate a programming error, not a user input issue.
        let url = URL(string: urlString)!
        
        // Create the request
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        
        // Add the special headers that YouTube expects.
        // Without these headers, YouTube returns errors or different data.
        // Each header tells YouTube something about our "client":
        request.addValue("1", forHTTPHeaderField: "X-Goog-Api-Format-Version")   // API format version (required)
        request.addValue(client.clientId, forHTTPHeaderField: "X-YouTube-Client-Name")    // Client type (e.g. "67" for WEB_REMIX)
        request.addValue(client.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version") // Client version string
        request.addValue("https://music.youtube.com", forHTTPHeaderField: "X-Origin")      // Origin header (CORS)
        request.addValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")       // Referer (must match origin)
        
        // Add visitor data if we have it
        if let visitorData = visitorData {
            request.addValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id")
        }
        
        // Add cookie if we have it (for logged-in features)
        if let cookie = cookie {
            request.addValue(cookie, forHTTPHeaderField: "Cookie")
        }
        
        // Encode the body to JSON
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .useDefaultKeys
        request.httpBody = try encoder.encode(body)
        
        // Make the request with retry logic
        return try await withRetry(maxAttempts: 3) {
            let (data, response) = try await session.data(for: request)
            
            // Check for HTTP errors
            guard let httpResponse = response as? HTTPURLResponse else {
                throw InnerTubeError.invalidResponse
            }
            
            guard (200...299).contains(httpResponse.statusCode) else {
                throw InnerTubeError.httpError(statusCode: httpResponse.statusCode)
            }
            
            // Decode the JSON response
            let decoder = JSONDecoder()
            // YouTube's API returns snake_case keys (e.g. "video_id", "thumbnail_url")
            // but our Swift structs use camelCase (e.g. "videoId", "thumbnailUrl").
            // This strategy automatically converts snake_case → camelCase during decoding.
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                // If decoding fails, print the raw JSON for debugging
                if let jsonString = String(data: data, encoding: .utf8) {
                    print("Raw JSON response (first 1000 chars): \(jsonString.prefix(1000))")
                }
                throw InnerTubeError.decodingFailed(error)
            }
        }
    }
    
    /// Retry logic with exponential backoff.
    ///
    /// HOW IT WORKS:
    /// 1. Try the operation
    /// 2. If it fails with a server error (5xx), wait and retry
    /// 3. If it fails with a client error (4xx), don't retry (it's our fault)
    /// 4. Wait time doubles each retry: 0.5s → 1s → 2s (exponential backoff)
    /// 5. After maxAttempts, give up and throw the last error
    ///
    /// WHY:
    /// YouTube's servers occasionally return 503 (Service Unavailable) or
    /// timeout errors. These are usually temporary, retrying after a short
    /// wait usually succeeds. Client errors (400 Bad Request, 403 Forbidden)
    /// won't fix themselves, so we don't retry those.
    ///
    /// WHAT IS `block`?
    /// `block: () async throws -> T` is a "closure" parameter, a closure is
    /// a chunk of code (here, "the actual network request") that gets passed
    /// around and called later, just like a value. Instead of writing the
    /// retry loop separately for every kind of request, callers hand this
    /// function a closure containing whatever work they want retried, and
    /// `withRetry` calls it (`try await block()` below) as many times as needed.
    private func withRetry<T>(maxAttempts: Int, initialDelay: TimeInterval = 0.5, block: () async throws -> T) async throws -> T {
        var currentDelay = initialDelay
        var lastError: Error?
        
        for attempt in 0..<maxAttempts {
            do {
                return try await block()
            } catch let error as InnerTubeError {
                // Don't retry client errors (400-499), they won't fix themselves
                if case .httpError(let statusCode) = error, (400...499).contains(statusCode) {
                    throw error
                }
                lastError = error
                
                if attempt < maxAttempts - 1 {
                    // Wait before retrying
                    // Task.sleep requires nanoseconds, so we convert:
                    // currentDelay (seconds) × 1,000,000,000 = nanoseconds
                    try await Task.sleep(nanoseconds: UInt64(currentDelay * 1_000_000_000))
                    currentDelay *= 2 // Double the wait for next retry (exponential backoff)
                }
            } catch {
                lastError = error
                if attempt < maxAttempts - 1 {
                    try await Task.sleep(nanoseconds: UInt64(currentDelay * 1_000_000_000))
                    currentDelay *= 2
                }
            }
        }
        
        // All attempts failed, throw the last error
        throw lastError ?? InnerTubeError.invalidResponse
    }
    
    // MARK: - Response Parsers
    
    /// Parse search results from the raw response
    private func parseSearchResults(from response: SearchResponse) -> [SearchResult] {
        var results: [SearchResult] = []
        
        // Navigate the nested response structure
        guard let tabs = response.contents?.tabbedSearchResultsRenderer?.tabs else {
            return results
        }
        
        // Get the first tab (usually "All")
        guard let tabContent = tabs.first?.tabRenderer?.content?.sectionListRenderer?.contents else {
            return results
        }
        
        // Collect items from every section shape YouTube uses today:
        // music shelves, plain item sections, and the top-result card shelf.
        for section in tabContent {
            let itemGroups: [[MusicItem]?] = [
                section.musicShelfRenderer?.contents,
                section.itemSectionRenderer?.contents,
                section.musicCardShelfRenderer?.contents
            ]
            for case let items? in itemGroups {
                for item in items {
                    if let renderer = item.musicResponsiveListItemRenderer {
                        if let result = parseSearchItem(renderer) {
                            results.append(result)
                        }
                    }
                }
            }
        }
        
        return results
    }
    
    /// Parse a single search item
    private func parseSearchItem(_ renderer: MusicResponsiveListItemRenderer) -> SearchResult? {
        // Get the video ID. Current responses no longer put a watch
        // endpoint at the item level for songs: the ID now arrives in
        // playlistItemData, in the overlay play button, or in the
        // title run's endpoint. Try every known location.
        let videoId = renderer.navigationEndpoint?.watchEndpoint?.videoId
            ?? renderer.playlistItemData?.videoId
            ?? renderer.overlay?.musicItemThumbnailOverlayRenderer?.content?.musicPlayButtonRenderer?.playNavigationEndpoint?.watchEndpoint?.videoId
            ?? renderer.flexColumns?.first?.musicResponsiveListItemFlexColumnRenderer?.text?.runs?.first?.navigationEndpoint?.watchEndpoint?.videoId
        guard let videoId = videoId else {
            return nil
        }
        
        // Get title from first flex column
        let title = renderer.flexColumns?.first?.musicResponsiveListItemFlexColumnRenderer?.text?.text ?? "Unknown"
        
        // Get artist/subtitle from second flex column
        let artist = renderer.flexColumns?.dropFirst().first?.musicResponsiveListItemFlexColumnRenderer?.text?.text ?? "Unknown Artist"
        
        // Get thumbnail URL
        let thumbnailUrl = renderer.thumbnail?.musicThumbnailRenderer?.thumbnail?.thumbnails?.last?.url ?? ""
        
        // Get duration from overlay
        let duration = renderer.overlay?.musicItemThumbnailOverlayRenderer?.content?.musicResponsiveListItemOverlayLayout?.musicDurationText?.text
        
        return SearchResult(
            id: videoId,
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            duration: duration
        )
    }
    
    /// Parse player info from the response
    /// Parse player info from the API response.
    ///
    /// Selects the appropriate audio stream based on the quality setting:
    /// - "low": Target ~72kbps (saves storage/bandwidth)
    /// - "medium": Target ~128kbps (balanced)
    /// - "high": Target ~256kbps (best quality)
    /// - "auto": Always pick the highest bitrate available
    private func parsePlayerInfo(from response: PlayerResponse, quality: String = "high") throws -> PlayerInfo {
        // Check if the video is playable
        if let status = response.playabilityStatus, status.status != "OK" {
            throw InnerTubeError.videoUnplayable(reason: status.reason ?? "Unknown reason")
        }
        
        // Get video details
        guard let details = response.videoDetails else {
            throw InnerTubeError.noVideoDetails
        }
        
        // Get streaming data
        guard let streaming = response.streamingData else {
            throw InnerTubeError.noStreamingData
        }
        
        // Filter to audio-only streams
        let audioStreams = (streaming.adaptiveFormats ?? []).filter { $0.isAudio }
        guard !audioStreams.isEmpty else {
            throw InnerTubeError.noAudioStream
        }
        
        // AVPlayer cannot decode webm/opus streams, and YouTube often
        // serves opus at the HIGHEST bitrate — selecting by bitrate
        // alone picks an unplayable stream and playback silently never
        // starts. Restrict the selection pool to mp4/AAC streams
        // whenever one exists.
        let playableStreams = audioStreams.filter { $0.mimeType.contains("audio/mp4") }
        let selectionPool = playableStreams.isEmpty ? audioStreams : playableStreams
        
        // Select the best audio stream based on quality preference
        let selectedAudio: StreamFormat
        
        switch quality {
        case "low":
            // Pick the lowest bitrate that's at least 48kbps (avoid extremely low quality)
            selectedAudio = selectionPool
                .filter { $0.bitrate >= 48000 }
                .min(by: { $0.bitrate < $1.bitrate })
                ?? selectionPool.min(by: { $0.bitrate < $1.bitrate })!
            
        case "medium":
            // Pick the stream closest to 128kbps
            selectedAudio = selectionPool
                .min(by: { abs($0.bitrate - 128000) < abs($1.bitrate - 128000) })!
            
        case "high":
            // Pick the highest bitrate (best quality)
            selectedAudio = selectionPool
                .max(by: { $0.bitrate < $1.bitrate })!
            
        default:
            // "auto" or any unknown value, pick highest bitrate
            selectedAudio = selectionPool
                .max(by: { $0.bitrate < $1.bitrate })!
        }
        
        // Get thumbnail
        let thumbnailUrl = details.thumbnail?.thumbnails?.last?.url ?? ""
        
        return PlayerInfo(
            videoId: details.videoId,
            title: details.title,
            artist: details.author,
            thumbnailUrl: thumbnailUrl,
            duration: Int(details.lengthSeconds) ?? 0,
            audioUrl: selectedAudio.url ?? "",
            audioQuality: selectedAudio.audioQuality,
            viewCount: details.viewCount
        )
    }
    
    /// Parse related/recommended content from the next response.
    ///
    /// Extracts song recommendations from the watch next results.
    /// These appear as "Related" or "Recommended" on the player screen.
    private func parseRelatedContent(from response: NextResponse) -> [SearchResult] {
        var results: [SearchResult] = []
        
        // Navigate through the nested response structure
        guard let contents = response.contents?
            .singleColumnMusicWatchNextResultsRenderer?
            .results?
            .results?
            .contents else {
            return results
        }
        
        // Extract items from the content array
        for content in contents {
            // Try musicResponsiveListItemRenderer (songs)
            if let renderer = content.musicResponsiveListItemRenderer {
                if let item = parseSearchItem(renderer) {
                    results.append(item)
                }
            }
            
            // Try musicTwoRowItemRenderer (albums, playlists, artists)
            if let renderer = content.musicTwoRowItemRenderer {
                if let title = renderer.title?.runs?.first?.text,
                   let subtitle = renderer.subtitle?.runs?.first?.text {
                    // Extract video ID from navigation endpoint
                    let videoId = renderer.navigationEndpoint?.watchEndpoint?.videoId ?? ""
                    // Extract thumbnail via the thumbnailRenderer path
                    let thumbnail = renderer.thumbnailRenderer?.musicThumbnailRenderer?.thumbnail?.thumbnails?.first?.url ?? ""
                    
                    results.append(SearchResult(
                        id: videoId,
                        title: title,
                        artist: subtitle,
                        thumbnailUrl: thumbnail,
                        duration: nil
                    ))
                }
            }
        }
        
        return results
    }
    
    /// Parse browse sections from the response
    private func parseBrowseSections(from response: BrowseResponse) -> [BrowseSection] {
        var sections: [BrowseSection] = []
        
        guard let contents = response.contents else { return sections }
        
        // Navigate to the section list
        let sectionList = contents.singleColumnBrowseResultsRenderer?.tabs?.first?.tabRenderer?.content?.sectionListRenderer
        
        guard let sectionContents = sectionList?.contents else { return sections }
        
        for sectionContent in sectionContents {
            // Handle carousel shelves (horizontal scrolling rows)
            if let carousel = sectionContent.musicCarouselShelfRenderer {
                let title = carousel.header?.musicCarouselShelfBasicHeaderRenderer?.title?.text ?? "Untitled"
                var items: [BrowseItem] = []
                
                for item in carousel.contents ?? [] {
                    if let twoRow = item.musicTwoRowItemRenderer {
                        let itemTitle = twoRow.title?.text ?? ""
                        let subtitle = twoRow.subtitle?.text ?? ""
                        let thumbUrl = twoRow.thumbnailRenderer?.musicThumbnailRenderer?.thumbnail?.thumbnails?.last?.url ?? ""
                        let browseId = twoRow.navigationEndpoint?.browseEndpoint?.browseId
                        let videoId = twoRow.navigationEndpoint?.watchEndpoint?.videoId
                        
                        items.append(BrowseItem(
                            id: browseId ?? videoId ?? "",
                            title: itemTitle,
                            subtitle: subtitle,
                            thumbnailUrl: thumbUrl,
                            type: browseId != nil ? .playlist : .song
                        ))
                    }
                    
                    if let listItem = item.musicResponsiveListItemRenderer {
                        if let result = parseSearchItem(listItem) {
                            items.append(BrowseItem(
                                id: result.id,
                                title: result.title,
                                subtitle: result.artist,
                                thumbnailUrl: result.thumbnailUrl,
                                type: .song
                            ))
                        }
                    }
                }
                
                sections.append(BrowseSection(title: title, items: items))
            }
            
            // Handle music shelves (vertical lists)
            if let shelf = sectionContent.musicShelfRenderer {
                let title = shelf.title?.text ?? "Untitled"
                var items: [BrowseItem] = []
                
                for item in shelf.contents ?? [] {
                    if let renderer = item.musicResponsiveListItemRenderer {
                        if let result = parseSearchItem(renderer) {
                            items.append(BrowseItem(
                                id: result.id,
                                title: result.title,
                                subtitle: result.artist,
                                thumbnailUrl: result.thumbnailUrl,
                                type: .song
                            ))
                        }
                    }
                }
                
                sections.append(BrowseSection(title: title, items: items))
            }
        }
        
        return sections
    }
}

// MARK: - Client Configuration

/// Configuration for a YouTube client type
struct YouTubeClient {
    let clientName: String
    let clientVersion: String
    let clientId: String
    let userAgent: String
    let osVersion: String?
    let loginSupported: Bool
    
    /// Convert this client to a context object for API requests
    func toContext(visitorData: String? = nil) -> InnerTubeContext {
        InnerTubeContext(
            client: InnerTubeClientInfo(
                clientName: clientName,
                clientVersion: clientVersion,
                deviceMake: "Apple",
                deviceModel: "iPhone16,2",
                hl: "en",
                gl: "US",
                osName: "iPhone",
                osVersion: osVersion ?? "18.2.0",
                userAgent: userAgent,
                visitorData: visitorData
            )
        )
    }
}

// MARK: - Request Body Models

/// Request body for search
struct SearchBody: Codable {
    let context: InnerTubeContext
    let query: String
    let params: String?  // Optional filter parameter (base64-encoded protobuf)
}

/// Request body for player
struct PlayerBody: Codable {
    let context: InnerTubeContext
    let videoId: String
    /// Proof-of-origin token (see PoTokenManager). Without it,
    /// YouTube answers anonymous player requests with
    /// LOGIN_REQUIRED ("Sign in to confirm you're not a bot").
    let serviceIntegrityDimensions: ServiceIntegrityDimensions?
}

/// The poToken container YouTube expects in player requests.
struct ServiceIntegrityDimensions: Codable {
    let poToken: String
}

/// Request body for browse
struct BrowseBody: Codable {
    let context: InnerTubeContext
    let browseId: String
    let params: String?
}

/// Request body for search suggestions
struct GetSearchSuggestionsBody: Codable {
    let context: InnerTubeContext
    let input: String
}

/// Request body for the /next endpoint (related/recommended content)
struct NextBody: Codable {
    let context: InnerTubeContext
    let videoId: String
}

// MARK: - Custom Errors

/// Errors that can occur when using the InnerTube API
enum InnerTubeError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)
    case decodingFailed(Error)
    case videoUnplayable(reason: String)
    case noVideoDetails
    case noStreamingData
    case noAudioStream
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let statusCode):
            return "HTTP error \(statusCode)"
        case .decodingFailed(let error):
            return "Failed to decode response: \(error.localizedDescription)"
        case .videoUnplayable(let reason):
            return "Video is unplayable: \(reason)"
        case .noVideoDetails:
            return "No video details in response"
        case .noStreamingData:
            return "No streaming data in response"
        case .noAudioStream:
            return "No audio stream found"
        }
    }
}
