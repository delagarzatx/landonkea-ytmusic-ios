import Foundation

/// All the data structures needed to talk to YouTube's InnerTube API.
///
/// WHY SO MANY STRUCTS?
/// YouTube's API returns deeply nested JSON. For example, a search response
/// looks like this (simplified):
///
/// ```json
/// {
///   "contents": {
///     "tabbedSearchResultsRenderer": {
///       "tabs": [{
///         "tabRenderer": {
///           "content": {
///             "sectionListRenderer": {
///               "contents": [{
///                 "musicShelfRenderer": {
///                   "contents": [{ ... }]
///                 }
///               }]
///             }
///           }
///         }
///       }]
///     }
///   }
/// }
/// ```
///
/// That's 7 levels of nesting! Each level needs its own Swift struct because
/// we can't decode arbitrary JSON, we need a struct for each object.
/// So we create one struct per nesting level (e.g. SearchResponse contains
/// TabbedSearchResultsRenderer, which contains TabRenderer, etc.).
///
/// All properties are optional (`?`) because YouTube's API omits fields
/// unpredictably. A field present in one response might be absent in another.
/// Making everything optional prevents decoding crashes.
///
/// These structs mirror YouTube's internal format exactly. They're NOT designed
/// for our UI, they're designed to match the JSON. We convert them to simpler
/// models (in Models.swift) before passing data to views.
///
/// Based on the open-source Metrolist project's InnerTube models.
///
/// WHAT IS "Codable"?
/// Every struct below conforms to the `Codable` protocol (you'll see
/// `: Codable` after almost every struct name). A "protocol" in Swift is
/// a contract: conforming to it means a type promises to provide certain
/// behavior. `Codable` is actually shorthand for two protocols combined,
/// `Decodable` (can be built FROM data, e.g. JSON bytes → a Swift struct)
/// and `Encodable` (can be turned INTO data, e.g. a Swift struct → JSON bytes).
/// The huge advantage: as long as a struct's property names/types line up
/// with the JSON shape, the Swift compiler auto-generates all the
/// conversion code for us, we never manually write "read this JSON key,
/// put it in this property" by hand. `JSONDecoder`/`JSONEncoder` (used in
/// InnerTubeClient.swift) do that conversion at runtime using this
/// compiler-generated code. This process of turning JSON text into typed
/// Swift values is called "decoding" (and the reverse, "encoding").

// MARK: - Context Models

/// The context object that every InnerTube request needs
/// It tells YouTube which "client" we're pretending to be
struct InnerTubeContext: Codable {
    let client: InnerTubeClientInfo
}

/// Information about which YouTube client we're impersonating
struct InnerTubeClientInfo: Codable {
    let clientName: String      // e.g. "WEB_REMIX" or "IOS"
    let clientVersion: String   // e.g. "1.20260114.03.00"
    let deviceMake: String      // e.g. "Apple"
    let deviceModel: String     // e.g. "iPhone16,2"
    let hl: String              // language, e.g. "en"
    let gl: String              // country, e.g. "US"
    let osName: String          // e.g. "iPhone"
    let osVersion: String       // e.g. "18.2.0"
    let userAgent: String       // browser/device user agent string
    let visitorData: String?    // optional visitor tracking data
}

// MARK: - Search Response

/// Response from a search request
struct SearchResponse: Codable {
    let contents: SearchContents?
}

/// Contents of search results
struct SearchContents: Codable {
    let tabbedSearchResultsRenderer: TabbedSearchResults?
}

/// Tabbed search results (All, Songs, Videos, Albums, etc.)
struct TabbedSearchResults: Codable {
    let tabs: [SearchTab]?
}

/// A single search tab
struct SearchTab: Codable {
    let tabRenderer: TabRenderer?
}

/// Tab renderer with content
struct TabRenderer: Codable {
    let content: TabContent?
}

/// Content inside a tab
struct TabContent: Codable {
    let sectionListRenderer: SectionListRenderer?
}

/// A list of sections
struct SectionListRenderer: Codable {
    let contents: [SectionContent]?
}

