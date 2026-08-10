import SwiftUI

// MARK: - Artist View

/// Full artist page showing top songs, albums, singles, and related artists.
///
/// HOW IT WORKS:
/// - Uses the `browse` API with the artist's channel ID (e.g. "UC...")
/// - Parses the response into an ArtistInfo model with all sections
/// - Top songs are playable directly
/// - Albums navigate to AlbumView for full track list
/// - Related artists navigate to another ArtistView (recursive)
struct ArtistView: View {

    // MARK: - Properties

    /// YouTube channel ID for this artist.
    /// `let` means it's fixed for the lifetime of this view, set once when
    /// the view is created (e.g. by whoever navigated here) and never
    /// reassigned.
    let channelId: String

    /// The API client for fetching artist data.
    /// `@EnvironmentObject` reads a shared object placed into the SwiftUI
    /// "environment" further up the view hierarchy (in this app, by the
    /// App's root view), it lets any descendant view use the same shared
    /// instance without it being passed explicitly through every view's
    /// initializer.
    @EnvironmentObject var apiClient: APIClient

    /// The audio player for playing songs. Also shared via the environment.
    @EnvironmentObject var audioPlayer: AudioPlayer

    /// The artist data (loaded from API).
    /// `ArtistInfo?` is an OPTIONAL: it's `nil` until the network request
    /// finishes successfully. `@State` marks this as a value owned by this
    /// view, SwiftUI watches it and automatically redraws `body` whenever
    /// it changes.
    @State private var artist: ArtistInfo?

    /// Whether the artist data is currently loading.
    @State private var isLoading = true

    /// Error message if loading fails (nil = no error).
    @State private var errorMessage: String?

    // MARK: - Body

    var body: some View {
        // `Group` combines the three mutually-exclusive states below
        // (loading / error / loaded) into a single view for `body` to
        // return, without adding any layout of its own.
        Group {
            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else if let artist = artist {
                // `if let artist = artist` unwraps the optional `artist`
                // state property into a plain, non-optional local constant
                // (SwiftUI allows a local name to "shadow"/reuse the outer
                // property's name), so the sections below can read its
                // properties directly.
                loadedView(artist)
            }
        }
        // `.task` runs this async closure automatically once, when the view
        // first appears on screen (and cancels it automatically if the view
        // goes away before it finishes), this is what kicks off loading.
        .task {
            await loadArtist()
        }
    }

    // MARK: - Loading State

    /// Skeleton placeholders shown while artist data is being fetched, so
    /// the layout doesn't jump once real content arrives.
    private var loadingView: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Artist avatar skeleton
                SkeletonView(width: 120, height: 120, cornerRadius: 60)

                // Name skeleton
                SkeletonView(width: 200, height: 24, cornerRadius: 4)

                // Subscriber count skeleton
                SkeletonView(width: 150, height: 16, cornerRadius: 4)

                // Top songs skeleton
                SkeletonSection()

