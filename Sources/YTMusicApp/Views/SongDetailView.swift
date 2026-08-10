// Import Apple's SwiftUI framework, provides all the UI building blocks
// like View, Text, Image, Button, VStack, etc.
import SwiftUI

// MARK: - Song Detail View

/// A full-screen view showing detailed information about a song.
///
/// Shows play count, last played date, album art, duration, and
/// provides quick actions like share, add to playlist, and download.
/// Presented as a sheet when the user taps "Song Info" in a context menu.
///
/// NOTE ON STRUCTURE: SwiftUI views are "declarative", instead of writing
/// step-by-step instructions for how to draw the screen, you describe WHAT
/// the screen should look like for the current data, and SwiftUI figures out
/// how to draw (and redraw) it. A `View` in this codebase is usually a
/// `struct` (a lightweight value type) that conforms to the `View` protocol,
/// meaning it promises to provide a `body` computed property describing its
/// contents. To keep any single `body` from becoming a giant wall of code,
/// this file breaks the screen into several small computed properties (like
/// `albumArtSection`, `statsSection`, etc.) that each return "some View",
/// a piece of UI, which `body` then assembles like puzzle pieces.
struct SongDetailView: View {

    /// The YouTube video ID, a unique string that identifies this video on YouTube
    let videoId: String

    /// Song title, the name of the song as displayed to the user
    let title: String

    /// Artist name, the performer or band that created the song
    let artist: String

    /// URL to the album art thumbnail, a web address pointing to the cover image
    let thumbnailUrl: String

    /// Duration as a display string (e.g. "3:45"), how long the song is
    let duration: String

    /// The audio player, used to start playback from this view
    /// Injected via the SwiftUI environment so all views share one player
    @EnvironmentObject var audioPlayer: AudioPlayer

    /// The offline manager, used to download songs for offline playback
    /// Injected via the environment, handles download logic
    @EnvironmentObject var offlineManager: OfflineManager

    /// The playlist manager, used to add songs to user-created playlists
    /// Injected via the environment, manages the list of playlists
    @EnvironmentObject var playlistManager: PlaylistManager

    /// The play count manager, provides play count data for this song
    /// Tracks how many times a song has been played and when it was last played
    @EnvironmentObject var playCountManager: PlayCountManager

    /// The liked songs manager, tracks which songs the user has liked
    @EnvironmentObject var likedSongs: LikedSongsManager

    /// The API client, used to fetch a real streaming/download URL.
    /// The download button needs the stream URL from the player endpoint
    /// (search results only carry display info, not the audio URL).
    @EnvironmentObject var apiClient: APIClient

    /// `@Environment(\.dismiss)` gives us a function we can call to close
    /// this view when it's presented modally (as a sheet, in our case).
    /// This is the modern, SwiftUI-native way to dismiss a view from inside
    /// itself, you don't need the parent to pass a binding just for closing.
    /// We use it below in the "Done" toolbar button.
    @Environment(\.dismiss) private var dismiss

    /// Whether a download is currently in progress.
    /// When true, the download button shows a spinner and is disabled
    /// so the user can't start two downloads for the same song.
    /// `@State` marks this as UI state this view owns and manages itself,
    /// whenever it changes, SwiftUI automatically re-renders any part of the
    /// view that reads it, so the spinner appears/disappears live.
    @State private var isDownloading = false

    /// Whether the playlist picker sheet is showing
    /// When true, a sheet slides up showing the user's playlists to choose from
    @State private var showPlaylistPicker = false

    /// Whether the share sheet is showing
    /// When true, the iOS native share sheet appears so the user can share the song
    @State private var showShareSheet = false

