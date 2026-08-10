import SwiftUI

// MARK: - App Entry Point

/// The main entry point for the YouTube Music iOS app.
///
/// HOW SWIFTUI APPS WORK:
/// - The `@main` attribute tells Swift this is where the app starts
/// - `App` protocol requires a `body` property that returns a `Scene`
/// - `WindowGroup` creates the app's window (supports multiple windows on iPad/Mac)
/// - We inject shared objects via `.environmentObject()` so all child views can access them
///
/// OBJECT LIFECYCLE:
/// - `@StateObject` creates the object when the app launches and keeps it alive
/// - It's only created ONCE (not recreated when the view re-renders)
/// - The object persists for the entire app lifetime
@main
struct YTMusicApp: App {
    
    /// The shared audio player, one instance for the entire app.
    /// Created here, injected into the view hierarchy, and accessible
    /// from any view via @EnvironmentObject.
    /// @StateObject = "I own this object, create it once, keep it alive"
    @StateObject private var audioPlayer = AudioPlayer()
    
    /// The API client, handles all YouTube Music API calls.
    /// Also created once and shared with all views.
    @StateObject private var apiClient = APIClient()
    
    /// The offline manager, handles downloading and caching songs.
    /// Created once and shared with all views for offline playback.
    @StateObject private var offlineManager = OfflineManager()
    
    /// The search history manager, saves and loads recent search queries.
    /// Created once and shared with SearchView for displaying history.
    @StateObject private var searchHistory = SearchHistoryManager()
    
    /// The equalizer manager, handles audio frequency adjustments.
    /// Created once and shared with EqualizerView and PlayerView.
    @StateObject private var equalizer = EqualizerManager()
    
    /// The playlist manager, handles local playlists without login.
    /// Created once and shared with PlaylistsView and context menus.
    @StateObject private var playlistManager = PlaylistManager()
    
    /// The play count manager, tracks how many times each song was played.
    /// Created once and shared with AudioPlayer and HomeView.
    @StateObject private var playCountManager = PlayCountManager()
    
    /// The voice search manager, handles speech-to-text for voice search.
    /// Created once and shared with SearchBar for microphone input.
    @StateObject private var voiceSearch = VoiceSearchManager()
    
    /// The liked songs manager, tracks which songs the user has liked locally.
    @StateObject private var likedSongs = LikedSongsManager()
    
    /// The stats manager, tracks listening statistics.
    @StateObject private var statsManager = StatsManager()

    /// CloudKit sync for playlists + liked songs only (NOT listening
    /// stats, see CloudKitSyncManager.swift for the full scope/design
    /// writeup). Not `@StateObject`/observed by views, nothing in the UI
    /// reads its state directly, it just quietly keeps PlaylistManager and
    /// LikedSongsManager in sync with iCloud in the background.
    private let cloudKitSyncManager = CloudKitSyncManager()

