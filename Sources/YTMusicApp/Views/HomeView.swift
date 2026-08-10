import SwiftUI

// MARK: - Home Screen

/// The home screen showing recommended music, trending songs, and playlists.
///
/// HOW IT WORKS:
/// - Loads YouTube Music's home feed when the view first appears
/// - Displays content in horizontal carousels (like the YouTube Music app)
/// - User can pull down to refresh the feed
/// - Tapping a song starts playing it immediately
struct HomeView: View {

    /// The API client handles loading home feed data from YouTube.
    /// @EnvironmentObject = injected by the parent (ContentView/App),
    /// shared across all views in the app. It's a property wrapper, a
    /// special annotation that changes how a property behaves, that pulls
    /// a shared object out of the "environment" (a bag of values every view
    /// below the one that put them there can access) instead of us having
    /// to create or pass it in manually.
    @EnvironmentObject var apiClient: APIClient

    /// The audio player handles playing songs.
    @EnvironmentObject var audioPlayer: AudioPlayer

    /// The play count manager, provides most played song data.
    @EnvironmentObject var playCountManager: PlayCountManager

    /// The stats manager, provides listening-history signal for the
    /// "Made For You", "On Repeat", and "Recently Discovered" sections.
    @EnvironmentObject var statsManager: StatsManager

    /// The auto-generated "Made For You" mix. Loaded once via `.task` below
    /// (it involves network calls to fetch related songs), then kept in
    /// local state, unlike `homeSections`/`chartsSections` it isn't owned
    /// by `apiClient` because it's derived from local listening data plus
    /// the API, not a browse endpoint by itself.
    @State private var madeForYouMix: [SearchResult] = []

    var body: some View {
        // NavigationView adds a navigation bar with the title
        NavigationView {
            // ScrollView makes the content scrollable vertically
            ScrollView {
                // Which of the three states below we show depends entirely
                // on `apiClient`'s current data, this is "declarative UI":
                // we describe what each state looks like, and SwiftUI
                // re-renders automatically whenever `apiClient`'s published
                // properties change.
                homeContent
            }
            .navigationTitle("Home")
            // Show error banner if an API error occurred
            .overlay(alignment: .top) {
                if let error = apiClient.errorMessage {
                    ErrorBanner(message: error) {
                        Task { await apiClient.loadHome() }
                    }
                }
            }
            // .task runs async code when the view first appears.
            // It's like .onAppear but supports async/await.
            // We only load if homeSections is empty (avoids reloading on tab switch).
            .task {
                if apiClient.homeSections.isEmpty {
                    // `async let` starts both loads at the same time instead
                    // of one after another, so the screen appears sooner.
                    // Each `async let` is a placeholder for a background
                    // result; the two `await`s below then wait for both to
                    // finish.
                    // Load home feed and charts in parallel for faster loading
                    async let homeLoad: () = apiClient.loadHome()
                    async let chartsLoad: () = apiClient.loadCharts()
                    await homeLoad
                    await chartsLoad
                }
                // "Made For You" needs a handful of related-songs network
                // calls (see MadeForYouEngine), so it's kept separate from
                // the home/charts load above and only (re)built once per
                // appearance, not on every re-render.
                if madeForYouMix.isEmpty {
                    madeForYouMix = await MadeForYouEngine.build(stats: statsManager, apiClient: apiClient)
                }
            }
            // .refreshable enables pull-to-refresh (pull down from top).
            // This calls our closure when the user releases the pull.
            // Always reloads (doesn't check if empty) since user explicitly asked.
            .refreshable {
                // Reload both home and charts on pull-to-refresh
                async let homeLoad: () = apiClient.loadHome()
                async let chartsLoad: () = apiClient.loadCharts()
                await homeLoad
                await chartsLoad
                madeForYouMix = await MadeForYouEngine.build(stats: statsManager, apiClient: apiClient)
            }
        }
    }

    // MARK: - Home Content (Loading → Empty → Content state machine)