    /// The body of the view, the visual content.
    /// This computed property (a property that runs code to produce its value,
    /// rather than just storing one) is required by the `View` protocol and is
    /// what SwiftUI calls whenever it needs to know what to draw.
    var body: some View {
        // Wraps everything in a NavigationView so we get a title bar and toolbar
        NavigationView {
            // Allows the content to scroll if it's taller than the screen
            ScrollView {
                // A vertical stack that spaces its children by 24 points each.
                // Each line below plugs in one of the small "section" computed
                // properties defined further down this file, this keeps the
                // body readable as a table of contents for the screen instead
                // of one long nested tree of views.
                VStack(spacing: 24) {
                    albumArtSection
                    titleArtistSection
                    durationSection
                    statsSection
                    actionsSection
                    videoIdSection
                }
                // Adds padding to the bottom of the entire VStack for scroll margin
                .padding(.bottom)
            }
            // Sets the title in the navigation bar to "Song Info"
            .navigationTitle("Song Info")
            // Makes the title display in a smaller inline style (not large title)
            .navigationBarTitleDisplayMode(.inline)
            // Adds items to the navigation bar (top area)
            .toolbar {
                // Close button to dismiss the sheet
                // Places a "Done" button on the right side of the navigation bar
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        // Calls the dismiss action from the environment, which
                        // tells SwiftUI to close this sheet. (Previously this
                        // button's action was empty, which meant tapping "Done"
                        // did nothing at all, a real bug, since the comment
                        // claimed dismissal was "handled automatically", but
                        // nothing in this view or its presenter actually did
                        // that. `@Environment(\.dismiss)` above fixes it.)
                        dismiss()
                    }
                }
            }
        }
        // Playlist picker sheet, a modal that slides up from the bottom.
        // `.sheet(isPresented:)` is a view modifier (a function that returns a
        // modified copy of a view) that watches a Bool `@State`/`@Binding`
        // value; when it flips to true, SwiftUI presents the given content as
        // a modal sheet, and flips it back to false automatically when the
        // user dismisses it.
        .sheet(isPresented: $showPlaylistPicker) {
            // Shows the PlaylistPickerSheet with the current song's info
            PlaylistPickerSheet(
                // Wraps the song data into a SearchResult object for the picker
                result: SearchResult(
                    id: videoId,
                    title: title,
                    artist: artist,
                    thumbnailUrl: thumbnailUrl,
                    duration: duration
                ),
                // Passes the binding so the picker can dismiss itself when done.
                // `$showPlaylistPicker` is a "binding", a two-way reference to
                // this view's @State value. The child view can both read it and
                // write to it, and because it's the *same* underlying storage
                // (not a copy), setting it to false there closes the sheet here too.
                isPresented: $showPlaylistPicker
            )
        }
        // Share sheet, uses the iOS native share sheet (UIActivityViewController)
        .sheet(isPresented: $showShareSheet) {
            // Builds a shareable text string with the song title, artist, and YouTube link.
            // String interpolation (`\(...)`) inserts each value directly into the string.
            let shareText = "Check out \(title) by \(artist) on YouTube Music!\nhttps://music.youtube.com/watch?v=\(videoId)"
            // Passes the text to the UIKit share sheet wrapper
            ShareSheet(items: [shareText])
        }
    }

    // MARK: - Sections
    // Each computed property below is a small, single-purpose piece of the
    // screen. Breaking the body up like this makes each piece easy to read
    // in isolation and easy to reuse or reorder later.

    /// Large album art displayed prominently at the top of the screen.
    /// Loads the image from the URL asynchronously (doesn't block the UI
    /// while the network request for the image is in flight).
    private var albumArtSection: some View {
        // `AsyncImage` is a SwiftUI view built for loading images from a URL.
        // It takes two closures: one that runs once the image has loaded
        // (`image in ...`), and a `placeholder` closure that runs while
        // loading (or if the URL is invalid/nil).
        AsyncImage(url: URL(string: thumbnailUrl)) { image in
            image
                // Makes the image resizable so it can fill the frame
                .resizable()
                // Maintains the image's original aspect ratio (not stretched)
                .aspectRatio(contentMode: .fit)
                // Rounds the corners by 12 points for a polished look
                .cornerRadius(12)
                // Adds a soft shadow underneath the image
                .shadow(radius: 8)
        } placeholder: {
            // Placeholder while the image loads
            // Shows a gray rounded rectangle with a music note icon
            RoundedRectangle(cornerRadius: 12)
                // Fills the rectangle with a light gray color at 30% opacity
                .fill(Color.gray.opacity(0.3))
                // Places the music note icon on top of the rectangle
                .overlay(
                    // Uses the SF Symbol "music.note" as a temporary icon
                    Image(systemName: "music.note")
                        // Makes the icon large so it fills the space well
                        .font(.largeTitle)
                        // Colors it with the system's secondary color (gray-ish)
                        .foregroundColor(.secondary)
                )
        }
        // Limits the image to a maximum of 280x280 points on screen
        .frame(maxWidth: 280, maxHeight: 280)
        // Adds padding to the top so it doesn't touch the navigation bar
        .padding(.top)
    }

    /// Title and artist name, centered below the album art.
    private var titleArtistSection: some View {
        // A vertical stack with 8 points of spacing between elements
        VStack(spacing: 8) {
            // Shows the song title in a large bold text
            Text(title)
                // Sets the font to title2, a medium-large system font
                .font(.title2)
                // Makes the text bold so it stands out
                .fontWeight(.bold)
                // Centers the text if it's longer than one line
                .multilineTextAlignment(.center)

            // Shows the artist name below the title
            Text(artist)
                // Uses the body font, the standard system font size
                .font(.body)
                // Uses the secondary color (light gray) to de-emphasize it
                .foregroundColor(.secondary)
                // Centers the text like the title above it
                .multilineTextAlignment(.center)
        }
        // Adds horizontal padding so text doesn't touch screen edges
        .padding(.horizontal)
    }

    /// A row showing the song's duration next to a clock icon.
    private var durationSection: some View {
        // A horizontal row with the clock icon and the duration text
        HStack {
            // A small clock icon from Apple's SF Symbols library
            Image(systemName: "clock")
                // Colors the clock icon in the secondary (gray) color
                .foregroundColor(.secondary)
            // The label "Duration:" followed by the actual duration value
            Text("Duration: \(duration)")
                // Uses a subheadline font, slightly smaller than body text
                .font(.subheadline)
                // Colors the text in the secondary (gray) color
                .foregroundColor(.secondary)
        }
    }

    /// Card showing play count and last played date.
    private var statsSection: some View {
        // A vertical stack with 12 points between the two stat rows
        VStack(spacing: 12) {
            // Play count stat
            // A reusable StatRow showing how many times the song was played
            StatRow(
                // Uses the play circle icon (blue) for the "play count" stat
                icon: "play.circle.fill",
                iconColor: .blue,
                label: "Times Played",
                // Gets the play count from the manager, converts Int to String
                value: "\(playCountManager.getPlayCount(videoId: videoId))"
            )

            // Last played stat
            // A reusable StatRow showing when the song was last played
            StatRow(
                // Uses a clock icon (green) for the "last played" stat
                icon: "clock.fill",
                iconColor: .green,
                label: "Last Played",
                // Formats the optional Date into a human-readable string
                value: formatDate(playCountManager.getLastPlayedDate(videoId: videoId))
            )
        }
        // Adds padding around the entire stats card
        .padding()
        // Sets the background to match the system background color
        .background(Color(.systemBackground))
        // Rounds the corners of the stats card
        .cornerRadius(12)
        // Adds a subtle shadow below the card for depth
        .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
        // Adds horizontal padding so it doesn't touch screen edges
        .padding(.horizontal)
    }

    /// The quick-action buttons: the big "Play Now" button plus the row of
    /// four secondary buttons (share, download, playlist, like).
    private var actionsSection: some View {
        // A vertical stack with 12 points between rows of buttons
        VStack(spacing: 12) {
            playButton
            secondaryActionsRow
        }
        // Adds horizontal padding so the buttons don't touch screen edges
        .padding(.horizontal)
    }

    /// Full-width blue button that adds the song to the queue and plays it.
    private var playButton: some View {
        Button(action: {
            // Creates a NowPlaying object with the song's basic info
            let song = NowPlaying(
                // The unique YouTube video ID
                id: videoId,
                // The song's title
                title: title,
                // The artist who performed the song
                artist: artist,
                // The URL string for the album art image
                thumbnailUrl: thumbnailUrl,
                // Duration set to 0 here, will be populated by the player
                duration: 0,
                // Audio URL is empty here, the player fetches the stream URL
                audioUrl: ""
            )
            // Tells the audio player to add this song to the queue and start playing
            audioPlayer.addToQueueAndPlay(song)
        }) {
            // The visual content of the button
            HStack {
                // A play icon from SF Symbols
                Image(systemName: "play.fill")
                // The label text for the button
                Text("Play Now")
            }
            // Makes the button stretch to fill the available width
            .frame(maxWidth: .infinity)
            // Adds padding inside the button for comfortable touch area
            .padding()
            // Sets the button background to blue so it looks like a primary action
            .background(Color.blue)
            // Sets the text and icon color to white for contrast on blue
            .foregroundColor(.white)
            // Rounds the button corners for a modern iOS look
            .cornerRadius(12)
        }
    }

    /// Bottom row, share, download, playlist, and like side by side.
    private var secondaryActionsRow: some View {
        // A horizontal stack containing four secondary buttons
        HStack(spacing: 12) {
            shareButton
            downloadButton
            playlistButton
            likeButton
        }
    }

    /// Share button, opens the iOS share sheet via `showShareSheet`.
    private var shareButton: some View {
        Button(action: {
            // Sets the state to true, which triggers the .sheet modifier
            showShareSheet = true
        }) {
            // The visual content of the share button
            HStack {
                // The standard iOS share icon (box with up arrow)
                Image(systemName: "square.and.arrow.up")
                // The label text
                Text("Share")
            }
            // Makes the button stretch to fill its share of the row
            .frame(maxWidth: .infinity)
            // Adds padding inside for a comfortable touch area
            .padding()
            // Uses a light gray background, secondary button style
            .background(Color(.systemGray5))
            // Uses the primary text color (black in light mode, white in dark)
            .foregroundColor(.primary)
            // Rounds the corners to match the play button style
            .cornerRadius(12)
        }
    }

    /// Download button, saves the song for offline playback.
    private var downloadButton: some View {
        Button(action: {
            // Only download if the song isn't already downloaded
            // or currently being downloaded.
            // `guard` checks a condition up front and exits early (via `return`)
            // if it's not met, it reads like "make sure all of this is true,
            // otherwise bail out", which keeps the "happy path" code below
            // free of nested `if` statements.
            guard !offlineManager.isDownloaded(videoId),
                  !offlineManager.isDownloading(videoId),
                  !isDownloading else { return }

            // Mark this song as downloading so the UI shows a spinner
            isDownloading = true

            // The download flow has three steps:
            // 1. Ask YouTube for a fresh stream URL (the player
            //    endpoint returns a temporary streaming URL,
            //    search results don't include one).
            // 2. Hand that URL to OfflineManager, which downloads
            //    the audio in the background and stores it on disk.
            // 3. Clear the downloading flag when done.
            //
            // `Task { ... }` starts an asynchronous unit of work. "Async" code
            // can pause at `await` points (like waiting on a network call)
            // without blocking the rest of the app, the UI stays responsive
            // while this runs in the background.
            Task {
                do {
                    // Get the real audio stream URL for this song.
                    // getPlayerInfoForDownload uses the user's
                    // "download quality" setting from Settings.
                    // `await` pauses this Task (not the whole app) until the
                    // network call finishes.
                    let info = try await apiClient.getPlayerInfoForDownload(videoId: videoId)

                    // Start the actual download with the real URL
                    await offlineManager.download(
                        videoId: videoId,
                        title: title,
                        artist: artist,
                        audioUrl: info.audioUrl,
                        thumbnailUrl: thumbnailUrl
                    )
                } catch {
                    // `do`/`catch` is Swift's error-handling pattern: code
                    // marked `try` inside `do` can throw an error, and if it
                    // does, execution jumps to the matching `catch` block
                    // instead of crashing. Here we just log the failure so
                    // it's debuggable in the console.
                    print("Download failed for \(title): \(error)")
                }

                // Turn off the spinner (success or failure)
                isDownloading = false
            }
        }) {
            // The visual content of the download button
            HStack {
                // If a download is in progress, show a small spinner
                if isDownloading {
                    ProgressView()
                        // Keeps the spinner small so it doesn't grow the button
                        .scaleEffect(0.8)
                } else {
                    // Shows a checkmark if already downloaded, or a down arrow if not.
                    // This is Swift's ternary conditional operator:
                    // `condition ? valueIfTrue : valueIfFalse`.
                    Image(systemName: offlineManager.isDownloaded(videoId) ? "checkmark.circle.fill" : "arrow.down.circle")
                }
                // Shows "Downloaded" if already saved, "Downloading..." if in progress, or "Download"
                Text(offlineManager.isDownloaded(videoId) ? "Downloaded" : (isDownloading ? "Downloading..." : "Download"))
            }
            // Makes the button stretch to fill its share of the row
            .frame(maxWidth: .infinity)
            // Adds padding inside for a comfortable touch area
            .padding()
            // Uses a light gray background, secondary button style
            .background(Color(.systemGray5))
            // Uses the primary text color
            .foregroundColor(.primary)
            // Rounds the corners to match the other buttons
            .cornerRadius(12)
        }
    }

    /// Add-to-playlist button, shows the playlist picker sheet.
    private var playlistButton: some View {
        Button(action: {
            // Sets the state to true, which triggers the .sheet modifier
            showPlaylistPicker = true
        }) {
            // The visual content of the playlist button
            HStack {
                // An icon showing a plus sign on a text badge
                Image(systemName: "text.badge.plus")
                // The label text
                Text("Playlist")
            }
            // Makes the button stretch to fill its share of the row
            .frame(maxWidth: .infinity)
            // Adds padding inside for a comfortable touch area
            .padding()
            // Uses a light gray background, secondary button style
            .background(Color(.systemGray5))
            // Uses the primary text color
            .foregroundColor(.primary)
            // Rounds the corners to match the other buttons
            .cornerRadius(12)
        }
    }

    /// Like button, toggles like status for this song.
    private var likeButton: some View {
        Button(action: {
            // Toggles the like status (add/remove from liked songs)
            likedSongs.toggle(videoId)
        }) {
            // The visual content of the like button
            HStack {
                // Filled heart if liked, outline heart if not
                Image(systemName: likedSongs.isLiked(videoId) ? "heart.fill" : "heart")
                // Shows "Liked" or "Like" depending on status
                Text(likedSongs.isLiked(videoId) ? "Liked" : "Like")
            }
            // Makes the button stretch to fill its share of the row
            .frame(maxWidth: .infinity)
            // Adds padding inside for a comfortable touch area
            .padding()
            // Uses pink when liked, gray when not
            .background(likedSongs.isLiked(videoId) ? Color.pink.opacity(0.2) : Color(.systemGray5))
            // Uses pink text when liked, primary when not
            .foregroundColor(likedSongs.isLiked(videoId) ? .pink : .primary)
            // Rounds the corners to match the other buttons
            .cornerRadius(12)
        }
    }

    /// Small info box at the bottom showing the raw YouTube video ID for reference.
    private var videoIdSection: some View {
        // A small info box at the bottom with the YouTube video identifier
        VStack(alignment: .leading, spacing: 8) {
            // The label "Video ID" in small caption text
            Text("Video ID")
                // Uses the smallest system font size (caption)
                .font(.caption)
                // Uses the secondary color to de-emphasize this section
                .foregroundColor(.secondary)
            // The actual video ID text shown in a monospaced font
            Text(videoId)
                // Uses the same small caption font size
                .font(.caption)
                // Uses a monospaced font so each character has equal width
                .monospaced()
                // Uses the secondary color to keep it subtle
                .foregroundColor(.secondary)
        }
        // Makes the container stretch full width with text aligned to the left
        .frame(maxWidth: .infinity, alignment: .leading)
        // Adds padding inside the container for spacing
        .padding()
        // Uses a slightly different gray background to distinguish this section
        .background(Color(.systemGray6))
        // Rounds the corners for a consistent card-like appearance
        .cornerRadius(8)
        // Adds horizontal padding so it doesn't touch screen edges
        .padding(.horizontal)
    }

    /// Format a Date into a human-readable string.
    ///
    /// Shows "Never" if no date is provided, or a relative time like
    /// "2 hours ago", "Yesterday", etc.
    /// - Parameter date: An optional Date to format
    /// - Returns: A human-readable string describing when the date was
    private func formatDate(_ date: Date?) -> String {
        // `Date?` is an "optional" Date, it can either hold a real Date value
        // or hold nothing at all (`nil`). Swift forces us to explicitly deal
        // with the "nothing" case before we can use the value, which prevents
        // a whole category of crashes common in other languages. `guard let`
        // unwraps the optional: if `date` has a value, it's bound to a new
        // non-optional `date` constant for the rest of the function; if it's
        // nil, we return early.
        guard let date = date else {
            return "Never"
        }

        // Gets the current date and time for comparison
        let now = Date()
        // Calculates how many seconds have passed since the given date
        let timeInterval = now.timeIntervalSince(date)

        // Less than 1 minute ago
        if timeInterval < 60 {
            return "Just now"
        }
        // Less than 1 hour ago (3600 seconds)
        else if timeInterval < 3600 {
            // Converts seconds to whole minutes
            let minutes = Int(timeInterval / 60)
            // Uses plural "minutes" for anything other than 1, singular "minute" for exactly 1
            return "\(minutes) minute\(minutes == 1 ? "" : "s") ago"
        }
        // Less than 24 hours ago (86400 seconds)
        else if timeInterval < 86400 {
            // Converts seconds to whole hours
            let hours = Int(timeInterval / 3600)
            // Uses plural "hours" for anything other than 1
            return "\(hours) hour\(hours == 1 ? "" : "s") ago"
        }
        // Less than 7 days ago (604800 seconds = 7 * 86400)
        else if timeInterval < 604800 {
            // Converts seconds to whole days
            let days = Int(timeInterval / 86400)
            // Uses plural "days" for anything other than 1
            return "\(days) day\(days == 1 ? "" : "s") ago"
        }
        // More than 7 days, show actual date instead of relative time
        else {
            // Creates a DateFormatter to convert the Date into a readable string
            let formatter = DateFormatter()
            // Uses medium style: e.g. "Jan 1, 2023" (adapts to user's locale)
            formatter.dateStyle = .medium
            // Converts the Date to a formatted string using the formatter
            return formatter.string(from: date)
        }
    }
}

