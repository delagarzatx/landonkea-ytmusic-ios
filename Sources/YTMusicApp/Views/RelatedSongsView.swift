import SwiftUI // Imports the SwiftUI framework, which provides all the UI components (views, modifiers, etc.) used throughout this file

// MARK: - Related Songs View

/// A horizontal carousel that displays songs related to the currently playing track.
///
/// This view fetches recommendations from YouTube Music's "Related" section using
/// the InnerTube `next` endpoint. It presents similar songs the user might enjoy
/// in a horizontally scrollable row, each showing a thumbnail, title, and artist name.
///
/// NOTE ON STYLE: `body` is kept short by delegating each visual chunk (header, loading
/// spinner, scroll row, individual song card) to its own small computed property or
/// helper view. This is the same idea as breaking a long function into smaller, clearly
/// named helper functions, it makes each piece easy to read and test in isolation.
struct RelatedSongsView: View { // Declares a SwiftUI View struct; View is the protocol all UI components conform to

    /// The YouTube video ID used to fetch related song recommendations.
    /// This is a `let` (constant) property, it's set once when the view is created.
    /// SwiftUI still notices when a *new* `RelatedSongsView` is created with a different
    /// `videoId` (e.g. because the parent view re-renders with a new song), which is
    /// what triggers the `.onChange(of:)` modifier further down.
    let videoId: String

    /// The API client injected from the environment for making YouTube Music network requests.
    /// `@EnvironmentObject` means "don't construct this here, read it from the shared
    /// environment that a parent view supplied via `.environmentObject(...)`." It's a way
    /// to share one instance of a class across many views without manually passing it down
    /// through every initializer.
    @EnvironmentObject var apiClient: APIClient

    /// The audio player injected from the environment for controlling music playback.
    @EnvironmentObject var audioPlayer: AudioPlayer

    /// The list of related songs fetched from the API, stored as a state property so the UI
    /// updates when it changes.
    /// `@State` is a property wrapper for small pieces of data that a view *owns* and
    /// mutates itself (as opposed to data owned by an external object, like the
    /// `@EnvironmentObject`s above). Whenever a `@State` value changes, SwiftUI re-runs
    /// `body` to reflect the new value on screen.
    @State private var relatedSongs: [SearchResult] = []

    /// A flag that tracks whether the network request for related songs is currently in
    /// progress. `@State` again, toggling this shows/hides the `ProgressView` spinner.
    @State private var isLoading = false