/// A single section
struct SectionContent: Codable {
    let musicShelfRenderer: MusicShelfRenderer?
    let musicCarouselShelfRenderer: MusicCarouselShelfRenderer?
    let itemSectionRenderer: ItemSectionRenderer?
    let musicCardShelfRenderer: MusicCardShelfRenderer?
}

/// A plain item section (current search responses group results this way)
struct ItemSectionRenderer: Codable {
    let contents: [MusicItem]?
}

/// The "top result" card shelf (first section of unfiltered search)
struct MusicCardShelfRenderer: Codable {
    let contents: [MusicItem]?
}

/// A shelf/section of music items
struct MusicShelfRenderer: Codable {
    let title: TextRun?
    let contents: [MusicItem]?
}

/// Individual music item
struct MusicItem: Codable {
    let musicResponsiveListItemRenderer: MusicResponsiveListItemRenderer?
}

/// A music list item with full details
struct MusicResponsiveListItemRenderer: Codable {
    let flexColumns: [FlexColumn]?
    let thumbnail: ThumbnailContainer?
    let overlay: ItemOverlay?
    let navigationEndpoint: NavigationEndpoint?
    let playlistItemData: PlaylistItemData?
}

/// Per-item playback data (current responses carry the videoId here —
/// the item-level navigationEndpoint is no longer sent for songs)
struct PlaylistItemData: Codable {
    let videoId: String?
}

/// A flexible column in the list item layout
struct FlexColumn: Codable {
    let musicResponsiveListItemFlexColumnRenderer: FlexColumnRenderer?
}

/// The actual content of a flex column
struct FlexColumnRenderer: Codable {
    let text: TextRun?
}

/// Text that can be either a simple string or a run of text
struct TextRun: Codable {
    let runs: [Run]?       // array of text segments
    let simpleText: String? // or just a plain string
    
    /// Convenience to get the full text as a single string
    var text: String {
        if let simpleText = simpleText {
            return simpleText
        }
        return runs?.map(\.text).joined() ?? ""
    }
}

/// A single segment of text
struct Run: Codable {
    let text: String
    let navigationEndpoint: NavigationEndpoint?
}

// MARK: - Navigation

/// Tells the app where to go when something is tapped
struct NavigationEndpoint: Codable {
    let watchEndpoint: WatchEndpoint?
    let browseEndpoint: BrowseEndpoint?
}

/// Endpoint for watching/playing a video
struct WatchEndpoint: Codable {
    let videoId: String?
    let playlistId: String?
    let index: Int?
}

/// Endpoint for browsing a page
struct BrowseEndpoint: Codable {
    let browseId: String?
    let params: String?
}

// MARK: - Thumbnails

/// Container for thumbnail images
struct ThumbnailContainer: Codable {
    let musicThumbnailRenderer: MusicThumbnailRenderer?
}

/// The actual thumbnail with its images
struct MusicThumbnailRenderer: Codable {
    let thumbnail: ThumbnailList?
}

/// The thumbnail set nested inside musicThumbnailRenderer
/// (the API nests it one level down: musicThumbnailRenderer.thumbnail.thumbnails)
struct ThumbnailList: Codable {
    let thumbnails: [Thumbnail]?
}

/// A single thumbnail image at a specific size
struct Thumbnail: Codable {
    let url: String
    let width: Int
    let height: Int
}

// MARK: - Overlay (for badges, duration, etc.)

/// Overlay info on top of an item
struct ItemOverlay: Codable {
    let musicItemThumbnailOverlayRenderer: MusicItemThumbnailOverlayRenderer?
}

/// The overlay content
struct MusicItemThumbnailOverlayRenderer: Codable {
    let content: OverlayContent?
}

/// What's in the overlay
struct OverlayContent: Codable {
    let musicResponsiveListItemOverlayLayout: OverlayLayout?
    let musicPlayButtonRenderer: MusicPlayButtonRenderer?
}

/// The overlay play button (its endpoint carries the videoId in
/// current responses)
struct MusicPlayButtonRenderer: Codable {
    let playNavigationEndpoint: NavigationEndpoint?
}