// MARK: - Stat Row

/// A single statistics row showing an icon, label, and value.
///
/// Used in the SongDetailView to display play count and last played info.
/// Lays out content horizontally: icon on the left, label in the middle, value on the right.
struct StatRow: View {

    /// The SF Symbol icon name, a string like "play.circle.fill" or "clock.fill"
    let icon: String

    /// The tint color for the icon, e.g. .blue for play count, .green for last played
    let iconColor: Color

    /// The label text (e.g. "Times Played"), describes what the stat represents
    let label: String

    /// The value text (e.g. "42"), the actual statistic to display
    let value: String

    /// The body of the StatRow, a horizontal row with icon, label, and value
    var body: some View {
        // Arranges content horizontally: icon, label, spacer, value
        HStack {
            // Icon with a tinted background, makes the stat visually distinct
            Image(systemName: icon)
                // Applies the tint color (blue, green, etc.) to the icon
                .foregroundColor(iconColor)
                // Sets a fixed 32x32 point frame for consistent sizing
                .frame(width: 32, height: 32)
                // Adds a semi-transparent background using the same color as the icon
                .background(iconColor.opacity(0.15))
                // Rounds the background's corners by 8 points
                .cornerRadius(8)

            // Label on the left, describes what this stat is
            Text(label)
                // Uses a subheadline font, slightly smaller than standard body text
                .font(.subheadline)
                // Uses the secondary color to de-emphasize the label
                .foregroundColor(.secondary)

            // Pushes everything apart, places the label on the left and value on the right.
            // `Spacer()` is an invisible view that expands to fill any remaining
            // space in its stack, shoving its neighbors apart.
            Spacer()

            // Value on the right, the actual number or date text
            Text(value)
                // Uses the same subheadline font size as the label
                .font(.subheadline)
                // Makes the value slightly bold so it stands out from the label
                .fontWeight(.semibold)
        }
    }
}