    /// Set up the shared managers for AudioPlayer to access.
    init() {
        PlayCountManager.shared = playCountManager
        // The audio player checks EqualizerManager.shared to decide whether
        // to route local playback through the equalizer engine.
        EqualizerManager.shared = equalizer
        // The audio player checks LikedSongsManager.shared to wire up the
        // lock screen / Control Center "like"/"dislike" remote commands.
        LikedSongsManager.shared = likedSongs

        // Wire CloudKitSyncManager to read/apply PlaylistManager's and
        // LikedSongsManager's data without either manager needing to know
        // anything about CloudKit directly (see CloudKitSyncManager.swift's
        // header comment for the full rationale).
        let syncManager = cloudKitSyncManager
        let playlists = playlistManager
        let liked = likedSongs
        syncManager.getLocalPlaylists = { playlists.playlists }
        syncManager.applyMergedPlaylists = { merged in playlists.applyMergedPlaylists(merged) }
        syncManager.getLocalLikedEntries = { liked.currentLikedEntries() }
        syncManager.applyMergedLikedEntries = { merged in liked.applyMergedLikedEntries(merged) }

        // Trigger a sync whenever playlists or liked songs change locally,
        // and once at launch to pull down anything from other devices.
        // Both the manager and the notification handlers are @MainActor,
        // hopping through Task {@MainActor in ...} keeps this correct
        // regardless of which thread NotificationCenter delivers on.
        NotificationCenter.default.addObserver(forName: .playlistsDidChange, object: nil, queue: nil) { _ in
            Task { @MainActor in syncManager.syncNow() }
        }
        NotificationCenter.default.addObserver(forName: .likedSongsDidChange, object: nil, queue: nil) { _ in
            Task { @MainActor in syncManager.syncNow() }
        }
        Task { @MainActor in syncManager.syncNow() }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                // .environmentObject() makes these objects available to
                // ContentView and ALL of its descendant views.
                // Any view in the hierarchy can access them with:
                //   @EnvironmentObject var audioPlayer: AudioPlayer
                //   @EnvironmentObject var apiClient: APIClient
                //
                // This is SwiftUI's dependency injection system, instead of
                // passing objects through init parameters to every view,
                // we inject them once at the top and they're automatically
                // available everywhere below.
                .environmentObject(audioPlayer)
                .environmentObject(apiClient)
                .environmentObject(offlineManager)
                .environmentObject(searchHistory)
                .environmentObject(equalizer)
                .environmentObject(playlistManager)
                .environmentObject(playCountManager)
                .environmentObject(voiceSearch)
                .environmentObject(likedSongs)
                .environmentObject(statsManager)
        }
    }
}

// MARK: - API Client

/// A wrapper around InnerTubeClient that works with SwiftUI's data flow.
///
/// WHY THIS EXISTS:
/// InnerTubeClient is a plain Swift class. SwiftUI needs an ObservableObject
/// to automatically update views when data changes. This class:
/// 1. Holds the InnerTubeClient instance
/// 2. Caches results (search results, home feed) in @Published properties
/// 3. Manages loading state (isLoading) so views can show spinners
/// 4. Catches errors and stores them for views to display
///
/// @MainActor ensures all @Published property updates happen on the main thread,
/// which is required for SwiftUI to observe them correctly.
@MainActor
class APIClient: ObservableObject {
    
    /// The actual API client that makes HTTP requests to YouTube.
    /// This is NOT @Published because views don't need to observe it directly,
    /// they observe the results stored in @Published properties below.
    let client = InnerTubeClient()
    
    /// The latest search results. Views observe this to display results.
    /// When this changes, any view using @EnvironmentObject var apiClient: APIClient
    /// will automatically re-render to show the new results.
    @Published var searchResults: [SearchResult] = []
    
    /// The home feed sections (e.g. "Quick Picks", "Trending").
    /// Populated by loadHome(), displayed by HomeView.
    @Published var homeSections: [BrowseSection] = []
    
    /// Trending charts sections from YouTube Music.
    /// Populated by loadCharts(), displayed in HomeView.
    @Published var chartsSections: [BrowseSection] = []
    
    /// Whether an API request is currently in progress.
    /// Views use this to show loading spinners.
    @Published var isLoading: Bool = false
    
    /// Error message from the last failed request.
    /// Views can display this as an alert or banner.
    /// nil = no error.
    @Published var errorMessage: String?
    
    /// Search for songs on YouTube Music.
    ///
    /// - Parameters:
    ///   - query: The search term (e.g. "Bohemian Rhapsody")
    ///   - filter: Optional filter, "songs", "videos", "albums", or nil for all
    ///
    /// HOW IT WORKS:
    /// 1. Trim whitespace and check for empty query (prevents useless API calls)
    /// 2. Set isLoading = true (views show spinner)
    /// 3. Call the InnerTube API with optional filter
    /// 4. On success: store results in searchResults (views update)
    /// 5. On failure: store error message (views can show it)
    /// 6. Set isLoading = false (spinner disappears)
    func search(query: String, filter: String? = nil) async {
        // `.whitespacesAndNewlines` includes spaces, tabs, and newlines.
        // This prevents searching for "   " (just spaces).
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        
        isLoading = true
        errorMessage = nil
        
        do {
            let results = try await client.search(query: query, filter: filter)
            searchResults = results
        } catch {
            errorMessage = "Search failed: \(error.localizedDescription)"
            print("Search error: \(error)")
        }
        
        isLoading = false
    }
    