    /// Picks which of three states to show: an initial loading skeleton, an
    /// empty-feed message, or the actual home feed sections. Pulled out of
    /// `body` so the top-level `body` only has to describe the screen's
    /// overall structure (NavigationView + ScrollView + modifiers).
    ///
    /// `@ViewBuilder` lets this computed property contain an `if/else if/else`
    /// that returns a different concrete view from each branch, normally a
    /// Swift property can only return one fixed type, but `@ViewBuilder`
    /// secretly combines the branches into a single "either-or" view type.
    @ViewBuilder
    private var homeContent: some View {
        if apiClient.isLoading && apiClient.homeSections.isEmpty {
            // STATE 1: Initial load, show skeleton placeholders.
            // These look like the actual content cards but are gray
            // rectangles with a shimmer animation.
            LazyVStack(spacing: 24) {
                SkeletonSection()
                SkeletonSection()
                SkeletonSection()
            }
            .padding(.vertical)
        } else if apiClient.homeSections.isEmpty {
            // STATE 2: Loaded but nothing to show (empty home feed)
            HomeEmptyState()
        } else {
            // STATE 3: Content loaded, show the sections
            loadedSections
        }
    }

    /// The stack of carousels shown once the home feed has data: recently
    /// played, most played, trending charts, then the YouTube Music home
    /// feed sections.
    private var loadedSections: some View {
        // LazyVStack = vertical stack that creates views lazily
        // (only when they scroll into view, not all at once).
        // This is important for performance with many sections.
        LazyVStack(spacing: 24) {
            // ── RECENTLY PLAYED SECTION ───────────────────
            // Shows songs the user recently listened to.
            // Only shown if there are songs in the history.
            // `!audioPlayer.recentlyPlayed.isEmpty`, the `!` here is
            // boolean "not", flipping true/false; it means "the list is
            // NOT empty", i.e. there's at least one song.
            if !audioPlayer.recentlyPlayed.isEmpty {
                RecentlyPlayedSection(songs: audioPlayer.recentlyPlayed)
            }

            // ── MOST PLAYED SECTION ──────────────────────
            // Shows the user's most frequently played songs.
            // Cross-references play counts with the recently played
            // list to get full song metadata (title, artist, etc.)
            let mostPlayed = getMostPlayedSongs()
            if !mostPlayed.isEmpty {
                MostPlayedSection(songs: mostPlayed)
            }

            // ── ON REPEAT SECTION ────────────────────────
            // Songs in heavy rotation over the last few weeks (not all-time,
            // like Most Played above, see StatsManager.onRepeatSongs).
            let onRepeat = getOnRepeatSongs()
            if !onRepeat.isEmpty {
                OnRepeatSection(songs: onRepeat)
            }

            // ── RECENTLY DISCOVERED SECTION ──────────────
            // Songs the user started listening to for the first time in the
            // last couple weeks (and hasn't skipped away from every time).
            let discovered = getRecentlyDiscoveredSongs()
            if !discovered.isEmpty {
                RecentlyDiscoveredSection(songs: discovered)
            }

            // ── MADE FOR YOU SECTION ─────────────────────
            // Auto-generated mix blending the user's top artists with
            // YouTube's related-songs graph (see MadeForYouEngine). Unlike
            // the sections above, these are songs the user hasn't
            // necessarily played before.
            if !madeForYouMix.isEmpty {
                MadeForYouSection(results: madeForYouMix)
            }

            // ── TRENDING CHARTS SECTION ───────────────────
            // Shows top songs and trending content from YouTube Music.
            // Loaded separately from the home feed.
            if !apiClient.chartsSections.isEmpty {
                ForEach(apiClient.chartsSections) { section in
                    SectionView(section: section)
                }
            }

            // ── YOUTUBE MUSIC HOME FEED SECTIONS ──────────
            ForEach(apiClient.homeSections) { section in
                SectionView(section: section)
            }
        }
        .padding(.vertical)
    }

    // MARK: - Most Played Helper