// MARK: - Share Sheet (UIKit Wrapper)

/// Wraps UIActivityViewController (iOS native share sheet) for SwiftUI.
///
/// SwiftUI doesn't have a built-in share sheet, so we wrap the UIKit one.
/// This lets us share text, URLs, or other content via the standard iOS share menu.
/// Conforms to UIViewControllerRepresentable to bridge UIKit view controllers into SwiftUI.
/// ("Conforms to a protocol" means this type promises to implement a specific
/// set of required properties/methods, here, `makeUIViewController` and
/// `updateUIViewController`, so SwiftUI knows how to host it.)
struct ShareSheet: UIViewControllerRepresentable {

    /// The items to share (text, URLs, images, etc.)
    /// Passed directly to UIActivityViewController's activityItems parameter
    let items: [Any]

    /// Create the UIActivityViewController, called once when the view is first created
    /// - Parameter context: The SwiftUI context (provides environment info)
    /// - Returns: A configured UIActivityViewController instance
    func makeUIViewController(context: Context) -> UIActivityViewController {
        // Creates the standard iOS share sheet with the provided items
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        // Returns the configured controller to display
        return controller
    }

    /// Update the view controller (not needed for share sheet)
    /// Required by UIViewControllerRepresentable but no updates are needed here
    /// - Parameters:
    ///   - uiViewController: The existing UIActivityViewController instance
    ///   - context: The SwiftUI context
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // No updates needed, the share sheet is configured once and dismissed by the system
    }
}