/// Layout of the overlay
struct OverlayLayout: Codable {
    let musicDurationText: TextRun?
}

// MARK: - Carousel (horizontal scrolling rows)

/// A horizontal carousel of music items
struct MusicCarouselShelfRenderer: Codable {
    let header: CarouselHeader?
    let contents: [CarouselItem]?
}

/// Header for a carousel section
struct CarouselHeader: Codable {
    let musicCarouselShelfBasicHeaderRenderer: CarouselHeaderRenderer?
}

/// The actual header content
struct CarouselHeaderRenderer: Codable {
    let title: TextRun?
}

/// A single item in a carousel
struct CarouselItem: Codable {
    let musicResponsiveListItemRenderer: MusicResponsiveListItemRenderer?
    let musicTwoRowItemRenderer: MusicTwoRowItemRenderer?
}

/// A two-row item (used for albums, playlists)
struct MusicTwoRowItemRenderer: Codable {
    let thumbnailRenderer: ThumbnailContainer?
    let title: TextRun?
    let navigationEndpoint: NavigationEndpoint?
    let subtitle: TextRun?
}

// MARK: - Player Response

/// Response from a player request
struct PlayerResponse: Codable {
    let playabilityStatus: PlayabilityStatus?
    let streamingData: StreamingData?
    let videoDetails: VideoDetails?
}

/// Status of whether a video can be played
struct PlayabilityStatus: Codable {
    let status: String          // "OK", "UNPLAYABLE", etc.
    let reason: String?         // why it can't be played
}

/// Contains the actual audio/video stream URLs
struct StreamingData: Codable {
    let formats: [StreamFormat]?          // combined audio+video
    let adaptiveFormats: [StreamFormat]?  // separate audio/video streams
    let expiresInSeconds: String?         // how long URLs are valid
}

/// A single stream format (audio or video)
struct StreamFormat: Codable {
    let itag: Int                    // format identifier
    let url: String?                 // direct URL to stream
    let mimeType: String             // e.g. "audio/mp4; codecs=\"mp4a.40.2\""
    let bitrate: Int                 // bits per second
    let width: Int?                  // video width (nil for audio)
    let height: Int?                 // video height (nil for audio)
    let contentLength: String?       // file size in bytes
    let approxDurationMs: String?    // duration in milliseconds
    
    /// Whether this is an audio-only stream
    var isAudio: Bool {
        return mimeType.contains("audio")
    }
    
    /// Whether this is a video stream
    var isVideo: Bool {
        return mimeType.contains("video")
    }
    
    /// Get the audio quality description
    var audioQuality: String {
        if bitrate >= 256000 { return "High" }
        if bitrate >= 128000 { return "Medium" }
        return "Low"
    }
}

/// Basic information about a video
struct VideoDetails: Codable {
    let videoId: String
    let title: String
    let lengthSeconds: String       // duration in seconds
    let channelId: String
    let author: String              // channel/artist name
    let viewCount: String
    let shortDescription: String?
    let thumbnail: VideoThumbnail?
}

/// Thumbnails for a video
struct VideoThumbnail: Codable {
    let thumbnails: [Thumbnail]?
}

// MARK: - Browse Response

/// Response from a browse request
struct BrowseResponse: Codable {
    let contents: BrowseContents?
    let header: BrowseHeader?  // Present for artist/album/channel pages
}

/// Header in a browse response (artist pages, album pages, etc.)
struct BrowseHeader: Codable {
    let musicImmersiveHeaderRenderer: MusicImmersiveHeaderRenderer?
    let musicVisualHeaderRenderer: MusicVisualHeaderRenderer?
    let musicEditablePlaylistDetailHeaderRenderer: MusicEditablePlaylistDetailHeaderRenderer?
    let musicDetailHeaderRenderer: MusicDetailHeaderRenderer?
}

/// Immersive header (used on artist pages)
struct MusicImmersiveHeaderRenderer: Codable {
    let title: TextRun?
    let subtitle: TextRun?
    let thumbnail: ThumbnailContainer?
    let subscriptionButton: SubscriptionButton?
    let description: TextRun?
}

