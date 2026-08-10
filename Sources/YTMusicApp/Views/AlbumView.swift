import SwiftUI

// MARK: - Album View

/// Full album page showing track list, album art, and metadata.
///
/// HOW IT WORKS:
/// - Uses the `browse` API with the album's browse ID (e.g. "MPREb_...")
/// - Parses the response into an AlbumInfo model
/// - Displays album art, title, artist, year, and full track list
/// - Each track is playable with a tap
struct AlbumView: View {

    // MARK: - Properties

    /// YouTube browse ID for this album.
    /// `let` (not `var`) means this never changes after the view is created,
    /// whoever navigates to this screen passes in the album they want to see.
    let browseId: String

    /// The API client for fetching album data.
    /// `@EnvironmentObject` means this object was created somewhere higher up
    /// in the view hierarchy (in this app, in the App's root) and "injected"
    /// into the environment so any descendant view can grab it, without it
    /// having to be passed explicitly through every initializer in between.
    @EnvironmentObject var apiClient: APIClient

    /// The audio player for playing tracks. Also shared via the environment.
    @EnvironmentObject var audioPlayer: AudioPlayer

    /// The album data (loaded from API).
    /// `AlbumInfo?` is an OPTIONAL, it starts as `nil` (no data yet) and
    /// becomes a real `AlbumInfo` once the network request finishes.
    /// `@State` means SwiftUI owns and tracks this value: whenever it
    /// changes, SwiftUI automatically re-runs `body` to update the screen.
    @State private var album: AlbumInfo?

    /// Whether the album data is currently loading.
    @State private var isLoading = true

    /// Error message if loading fails (nil = no error).
    @State private var errorMessage: String?

    // MARK: - Body

    var body: some View {
        // `Group` lets us return one of several different view trees below
        // (loading / error / loaded) from a single `body`, without `Group`
        // itself adding any visual effect or extra layout.
        Group {
            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else if let album = album {
                // This `if let` unwraps the optional `album` state property
                // into a non-optional local constant (also named `album`,
                // which "shadows"/hides the outer optional one inside this
                // branch) so the views below can use its properties directly
                // without needing `?` everywhere.
                loadedView(album)
            }
        }
        // `.task` runs an async block automatically when this view first
        // appears (and cancels it automatically if the view disappears
        // before it finishes), the standard SwiftUI way to kick off a
        // network request as soon as a screen is shown.
        .task {
            await loadAlbum()
        }
    }

    // MARK: - Loading State

    /// Skeleton placeholders shown while the album is being fetched.
    /// Mimics the eventual layout (art, title, artist, track rows) so the
    /// screen doesn't visually "jump" once real data arrives.
    private var loadingView: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Album art skeleton
                SkeletonView(width: 200, height: 200, cornerRadius: 12)

                // Title skeleton
                SkeletonView(width: 180, height: 24, cornerRadius: 4)

                // Artist skeleton
                SkeletonView(width: 140, height: 16, cornerRadius: 4)