    /// Get the user's most played songs with full metadata.
    ///
    /// Cross-references play counts from PlayCountManager with the
    /// recently played list to get complete song info (title, artist, etc.).
    /// Returns up to 10 songs sorted by play count.
    private func getMostPlayedSongs() -> [(song: NowPlaying, playCount: Int)] {
        let topPlayed = playCountManager.getMostPlayed(limit: 10)

        // Map play counts to full song objects using recently played as a lookup
        var result: [(song: NowPlaying, playCount: Int)] = []

        for item in topPlayed {
            // `first(where:)` scans the array and returns the first element
            // matching the condition, or `nil` if none match, that's why
            // we can `if let` it. This looks up the full song info
            // (title/artist/thumbnail) for a play-count entry that only
            // stores a video ID and a count.
            // Find the song in recently played to get full metadata
            if let song = audioPlayer.recentlyPlayed.first(where: { $0.id == item.videoId }) {
                result.append((song: song, playCount: item.count))
            }
        }

        return result
    }

    // MARK: - On Repeat / Recently Discovered Helpers

    /// Cross-references StatsManager's `onRepeatSongs()` (videoId + count)
    /// with `recentlyPlayed` to get full song metadata, the same pattern as
    /// `getMostPlayedSongs()` above.
    private func getOnRepeatSongs() -> [(song: NowPlaying, playCount: Int)] {
        var result: [(song: NowPlaying, playCount: Int)] = []
        for item in statsManager.onRepeatSongs(limit: 10) {
            if let song = audioPlayer.recentlyPlayed.first(where: { $0.id == item.videoId }) {
                result.append((song: song, playCount: item.count))
            }
        }
        return result
    }

    /// Cross-references StatsManager's `recentlyDiscoveredSongs()` with
    /// `recentlyPlayed` for full metadata.
    private func getRecentlyDiscoveredSongs() -> [NowPlaying] {
        var result: [NowPlaying] = []
        for item in statsManager.recentlyDiscoveredSongs(limit: 10) {
            if let song = audioPlayer.recentlyPlayed.first(where: { $0.id == item.videoId }) {
                result.append(song)
            }
        }
        return result
    }
}

// MARK: - Home Empty State

/// Shown when the home feed finished loading but returned no sections.
private struct HomeEmptyState: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "music.note")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("Welcome to YouTube Music")
                .font(.title2)

            Text("Your music, ad-free")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}

// MARK: - Section View

/// A single horizontal carousel section (like "Quick Picks" or "Trending").
///
/// Each section has a title and a horizontally scrolling list of items.
struct SectionView: View {

    /// The section data (title + list of items)
    let section: BrowseSection

    @EnvironmentObject var audioPlayer: AudioPlayer
    @EnvironmentObject var apiClient: APIClient

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section title (e.g. "Quick Picks", "Trending")
            Text(section.title)
                .font(.title3)
                .fontWeight(.bold)
                .padding(.horizontal)

            // ScrollView(.horizontal) = horizontal scrolling container
            // showsIndicators: false = hide the scroll bar dots
            ScrollView(.horizontal, showsIndicators: false) {
                // LazyHStack = horizontal stack with lazy view creation
                // (better performance for long lists)
                LazyHStack(spacing: 12) {
                    // `ForEach` walks through `section.items` and builds one
                    // view per element. `BrowseItem` conforms to
                    // `Identifiable` (has a stable `id`), which is how
                    // SwiftUI tells each card apart across re-renders.
                    ForEach(section.items) { item in
                        ItemCard(item: item)
                            .onTapGesture {
                                // When user taps a card, play that song
                                playItem(item)
                            }
                    }
                }
                .padding(.horizontal) // Indent cards from screen edges
            }
        }
    }

    // MARK: - Playback

    /// Play an item when the user taps it.
    ///
    /// FLOW:
    /// 1. We have a BrowseItem with just the video ID and metadata
    /// 2. We need to call getPlayerInfo() to get the actual audio streaming URL
    /// 3. Once we have the streaming URL, we pass it to AudioPlayer to play
    ///
    /// This 2-step process (metadata → stream URL) is because YouTube doesn't
    /// include streaming URLs in browse/search responses, they're only
    /// available from the player endpoint, and they expire after a few hours.
    private func playItem(_ item: BrowseItem) {
        // Task = start an async operation without blocking the UI
        Task {
            do {
                // Step 1: Get the streaming URL from YouTube's player endpoint
                let playerInfo = try await apiClient.getPlayerInfo(videoId: item.id)

                // Step 2: Tell the audio player to play this song
                // `await` because AudioPlayer's play() method is also async
                await audioPlayer.play(
                    videoId: playerInfo.videoId,
                    title: playerInfo.title,
                    artist: playerInfo.artist,
                    thumbnailUrl: playerInfo.thumbnailUrl,
                    audioUrl: playerInfo.audioUrl,
                    duration: playerInfo.duration
                )
            } catch {
                // If anything fails (network error, invalid URL, etc.),
                // log it for debugging. In production, we'd show an alert.
                print("Failed to play item: \(error)")
            }
        }
    }
}