/// Visual header (alternative artist page header)
struct MusicVisualHeaderRenderer: Codable {
    let title: TextRun?
    let thumbnail: ThumbnailContainer?
    let menu: MusicMenu?
}

/// Playlist detail header (used on album/playlist pages)
struct MusicEditablePlaylistDetailHeaderRenderer: Codable {
    let header: PlaylistDetailHeader?
}

/// Inner playlist detail header
struct PlaylistDetailHeader: Codable {
    let title: TextRun?
    let subtitle: TextRun?
    let songCount: TextRun?
    let totalDuration: TextRun?
    let thumbnail: ThumbnailContainer?
    let editHeader: PlaylistEditHeader?
}

/// Edit header (for playlist editing metadata)
struct PlaylistEditHeader: Codable {
    let musicPlaylistEditHeaderRenderer: MusicPlaylistEditHeaderRenderer?
}

/// Playlist edit header renderer
struct MusicPlaylistEditHeaderRenderer: Codable {
    let title: TextRun?
}

/// Detail header (used on some album/playlist pages)
struct MusicDetailHeaderRenderer: Codable {
    let title: TextRun?
    let subtitle: TextRun?
    let thumbnail: ThumbnailContainer?
}

/// Subscription button (on artist pages)
struct SubscriptionButton: Codable {
    let subscribeButtonRenderer: SubscribeButtonRenderer?
}

/// Subscribe button renderer
struct SubscribeButtonRenderer: Codable {
    let subscriberCountText: TextRun?
    let subscribed: Bool?
    let channelId: String?
}

/// Menu (overflow menu on headers)
struct MusicMenu: Codable {
    let menuRenderer: MenuRenderer?
}

/// Menu renderer
struct MenuRenderer: Codable {
    let items: [MenuItem]?
}

/// A single menu item
struct MenuItem: Codable {
    let menuNavigationItemRenderer: MenuNavigationItemRenderer?
}

/// Menu navigation item
struct MenuNavigationItemRenderer: Codable {
    let text: TextRun?
    let navigationEndpoint: NavigationEndpoint?
}

/// Contents of a browse response
struct BrowseContents: Codable {
    let singleColumnBrowseResultsRenderer: SingleColumnBrowseResults?
}

/// Single column browse results
struct SingleColumnBrowseResults: Codable {
    let tabs: [BrowseTab]?
}

/// A tab in browse results
struct BrowseTab: Codable {
    let tabRenderer: TabRenderer?
}

// MARK: - Search Suggestions Response

/// Response from search suggestions
struct GetSearchSuggestionsResponse: Codable {
    let contents: [SearchSuggestionsSection]?
}

/// A section of search suggestions
struct SearchSuggestionsSection: Codable {
    let searchSuggestionsSectionRenderer: SearchSuggestionsSectionRenderer?
}

/// The actual suggestions
struct SearchSuggestionsSectionRenderer: Codable {
    let contents: [SearchSuggestionItem]?
}

/// A single suggestion item
struct SearchSuggestionItem: Codable {
    let searchSuggestionRenderer: SearchSuggestionRenderer?
}

/// The suggestion text
struct SearchSuggestionRenderer: Codable {
    let suggestion: TextRun?
}

// MARK: - Next Endpoint Models (Related Content)

/// Response from the /next endpoint (related content)
struct NextResponse: Codable {
    let contents: NextContents?
}

/// Top-level contents of the next response
struct NextContents: Codable {
    let singleColumnMusicWatchNextResultsRenderer: SingleColumnWatchNext?
}

/// The watch next results container
struct SingleColumnWatchNext: Codable {
    let results: WatchNextResults?
}

/// Results container with the actual content
struct WatchNextResults: Codable {
    let results: WatchNextContents?
}

/// The contents array holding sections
struct WatchNextContents: Codable {
    let contents: [WatchNextContent]?
}

/// A single content item in the results
struct WatchNextContent: Codable {
    let musicResponsiveListItemRenderer: MusicResponsiveListItemRenderer?
    let musicTwoRowItemRenderer: MusicTwoRowItemRenderer?
}