    /// The required computed property that defines the view's layout and content.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { // A vertical stack; children align left with 12 points of spacing between them
            headerView // "Related" section title with icon
            loadingIndicator // Spinner shown only while the network request is in flight
            relatedSongsRow // The horizontally scrolling carousel of song cards
        }
        .task { // SwiftUI modifier that runs an asynchronous operation when the view first appears (and automatically cancels it if the view disappears before it finishes)
            // Load related songs as soon as the view appears on screen
            await loadRelatedSongs() // Calls the private async method and suspends until the network request completes
        }
        .onChange(of: videoId) { _ in // Triggers whenever the videoId property changes (e.g., when the user plays a different song)
            // Reload the related songs list to match the new video.
            // `Task { ... }` starts a new unit of asynchronous work. It's needed here
            // because `.onChange`'s closure is not itself `async`, but `loadRelatedSongs()`
            // is, so we need an async context to `await` it from.
            Task {
                await loadRelatedSongs() // Re-fetches related songs for the updated video ID
            }
        }
    }

    // MARK: - Subviews
    // "MARK:" comments are just bookmarks for Xcode's navigator/minimap; they don't affect behavior.

    /// Section header, a row containing an icon and the word "Related".
    private var headerView: some View {
        HStack { // A horizontal stack that places the icon and text side-by-side
            Image(systemName: "arrow.triangle.2.circlepath") // SF Symbol for a circular-arrow icon, suggesting "related" or "refresh"
                .foregroundColor(.purple) // Applies the app's accent purple color to the icon
            Text("Related") // The section's heading label
                .font(.title3) // Uses the system's title-3 font size (smaller than title but still prominent)
                .fontWeight(.bold) // Makes the heading text bold for emphasis
        }
    }

    /// Loading indicator, shown while the API call is in flight.
    /// Marked `@ViewBuilder` so we can conditionally return either the spinner or nothing
    /// at all, without needing to wrap everything in an `if`/`else` that produces two
    /// different concrete view types.
    @ViewBuilder
    private var loadingIndicator: some View {
        if isLoading { // Conditional block: only renders its children when isLoading is true
            ProgressView() // A native iOS spinner that indicates activity
                .frame(maxWidth: .infinity) // Expands the spinner's frame to fill the full available width
                .padding() // Adds the system default padding around the spinner
        }
    }

    /// Horizontal scroll of related songs, rendered only after songs have been loaded.
    @ViewBuilder
    private var relatedSongsRow: some View {
        if !relatedSongs.isEmpty { // Only displays the scroll view when the array contains at least one song
            ScrollView(.horizontal, showsIndicators: false) { // Creates a horizontally scrolling container; hides the scroll bar for a cleaner look
                HStack(spacing: 12) { // Arranges the song cards in a horizontal row with 12 points of spacing between them
                    // `ForEach` turns each element of `relatedSongs` into a view. Each
                    // element must conform to `Identifiable` (have a stable, unique `id`)
                    // so SwiftUI can track which on-screen row corresponds to which piece
                    // of data as the array changes.
                    ForEach(relatedSongs) { song in
                        songCard(for: song)
                    }
                }
            }
        }
    }

    /// A single song card in the carousel: thumbnail, title, and artist, wrapped in a
    /// tappable button that starts playback.
    /// - Parameter song: The related song this card represents.
    private func songCard(for song: SearchResult) -> some View {
        Button(action: { // Wraps the song card in a Button so tapping it triggers playback
            playRelatedSong(song) // Calls the private method that fetches streaming info and starts playback
        }) {
            VStack(alignment: .leading, spacing: 6) { // Stacks the thumbnail, title, and artist vertically
                songThumbnail(url: song.thumbnailUrl)

                // Song title, displays below the thumbnail
                Text(song.title) // The song's title text, taken from the SearchResult model
                    .font(.caption) // Uses the system caption font (small, intended for supplementary text)
                    .fontWeight(.medium) // Medium font weight for better readability at small sizes
                    .lineLimit(2) // Limits the title to at most 2 lines, adding an ellipsis if truncated
                    .frame(width: 120, alignment: .leading) // Matches the thumbnail width, left-aligns the text

                // Artist name, displayed below the title
                Text(song.artist) // The artist name text from the SearchResult model
                    .font(.caption2) // Uses an even smaller font size than caption for secondary info
                    .foregroundColor(.secondary) // Muted gray color to visually de-emphasize compared to the title
                    .lineLimit(1) // Single line only; truncates with an ellipsis if the name is too long
                    .frame(width: 120, alignment: .leading) // Matches thumbnail width, left-aligns the text
            }
        }
    }

    /// Album art thumbnail, loads the image from the URL asynchronously, showing a
    /// placeholder while it downloads or if it fails to load.
    /// - Parameter url: The thumbnail image URL string, as returned by the API.
    private func songThumbnail(url: String) -> some View {
        // `AsyncImage` downloads and displays a remote image. `URL(string:)` returns an
        // Optional<URL> because the string might not be a valid URL; AsyncImage handles a
        // `nil` URL gracefully by simply showing the placeholder, so no crash risk here.
        AsyncImage(url: URL(string: url)) { image in // The closure runs once the image successfully loads, receiving the loaded `Image`
            image // Refers to the successfully loaded Image instance
                .resizable() // Allows the image to be resized to fit the frame
                .aspectRatio(contentMode: .fill) // Scales the image to fill the frame, cropping if necessary to maintain aspect ratio
        } placeholder: { // A closure that provides placeholder content while the image loads
            Rectangle() // A simple rectangle shape as a placeholder
                .fill(Color.gray.opacity(0.3)) // Fills the rectangle with a light gray, partially transparent
                .overlay( // Layers additional content on top of the rectangle
                    Image(systemName: "music.note") // SF Symbol for a music note as a fallback icon
                        .foregroundColor(.secondary) // Uses the system's secondary text color for subtle appearance
                )
        }
        .frame(width: 120, height: 120) // Constrains the thumbnail (and placeholder) to a fixed 120x120 point square
        .cornerRadius(8) // Rounds the corners of the thumbnail image by 8 points
    }

    // MARK: - Networking

    /// Fetches the list of related songs from the YouTube Music API and updates the UI state.
    ///
    /// This method sets `isLoading` to `true` before the request and `false` after it completes,
    /// so the SwiftUI view shows a spinner during loading. If the request fails, the error is
    /// logged to the console and `relatedSongs` remains unchanged.
    private func loadRelatedSongs() async { // Declares a private asynchronous method; private restricts access to this struct
        isLoading = true // Sets the loading flag to true, which triggers the ProgressView to appear in the UI
        do { // Opens a do/catch block to handle any errors thrown by the network call
            let songs = try await apiClient.getRelated(videoId: videoId) // Calls the API client's getRelated method; suspends execution until the response arrives
            relatedSongs = songs // Assigns the fetched array to the @State property, causing SwiftUI to re-render the view
        } catch { // Catches any error thrown inside the do block (network failure, decoding error, etc.)
            print("Failed to load related songs: \(error)") // Prints an error message to the Xcode debug console for debugging purposes
        }
        isLoading = false // Resets the loading flag to false regardless of whether the request succeeded or failed
    }

    /// Fetches streaming information for the given song and starts playback.
    ///
    /// - Parameter result: A `SearchResult` object representing the song the user tapped.
    ///   The method extracts the video ID, calls the player API, constructs a `NowPlaying`
    ///   object, and passes it to the audio player's queue-and-play method.
    private func playRelatedSong(_ result: SearchResult) { // Takes a SearchResult and initiates playback
        Task { // Wraps the async call in a Task because this method is not itself async (it's called from a Button action)
            do { // Opens a do/catch block for error handling
                let playerInfo = try await apiClient.getPlayerInfo(videoId: result.id) // Fetches detailed streaming info (URL, metadata) for this video ID
                let song = NowPlaying( // Creates a NowPlaying value object from the API response
                    id: playerInfo.videoId, // The unique video identifier, used for tracking and queue management
                    title: playerInfo.title, // The display title of the song
                    artist: playerInfo.artist, // The artist or channel name
                    thumbnailUrl: playerInfo.thumbnailUrl, // The URL string for the album art image
                    duration: playerInfo.duration, // The total duration of the track in seconds
                    audioUrl: playerInfo.audioUrl // The streaming audio URL that the player will use
                )
                audioPlayer.addToQueueAndPlay(song) // Adds the song to the playback queue and immediately starts playing it
            } catch { // Catches any error from the network request
                print("Failed to play related song: \(error)") // Logs the failure message to the debug console
            }
        }
    }
}

// MARK: - Preview

#Preview { // SwiftUI macro that generates a live preview in Xcode's canvas or Swift Previews
    RelatedSongsView(videoId: "dQw4w9WgXcQ") // Creates an instance with a sample video ID (Rick Astley, "Never Gonna Give You Up")
        .environmentObject(APIClient()) // Injects a fresh APIClient into the environment for the preview to use
        .environmentObject(AudioPlayer()) // Injects a fresh AudioPlayer into the environment for the preview to use
}