// MARK: - Item Card

/// A single card in the horizontal carousel.
///
/// Shows: thumbnail image, title, and subtitle (artist/playlist name).
/// The card is a fixed width (160pt) so carousels scroll smoothly.
struct ItemCard: View {

    /// The item data to display
    let item: BrowseItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Album art thumbnail
            // AsyncImage loads the URL asynchronously and shows a placeholder while loading
            AsyncImage(url: URL(string: item.thumbnailUrl)) { image in
                image
                    .resizable() // Allow resizing to fit frame
                    .aspectRatio(contentMode: .fill) // Fill the frame (may crop)
            } placeholder: {
                // Gray box with music note while image loads
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay(
                        Image(systemName: "music.note")
                            .foregroundColor(.secondary)
                    )
            }
            .frame(width: 160, height: 160)
            .cornerRadius(8)

            // Title (e.g. "Bohemian Rhapsody")
            Text(item.title)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2) // Allow 2 lines, truncate with "..." if longer
                .frame(width: 160, alignment: .leading)

            // Subtitle (e.g. "Queen" or "Playlist • 50 songs")
            Text(item.subtitle)
                .font(.caption) // Smaller font
                .foregroundColor(.secondary) // Gray
                .lineLimit(1)
                .frame(width: 160, alignment: .leading)
        }
    }
}

// MARK: - Recently Played Section

/// A horizontal carousel showing recently played songs.
///
/// Similar to YouTube Music's "Recently Played" section on the home screen.
/// Shows the last 20 songs played, most recent on the left.
struct RecentlyPlayedSection: View {

    /// The audio player for starting playback
    @EnvironmentObject var audioPlayer: AudioPlayer

    /// The list of recently played songs (most recent first)
    let songs: [NowPlaying]

    /// The song being viewed in SongDetailView
    @State private var selectedSong: NowPlaying?

    /// Whether to show the SongDetailView sheet
    @State private var showSongInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            Text("Recently Played")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.horizontal)

            // Horizontal scroll of song cards
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    // `songs.prefix(20)` takes at most the first 20 elements
                    // (fewer if the array is shorter). `Array(...)` converts
                    // that slice back into a plain array so `ForEach` can
                    // use it directly.
                    // Show up to 20 recent songs
                    ForEach(Array(songs.prefix(20))) { song in
                        RecentlyPlayedCard(
                            song: song,
                            onTap: { audioPlayer.addToQueueAndPlay(song) },
                            onShowInfo: {
                                selectedSong = song
                                showSongInfo = true
                            }
                        )
                    }
                }
                .padding(.horizontal)
            }
        }
        // `.sheet(isPresented:)` shows a modal card sliding up from the
        // bottom whenever the bound Bool (`$showSongInfo`) becomes true, and
        // dismisses it automatically when the Bool goes back to false (e.g.
        // the user swipes it away, which SwiftUI does for us and syncs back
        // into the binding).
        //
        // BUG FIX: previously `selectedSong`/`showSongInfo` were set by the
        // "Song Info" context-menu action but nothing ever presented a
        // sheet, so tapping "Song Info" appeared to do nothing, the state
        // was set but never read anywhere. This `.sheet` is what was
        // missing to actually show the song's detail view.
        .sheet(isPresented: $showSongInfo) {
            // `if let` unwraps the optional `selectedSong` safely. This
            // should always succeed since we only flip `showSongInfo` to
            // true right after setting `selectedSong`, but guarding with
            // `if let` (instead of force-unwrapping with `!`) means we never
            // risk a crash even if that assumption is ever violated.
            if let song = selectedSong {
                NavigationView {
                    SongDetailView(
                        videoId: song.id,
                        title: song.title,
                        artist: song.artist,
                        thumbnailUrl: song.thumbnailUrl,
                        duration: "\(song.duration)"
                    )
                }
            }
        }
    }
}