    /// Load the YouTube Music home feed (recommended songs, playlists, etc.).
    ///
    /// Called by HomeView on first appearance and on pull-to-refresh.
    func loadHome() async {
        isLoading = true
        errorMessage = nil
        
        do {
            let sections = try await client.getHome()
            homeSections = sections
        } catch {
            errorMessage = "Failed to load home: \(error.localizedDescription)"
            print("Home load error: \(error)")
        }
        
        isLoading = false
    }
    
    /// Load the YouTube Music trending charts.
    ///
    /// Called by HomeView to show top songs and trending content, typically
    /// alongside `loadHome()` (HomeView kicks them off together with
    /// `async let`, so both requests run concurrently instead of one after
    /// the other).
    ///
    /// Unlike `search`/`loadHome`, this intentionally does NOT touch
    /// `isLoading`/`errorMessage`, HomeView's loading spinner and error
    /// banner are driven by `loadHome()`, and charts are treated as a
    /// secondary, best-effort section: if this fails, we just log it and
    /// leave `chartsSections` as-is rather than surfacing an error to the user.
    func loadCharts() async {
        do {
            let sections = try await client.getCharts()
            chartsSections = sections
        } catch {
            print("Charts load error: \(error)")
        }
    }
    
    /// Get streaming info for a specific song (audio URL, duration, etc.).
    ///
    /// This is called before playing a song. We need it because search/browse
    /// responses don't include the actual audio streaming URL, only the player
    /// endpoint provides that.
    ///
    /// - Parameters:
    ///   - videoId: YouTube video ID (e.g. "dQw4w9WgXcQ")
    ///   - quality: Audio quality ("low", "medium", "high"), reads from UserDefaults
    /// - Returns: PlayerInfo with the streaming URL and metadata
    /// - Throws: If the API request fails or the video is unavailable
    func getPlayerInfo(videoId: String, quality: String? = nil) async throws -> PlayerInfo {
        // Use provided quality, or read from UserDefaults
        let effectiveQuality = quality ?? UserDefaults.standard.string(forKey: "streamQuality") ?? "high"
        return try await client.getPlayer(videoId: videoId, quality: effectiveQuality)
    }
    
    /// Get streaming info for downloads using the download quality setting.
    ///
    /// Separate from playback quality, lets users download lower quality to save storage.
    func getPlayerInfoForDownload(videoId: String) async throws -> PlayerInfo {
        let quality = UserDefaults.standard.string(forKey: "downloadQuality") ?? "high"
        return try await client.getPlayer(videoId: videoId, quality: quality)
    }
    
    /// Get related/recommended songs for a video.
    ///
    /// Returns songs similar to the one currently playing, based on YouTube's
    /// recommendation algorithm. Used to show "Related" section in the player.
    func getRelated(videoId: String) async throws -> [SearchResult] {
        return try await client.getRelated(videoId: videoId)
    }
    
    /// Get full artist page data.
    ///
    /// Used by ArtistView to display top songs, albums, and related artists.
    func getArtist(channelId: String) async throws -> ArtistInfo {
        return try await client.getArtist(channelId: channelId)
    }
    
    /// Get full album data with track list.
    ///
    /// Used by AlbumView to display album tracks and metadata.
    func getAlbum(browseId: String) async throws -> AlbumInfo {
        return try await client.getAlbum(browseId: browseId)
    }
    
    /// Get explore page data (new releases, moods, genres).
    func getExplore() async throws -> [ExploreCategory] {
        return try await client.getExplore()
    }
    
    /// Get new releases from YouTube Music.
    func getNewReleases() async throws -> [ExploreCategory] {
        return try await client.getNewReleases()
    }
    
    /// Get mood and genre categories.
    func getMoodCategories() async throws -> [ExploreCategory] {
        return try await client.getMoodCategories()
    }
    
    /// Get playlists for a specific mood/genre.
    func getMoodPlaylists(params: String) async throws -> [BrowseItem] {
        return try await client.getMoodPlaylists(params: params)
    }
}