                // Albums skeleton
                SkeletonSection()
            }
            .padding()
        }
    }

    // MARK: - Error State

    /// Shown when the network request fails: an icon, the error message,
    /// and a button that retries `loadArtist()`.
    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            Text("Failed to load artist")
                .font(.title2)
                .fontWeight(.bold)
            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                // `Task { ... }` starts a new concurrent unit of work so we
                // can call the `async` function `loadArtist()` here, the
                // button's action closure itself is not `async` and can't
                // directly `await`.
                Task { await loadArtist() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - Loaded State

    /// The fully-loaded artist screen: header plus whichever sections have
    /// content (top songs, albums, related artists).
    private func loadedView(_ artist: ArtistInfo) -> some View {
        ScrollView {
            VStack(spacing: 24) {
                // Artist header
                artistHeader(artist)

                // Top songs section, only shown if there's at least one
                // song, so we don't render an empty section header.
                if !artist.topSongs.isEmpty {
                    topSongsSection(artist.topSongs)
                }

                // Albums section
                if !artist.albums.isEmpty {
                    albumsSection(artist.albums)
                }

                // Related artists section
                if !artist.relatedArtists.isEmpty {
                    relatedArtistsSection(artist.relatedArtists)
                }
            }
            .padding(.bottom, 100) // Space for mini player
        }
        .navigationTitle(artist.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Load Artist

    /// Fetch artist data from the API.
    /// Marked `async` because it awaits a network call; `async` functions
    /// can suspend at `await` points without blocking the main thread, so
    /// the UI (e.g. the loading skeleton) stays responsive while we wait.
    private func loadArtist() async {
        isLoading = true
        errorMessage = nil

        do {
            // `try await` awaits the network response AND, if it throws an
            // error, jumps straight to the `catch` block below instead of
            // crashing the app, Swift's structured error handling.
            artist = try await apiClient.getArtist(channelId: channelId)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
    
    // MARK: - Artist Header
    
    /// The artist header with avatar, name, and subscriber count.
    private func artistHeader(_ artist: ArtistInfo) -> some View {
        VStack(spacing: 12) {
            // Avatar.
            // This is the "phase" form of `AsyncImage`: the closure receives
            // an `AsyncImagePhase` describing exactly how the download is
            // going, and we `switch` over it to show the right view for
            // each case. `@unknown default` is required by Swift whenever
            // you switch over an enum from a library you don't control
            // (like this one from SwiftUI), it's a safety net that handles
            // any future case Apple might add without breaking this code.
            AsyncImage(url: URL(string: artist.thumbnailUrl)) { phase in
                switch phase {
                case .success(let image):
                    // `let image` "binds" (extracts) the loaded `Image` out
                    // of the `.success` case so the lines below can use it.
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 120, height: 120)
                        .clipShape(Circle())
                case .failure:
                    // Fallback icon shown if the download fails
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 120))
                        .foregroundColor(.secondary)
                case .empty:
                    // Shown while still downloading
                    ProgressView()
                        .frame(width: 120, height: 120)
                @unknown default:
                    EmptyView()
                }
            }

            // Name
            Text(artist.name)
                .font(.title)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
            
            // Subscriber count, optional, so only shown if the API
            // actually returned one.
            if let subscribers = artist.subscriberCount {
                Text(subscribers)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            // Description (collapsed).
            // `if let description = artist.description, !description.isEmpty`
            // chains two conditions: first unwrap the optional `description`,
            // THEN (only if that succeeded) also check it isn't an empty
            // string, both must be true for the `Text` to appear.
            if let description = artist.description, !description.isEmpty {
                Text(description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding(.horizontal)
        .padding(.top)
    }

    // MARK: - Top Songs Section

    /// A list of the artist's most popular songs (top 10).
    private func topSongsSection(_ songs: [SearchResult]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            HStack {
                Image(systemName: "music.note.list")
                    .foregroundColor(.purple)
                Text("Top Songs")
                    .font(.title3)
                    .fontWeight(.bold)
            }
            .padding(.horizontal)

            // Song list.
            // `songs.prefix(10)` takes at most the first 10 songs (fewer if
            // the artist has less than 10), we only ever show a "top 10",
            // not the whole catalog. `.enumerated()` pairs each song with
            // its index (0, 1, 2, ...); wrapping in `Array(...)` gives
            // `ForEach` a concrete collection to iterate. `id: \.element.id`
            // tells `ForEach` to identify each row by the song's own `id`
            // property, which is how SwiftUI tracks which row is which.
            ForEach(Array(songs.prefix(10).enumerated()), id: \.element.id) { index, song in
                topSongRow(song, index: index)
            }
        }
    }

    /// A single tappable row in the top songs list: position number,
    /// thumbnail, title/artist, duration, and a play icon.
    private func topSongRow(_ song: SearchResult, index: Int) -> some View {
        Button {
            Task {
                await playSong(song)
            }
        } label: {
            HStack(spacing: 12) {
                // Position number (1-based for display)
                Text("\(index + 1)")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(width: 24)

                // Thumbnail.
                // `phase.image` is an optional `Image?` that's non-nil only
                // once the download succeeds, this `if let` covers both
                // the "still loading" and "failed" cases with one fallback.
                AsyncImage(url: URL(string: song.thumbnailUrl)) { phase in
                    if let image = phase.image {
                        image.resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 44, height: 44)
                            .cornerRadius(4)
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.secondary.opacity(0.3))
                            .frame(width: 44, height: 44)
                    }
                }

                // Title and artist
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .foregroundColor(.primary)
                    Text(song.artist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Duration (optional)
                if let duration = song.duration {
                    Text(duration)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Play icon
                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundColor(.purple)
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }
    
    // MARK: - Albums Section

    /// Horizontal carousel of the artist's albums and singles.
    private func albumsSection(_ albums: [AlbumInfo]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            HStack {
                Image(systemName: "square.stack")
                    .foregroundColor(.purple)
                Text("Albums & Singles")
                    .font(.title3)
                    .fontWeight(.bold)
            }
            .padding(.horizontal)

            // Horizontal scroll.
            // `ScrollView(.horizontal, ...)` makes the content inside scroll
            // sideways instead of the default up/down; `showsIndicators:
            // false` hides the little scrollbar SwiftUI would otherwise
            // draw, matching the "carousel" look used elsewhere in the app.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    // `ForEach(albums)` iterates the album list directly
                    // (no need for `.enumerated()` here since we don't use
                    // the index), this works because `AlbumInfo` conforms
                    // to `Identifiable`, so `ForEach` can find a stable `id`
                    // on each element automatically without us specifying one.
                    ForEach(albums) { album in
                        // `NavigationLink` makes its content tappable and,
                        // when tapped, pushes `destination` onto the current
                        // `NavigationStack`, here, another `AlbumView` for
                        // whichever album was tapped.
                        NavigationLink(destination: AlbumView(browseId: album.id)) {
                            albumCard(album)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// A single album/single card: artwork, title, and artist/type label.
    private func albumCard(_ album: AlbumInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            // Album art
            AsyncImage(url: URL(string: album.thumbnailUrl)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 140, height: 140)
                        .cornerRadius(8)
                case .failure:
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.secondary.opacity(0.3))
                        .frame(width: 140, height: 140)
                        .overlay(
                            Image(systemName: "music.note")
                                .foregroundColor(.secondary)
                        )
                case .empty:
                    ProgressView()
                        .frame(width: 140, height: 140)
                @unknown default:
                    EmptyView()
                }
            }

            // Album title
            Text(album.title)
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(2)
                .foregroundColor(.primary)
                .frame(width: 140, alignment: .leading)

            // Album type
            Text(album.artist)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(width: 140, alignment: .leading)
        }
    }
    
    // MARK: - Related Artists Section

    /// Horizontal carousel of related/similar artists.
    ///
    /// Each card navigates to ANOTHER `ArtistView` for that related artist,
    /// this is a "recursive" navigation: the same screen type can push
    /// another instance of itself onto the navigation stack (e.g. Artist A
    /// → related Artist B → related Artist C, indefinitely). SwiftUI/iOS
    /// handles this naturally since each `ArtistView` just holds its own
    /// `channelId` and loads independently.
    private func relatedArtistsSection(_ artists: [ArtistInfo]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Section header
            HStack {
                Image(systemName: "person.2.fill")
                    .foregroundColor(.purple)
                Text("Related Artists")
                    .font(.title3)
                    .fontWeight(.bold)
            }
            .padding(.horizontal)

            // Horizontal scroll
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    // `ArtistInfo` conforms to (i.e. implements the
                    // requirements of) the `Identifiable` protocol, which is
                    // why `ForEach(artists)` can identify each row without
                    // us writing an explicit `id:` parameter, "protocol
                    // conformance" is what lets generic SwiftUI APIs like
                    // `ForEach` work with many different model types.
                    ForEach(artists) { relatedArtist in
                        NavigationLink(destination: ArtistView(channelId: relatedArtist.id)) {
                            relatedArtistCard(relatedArtist)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    /// A single related-artist card: circular avatar plus name.
    private func relatedArtistCard(_ relatedArtist: ArtistInfo) -> some View {
        VStack(spacing: 8) {
            // Artist avatar
            AsyncImage(url: URL(string: relatedArtist.thumbnailUrl)) { phase in
                switch phase {
                case .success(let image):
                    image.resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 80, height: 80)
                        .clipShape(Circle())
                case .failure:
                    Circle()
                        .fill(.secondary.opacity(0.3))
                        .frame(width: 80, height: 80)
                        .overlay(
                            Image(systemName: "person.fill")
                                .foregroundColor(.secondary)
                        )
                case .empty:
                    ProgressView()
                        .frame(width: 80, height: 80)
                @unknown default:
                    EmptyView()
                }
            }

            // Artist name
            Text(relatedArtist.name)
                .font(.caption)
                .foregroundColor(.primary)
                .lineLimit(2)
                .frame(width: 80)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Play Song

    /// Fetch streaming URL and play the selected song.
    /// Marked `async` because it awaits a network call to resolve the
    /// actual playable audio URL for this song's video ID.
    private func playSong(_ song: SearchResult) async {
        do {
            let info = try await apiClient.getPlayerInfo(videoId: song.id)
            await audioPlayer.play(
                videoId: info.videoId,
                title: info.title,
                artist: info.artist,
                thumbnailUrl: info.thumbnailUrl,
                audioUrl: info.audioUrl,
                duration: info.duration
            )
        } catch {
            // Log rather than show an error UI, the user is mid-tap on a
            // list, so a console message is enough; a full error screen
            // here would be disruptive for what's usually a transient
            // network hiccup.
            print("Failed to play song: \(error)")
        }
    }
}