/// One tappable card in the Recently Played carousel, with a long-press
/// context menu offering "Song Info".
private struct RecentlyPlayedCard: View {
    let song: NowPlaying

    /// Called when the card itself is tapped (plays the song).
    let onTap: () -> Void

    /// Called when the user picks "Song Info" from the long-press menu.
    let onShowInfo: () -> Void

    var body: some View {
        // `Button(action:)` makes its whole label tappable and runs
        // `action` (a closure, a block of code passed in as a value) when
        // tapped.
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                // Album art thumbnail
                AsyncImage(url: URL(string: song.thumbnailUrl)) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } placeholder: {
                    // Placeholder while loading
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .overlay(
                            Image(systemName: "music.note")
                                .foregroundColor(.secondary)
                        )
                }
                .frame(width: 120, height: 120)
                .cornerRadius(8)

                // Song title
                Text(song.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .frame(width: 120, alignment: .leading)

                // Artist name
                Text(song.artist)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)
            }
        }
        // `.contextMenu` attaches a long-press menu to this view, hold your
        // finger down on the card and this list of actions pops up.
        // Long-press menu with Song Info option
        .contextMenu {
            Button(action: onShowInfo) {
                Label("Song Info", systemImage: "info.circle")
            }
        }
    }
}

// MARK: - Most Played Section

/// A horizontal carousel showing the user's most frequently played songs.
///
/// Shows up to 10 songs with their play count displayed as a badge.
/// Tapping a song starts playing it immediately. Long-press shows Song Info.
struct MostPlayedSection: View {

    /// The audio player for starting playback
    @EnvironmentObject var audioPlayer: AudioPlayer

    /// The list of most played songs with their play counts
    let songs: [(song: NowPlaying, playCount: Int)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Section header
            HStack {
                Image(systemName: "flame.fill")
                    .foregroundColor(.orange)
                Text("Most Played")
                    .font(.title2)
                    .fontWeight(.bold)
            }
            .padding(.horizontal)

            // Horizontal scroll of song cards
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    // `enumerated()` pairs each element with its index
                    // (0, 1, 2, ...). We only need the index for the `id:`
                    // parameter below (tuples aren't `Identifiable` on their
                    // own), so `ForEach` is told explicitly to identify rows
                    // by `\.element.song.id`, the underlying song's id,
                    // via a "key path" (a `\.` expression that points at a
                    // property instead of reading it immediately).
                    ForEach(Array(songs.prefix(10).enumerated()), id: \.element.song.id) { _, item in
                        MostPlayedCard(song: item.song, playCount: item.playCount)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

/// One tappable card in the Most Played carousel, showing a play-count badge
/// over the thumbnail. Tapping navigates to that song's detail screen.
private struct MostPlayedCard: View {
    let song: NowPlaying
    let playCount: Int

    var body: some View {
        NavigationLink(destination: SongDetailView(
            videoId: song.id,
            title: song.title,
            artist: song.artist,
            thumbnailUrl: song.thumbnailUrl,
            duration: "\(song.duration)"
        )) {
            VStack(alignment: .leading, spacing: 6) {
                // `ZStack` layers its children on top of each other (unlike
                // VStack/HStack, which lay children out side by side).
                // `alignment: .topTrailing` pins the badge to the
                // thumbnail's top-right corner.
                ZStack(alignment: .topTrailing) {
                    // Album art thumbnail
                    AsyncImage(url: URL(string: song.thumbnailUrl)) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))
                            .overlay(
                                Image(systemName: "music.note")
                                    .foregroundColor(.secondary)
                            )
                    }
                    .frame(width: 120, height: 120)
                    .cornerRadius(8)

                    // Play count badge
                    Text("\(playCount)")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.orange)
                        .cornerRadius(8)
                        .padding(4)
                }

                // Song title
                Text(song.title)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .frame(width: 120, alignment: .leading)

                // Artist name
                Text(song.artist)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: 120, alignment: .leading)
            }
        }
    }
}