                // Track list skeletons.
                // `ForEach(0..<8)` repeats the view inside its closure 8
                // times, `0..<8` is a Range (0 through 7). We don't care
                // about the actual number each time, so the closure's
                // parameter is named `_` to mean "ignore this value".
                ForEach(0..<8) { _ in
                    HStack {
                        SkeletonView(width: 40, height: 40, cornerRadius: 4)
                        VStack(alignment: .leading, spacing: 4) {
                            SkeletonView(width: 160, height: 14, cornerRadius: 2)
                            SkeletonView(width: 100, height: 12, cornerRadius: 2)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .padding()
        }
    }

    // MARK: - Error State

    /// Shown when the network request fails, an icon, message, and a retry
    /// button that re-runs `loadAlbum()`.
    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            Text("Failed to load album")
                .font(.title2)
                .fontWeight(.bold)
            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Try Again") {
                // `Task { ... }` starts a new unstructured concurrent task
                // so we can call the `async` function `loadAlbum()` from
                // inside a synchronous button action closure (button
                // actions themselves can't be marked `async`).
                Task { await loadAlbum() }
            }
            .buttonStyle(.bordered)
        }
        .padding()
    }

    // MARK: - Loaded State

    /// The fully-loaded album screen: header, play-all button, and track list.
    private func loadedView(_ album: AlbumInfo) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                // Album header
                albumHeader(album)

                // Play All button
                playAllButton(album)

                // Track list divider
                Divider()
                    .padding(.horizontal)

                // Track list
                trackList(album)
            }
            .padding(.bottom, 100)
        }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Load Album

    /// Fetch album data from the API.
    /// Marked `async` because it awaits a network call, `async` functions
    /// can pause at `await` points without blocking the app's main thread,
    /// so the UI stays responsive while we wait for the response.
    private func loadAlbum() async {
        isLoading = true
        errorMessage = nil

        do {
            // `try await` both awaits the async network call AND propagates
            // any error it throws up to the `catch` block below, instead of
            // crashing, this is Swift's structured error handling.
            album = try await apiClient.getAlbum(browseId: browseId)
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
    
    // MARK: - Album Header
    
    /// Album art, title, artist, and metadata.
    private func albumHeader(_ album: AlbumInfo) -> some View {
        VStack(spacing: 12) {
            // Album art.
            // This is the "phase" form of `AsyncImage`: instead of separate
            // success/placeholder closures, it gives us one closure with an
            // `AsyncImagePhase` value we can `switch` over, so we can show a
            // different view for each of the three possible states, still
            // loading, loaded successfully, or failed (e.g. bad URL, no
            // network). `switch` must handle every possible case of an enum,
            // which is why `@unknown default` exists below: it's a safety
            // net for any future case Apple might add to `AsyncImagePhase`
            // that this code doesn't explicitly know about yet.
            AsyncImage(url: URL(string: album.thumbnailUrl)) { phase in
                switch phase {
                case .success(let image):
                    // `let image` here "binds" the loaded image out of the
                    // `.success` case so we can use it below.
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 200, height: 200)
                        .cornerRadius(12)
                        .shadow(radius: 8)
                case .failure:
                    // Shown if the download fails, a placeholder icon
                    // instead of a broken image.
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.secondary.opacity(0.3))
                        .frame(width: 200, height: 200)
                        .overlay(
                            Image(systemName: "music.note")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary)
                        )
                case .empty:
                    // Shown while the image is still downloading.
                    ProgressView()
                        .frame(width: 200, height: 200)
                @unknown default:
                    EmptyView()
                }
            }

            // Title
            Text(album.title)
                .font(.title2)
                .fontWeight(.bold)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            // Artist
            Text(album.artist)
                .font(.body)
                .foregroundColor(.secondary)
            
            // Year and track count
            if let year = album.year {
                HStack(spacing: 8) {
                    Text("\(year)")
                    
                    if let count = album.trackCount {
                        Text("•")
                        Text("\(count) songs")
                    }
                }
                .font(.subheadline)
                .foregroundColor(.secondary)
            } else if let count = album.trackCount {
                Text("\(count) songs")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.top)
    }
    
    // MARK: - Play All Button
    
    /// Button to play the entire album starting from the first track.
    private func playAllButton(_ album: AlbumInfo) -> some View {
        Button {
            Task {
                await playAll(album)
            }
        } label: {
            HStack {
                Image(systemName: "play.fill")
                Text("Play All")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.purple)
            .foregroundColor(.white)
            .cornerRadius(10)
            .padding(.horizontal)
        }
        // `album.tracks` is `[SearchResult]?`, an optional array. `?.isEmpty`
        // asks "is it empty?" only if there IS an array; if `tracks` is nil,
        // the whole expression is nil too. `?? true` is the "nil-coalescing
        // operator": it supplies a fallback value (`true`, i.e. treat a
        // missing track list as "empty") whenever the left side is nil. Net
        // effect: disable the button unless there's a non-empty track list.
        .disabled(album.tracks?.isEmpty ?? true)
        .opacity(album.tracks?.isEmpty ?? true ? 0.5 : 1)
    }

    // MARK: - Track List

    /// Complete list of tracks in the album.
    private func trackList(_ album: AlbumInfo) -> some View {
        VStack(spacing: 0) {
            if let tracks = album.tracks {
                // `tracks.enumerated()` pairs each track with its index
                // (0, 1, 2, ...), producing a sequence of `(index, element)`
                // tuples. `Array(...)` turns that sequence into a concrete
                // array so `ForEach` can use it. `ForEach` is the SwiftUI
                // view that turns a collection into a repeated row of views
                //, one call to its closure per item. `id: \.element.id`
                // tells `ForEach` how to uniquely identify each row (using
                // the track's own `id` property) so SwiftUI can track which
                // row is which across UI updates, even if the list reorders.
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    trackRow(track, index: index, tracks: tracks)

                    Divider()
                        .padding(.leading, 80)
                }
            } else {
                // Empty state, shown when `album.tracks` is nil.
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No tracks available")
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 40)
            }
        }
    }

    /// A single tappable row in the track list: track number, thumbnail,
    /// title/artist, duration, and a play icon. Tapping it plays this track
    /// and queues the rest of the album after it.
    private func trackRow(_ track: SearchResult, index: Int, tracks: [SearchResult]) -> some View {
        Button {
            Task {
                await playTrack(track, tracks: tracks, startIndex: index)
            }
        } label: {
            HStack(spacing: 12) {
                // Track number (1-based for display, so we add 1 to the
                // 0-based `index`)
                Text("\(index + 1)")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .frame(width: 28)

                // Thumbnail.
                // This is the simpler `AsyncImage` form: `phase.image` is an
                // optional `Image?` that's non-nil only once loading has
                // succeeded, so `if let image = phase.image` covers both the
                // "still loading" and "failed" cases with one fallback view.
                AsyncImage(url: URL(string: track.thumbnailUrl)) { phase in
                    if let image = phase.image {
                        image.resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 40, height: 40)
                            .cornerRadius(4)
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.secondary.opacity(0.3))
                            .frame(width: 40, height: 40)
                    }
                }

                // Title and artist
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .foregroundColor(.primary)
                    Text(track.artist)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                // Duration (optional, not all tracks report one)
                if let duration = track.duration {
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
            .padding(.vertical, 6)
        }
    }
    
    // MARK: - Play Actions

    /// Play the entire album starting from the beginning.
    private func playAll(_ album: AlbumInfo) async {
        // `guard let ... else { return }` is Swift's "early exit" pattern:
        // it unwraps `album.tracks` into `tracks`, and if that fails (nil)
        // OR the array is empty, the `else` branch runs and we `return`
        // immediately, skipping the rest of the function. This avoids ever
        // indexing into an empty/missing array below.
        guard let tracks = album.tracks, !tracks.isEmpty else { return }
        await playTrack(tracks[0], tracks: tracks, startIndex: 0)
    }

    /// Play a specific track and queue the rest of the album after it.
    /// `track` is the one to start playing now; `tracks` is the full album
    /// list so we know what comes after it; `startIndex` is `track`'s
    /// position within `tracks`.
    private func playTrack(_ track: SearchResult, tracks: [SearchResult], startIndex: Int) async {
        do {
            // Ask the API for the actual streamable audio URL for this
            // video ID (the search/track result alone doesn't include one).
            let info = try await apiClient.getPlayerInfo(videoId: track.id)
            await audioPlayer.play(
                videoId: info.videoId,
                title: info.title,
                artist: info.artist,
                thumbnailUrl: info.thumbnailUrl,
                audioUrl: info.audioUrl,
                duration: info.duration
            )

            // Queue remaining tracks after the current one so playback
            // continues through the rest of the album automatically.
            // `(startIndex + 1)..<tracks.count` is a Range covering every
            // index AFTER the one we just started playing.
            for i in (startIndex + 1)..<tracks.count {
                let nextTrack = tracks[i]
                // `try?` converts a throwing call into an optional: if
                // `getPlayerInfo` succeeds we get `Optional(info)`, if it
                // throws we get `nil` instead of propagating the error. We
                // use that here so ONE track failing to resolve (e.g. a
                // removed video) doesn't abort queuing the rest of the
                // album, it just gets silently skipped.
                if let nextInfo = try? await apiClient.getPlayerInfo(videoId: nextTrack.id) {
                    // Convert PlayerInfo to NowPlaying for the queue.
                    // NowPlaying is the queue's data type.
                    audioPlayer.addToQueue(NowPlaying(
                        id: nextInfo.videoId,
                        title: nextInfo.title,
                        artist: nextInfo.artist,
                        thumbnailUrl: nextInfo.thumbnailUrl,
                        duration: nextInfo.duration,
                        audioUrl: nextInfo.audioUrl
                    ))
                }
            }
        } catch {
            // If fetching the FIRST track's player info fails, we land
            // here (the `try?` above only guards the queued-up tracks).
            // We just log it rather than showing an error UI, since the
            // user is mid-navigation and a console log is enough for now.
            print("Failed to play track: \(error)")
        }
    }
}