// MARK: - Preview

/// A preview provider for Xcode's Canvas, shows what the view looks like at design time
#Preview {
    // Creates a SongDetailView with sample data for previewing in Xcode
    SongDetailView(
        // Rick Astley's famous music video ID, a recognizable test value
        videoId: "dQw4w9WgXcQ",
        // A well-known song title for the preview
        title: "Never Gonna Give You Up",
        // The artist name for the preview
        artist: "Rick Astley",
        // Empty thumbnail URL, will show the placeholder in previews
        thumbnailUrl: "",
        // A sample duration string for display
        duration: "3:33"
    )
    // Injects a mock AudioPlayer into the environment for previewing
    .environmentObject(AudioPlayer())
    // Injects a mock OfflineManager into the environment for previewing
    .environmentObject(OfflineManager())
    // Injects a mock PlaylistManager into the environment for previewing
    .environmentObject(PlaylistManager())
    // Injects a mock PlayCountManager into the environment for previewing
    .environmentObject(PlayCountManager())
    // Injects a mock LikedSongsManager into the environment for previewing.
    // (Previously missing, the view reads `likedSongs` in its like button,
    // so without this the Xcode preview would crash when opened.)
    .environmentObject(LikedSongsManager())
    // Injects a mock APIClient into the environment for previewing.
    // (Also previously missing, needed by the download button's action.)
    .environmentObject(APIClient())
}