// MARK: - On Repeat Section

/// A horizontal carousel showing songs in heavy rotation over the last few
/// weeks (as opposed to `MostPlayedSection`, which is all-time).
struct OnRepeatSection: View {
    let songs: [(song: NowPlaying, playCount: Int)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "repeat.circle.fill")
                    .foregroundColor(.purple)
                Text("On Repeat")
                    .font(.title2)
                    .fontWeight(.bold)
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(songs.enumerated()), id: \.element.song.id) { _, item in
                        MostPlayedCard(song: item.song, playCount: item.playCount)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

// MARK: - Recently Discovered Section

/// A horizontal carousel showing songs the user started listening to for
/// the first time in the last couple weeks.
struct RecentlyDiscoveredSection: View {
    @EnvironmentObject var audioPlayer: AudioPlayer
    let songs: [NowPlaying]

    @State private var selectedSong: NowPlaying?
    @State private var showSongInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.yellow)
                Text("Recently Discovered")
                    .font(.title2)
                    .fontWeight(.bold)
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(songs) { song in
                        RecentlyPlayedCard(
                            song: song,
                            onTap: { audioPlayer.addToQueueAndPlay(song) },
                            onShowInfo: {
                                selectedSong = song
                                showSongInfo = true
                            }
                        )
                    }
                }
                .padding(.horizontal)
            }
        }
        .sheet(isPresented: $showSongInfo) {
            if let song = selectedSong {
                NavigationView {
                    SongDetailView(
                        videoId: song.id,
                        title: song.title,
                        artist: song.artist,
                        thumbnailUrl: song.thumbnailUrl,
                        duration: "\(song.duration)"
                    )
                }
            }
        }
    }
}

// MARK: - Made For You Section

/// A horizontal carousel showing the auto-generated "Made For You" mix (see
/// MadeForYouEngine). Unlike the sections above, these are `SearchResult`s
/// (metadata only, no streaming URL yet) rather than `NowPlaying`, the
/// streaming URL is resolved on tap, same as every other browse card.
struct MadeForYouSection: View {
    @EnvironmentObject var audioPlayer: AudioPlayer
    @EnvironmentObject var apiClient: APIClient
    let results: [SearchResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "wand.and.stars")
                    .foregroundColor(.pink)
                Text("Made For You")
                    .font(.title2)
                    .fontWeight(.bold)
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(results) { result in
                        ItemCard(item: BrowseItem(
                            id: result.id,
                            title: result.title,
                            subtitle: result.artist,
                            thumbnailUrl: result.thumbnailUrl,
                            type: .song
                        ))
                        .onTapGesture {
                            playSearchResult(result)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// Resolve the streaming URL and play, same 2-step flow as
    /// `SectionView.playItem(_:)`: browse/related results only include
    /// metadata, not the (short-lived) audio URL.
    private func playSearchResult(_ result: SearchResult) {
        Task {
            do {
                let playerInfo = try await apiClient.getPlayerInfo(videoId: result.id)
                await audioPlayer.play(
                    videoId: playerInfo.videoId,
                    title: playerInfo.title,
                    artist: playerInfo.artist,
                    thumbnailUrl: playerInfo.thumbnailUrl,
                    audioUrl: playerInfo.audioUrl,
                    duration: playerInfo.duration
                )
            } catch {
                print("Failed to play Made For You item: \(error)")
            }
        }
    }
}

// MARK: - Preview

#Preview {
    HomeView()
        .environmentObject(AudioPlayer())
        .environmentObject(APIClient())
        .environmentObject(PlayCountManager())
        .environmentObject(StatsManager())
}
