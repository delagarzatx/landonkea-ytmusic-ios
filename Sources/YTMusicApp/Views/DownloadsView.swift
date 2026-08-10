import SwiftUI
// ^ Import Apple's SwiftUI framework for building user interfaces

/// Shows all downloaded songs available for offline playback.
///
/// Displayed in the Library tab. Users can:
/// - Tap a song to play it from cache (no internet needed)
/// - Swipe to delete individual songs
/// - Clear all downloads (with confirmation)
/// - See storage usage and download count
///
/// GLOSSARY (terms explained here the first time they appear in this file):
/// - **@EnvironmentObject**: reads a shared object that some ancestor view
///   injected into the app's "environment" (via `.environmentObject(...)`),
///   instead of it being passed down explicitly through initializers. The
///   view automatically re-renders whenever that object's data changes.
/// - **@State**: a property wrapper for small pieces of view-local, in-memory
///   state. When a `@State` value changes, SwiftUI re-runs `body` to update
///   the screen. It resets whenever the view itself is thrown away and recreated.
/// - **optional**: a Swift type that can either hold a value or hold nothing
///   (`nil`). Written as `Type?`, e.g. `URL?`. Optionals force you to handle
///   the "there might be nothing here" case explicitly, which is why you'll
///   see `guard let` and `if let` throughout this codebase.
/// - **guard**: an early-exit check. `guard condition else { return }` reads
///   as "make sure this is true, otherwise stop right here." It's preferred
///   over deeply nested `if` blocks because the "happy path" code that
///   follows doesn't need to be indented inside an `if`.
struct DownloadsView: View {
    // ^ A full-screen view that lists every song saved for offline listening

    // MARK: - Injected Dependencies

    /// The offline manager handles downloads and cache
    @EnvironmentObject var offlineManager: OfflineManager
    // ^ Read from the environment: gives us access to the list of downloads + delete methods

    /// The audio player for playing cached songs
    @EnvironmentObject var audioPlayer: AudioPlayer
    // ^ Read from the environment: lets us play a song directly from local storage

    // MARK: - Local State

    /// Whether to show the "Clear All" confirmation alert
    @State private var showClearAllAlert = false
    // ^ Tracks whether the destructive confirmation dialog is visible

    // MARK: - UI Body

    // `body` is kept intentionally tiny: it just picks between the empty
    // state and the real list, then attaches the navigation title, toolbar,
    // and alert. Each of those pieces is defined as its own computed
    // property below so this top-level view stays easy to scan.
    var body: some View {
        // ^ The main view content, SwiftUI renders this on screen
        NavigationView {
            // ^ Wraps everything in a navigation controller (top bar + titles)
            Group {
                // ^ A container that applies the same modifiers to its children
                if offlineManager.downloads.isEmpty {
                    emptyState
                } else {
                    downloadsList
                }
            }
            .navigationTitle("Downloads")
            // ^ Set the title shown in the navigation bar at the top
            .toolbar { toolbarContent }
            // Confirmation alert before deleting all downloads
            .alert("Clear All Downloads?", isPresented: $showClearAllAlert) {
                // ^ A modal dialog; appears when showClearAllAlert becomes true
                Button("Cancel", role: .cancel) { }
                // ^ Dismisses the alert, role: .cancel means it's the safe default
                Button("Clear All", role: .destructive) {
                    // ^ Red-styled destructive button
                    offlineManager.deleteAll()
                    // ^ Delete every downloaded file and metadata entry
                }
            } message: {
                // ^ The body text below the alert title
                Text("This will remove all \(offlineManager.downloads.count) downloaded songs. This cannot be undone.")
                // ^ Warns the user about the irreversible action
            }
        }
    }

    // MARK: - Empty State

    /// Shown when the user has no downloads yet, explains what downloads are
    /// and how to create one.
    private var emptyState: some View {
        VStack(spacing: 16) {
            // ^ Vertical stack with 16 points between each child
            Image(systemName: "arrow.down.circle")
                // ^ A cloud-with-down-arrow icon from SF Symbols
                .font(.system(size: 60))
                // ^ Large icon (60 points) to draw attention
                .foregroundColor(.secondary)
                // ^ Grey tint to keep it subtle

            Text("No Downloads")
                // ^ Main heading for the empty state
                .font(.title2)
                // ^ Slightly smaller than the default title

            Text("Download songs from the player to listen offline")
                // ^ Subtitle explaining what the user should do
                .font(.subheadline)
                // ^ Smaller secondary text
                .foregroundColor(.secondary)
                // ^ Grey colour to de-emphasise it
                .multilineTextAlignment(.center)
                // ^ Centre-align because the text wraps to multiple lines

            // Call to action, tells user how to download
            Text("Tap the download icon on any song")
                // ^ A hint pointing to the download button on player rows
                .font(.caption)
                // ^ Very small caption text
                .foregroundColor(.blue)
            // ^ Blue to make it look like a tappable hint
        }
    }

    // MARK: - Downloads List

    /// Shown when there's at least one download, a storage summary section
    /// followed by the list of downloaded songs.
    private var downloadsList: some View {
        List {
            // ^ A vertical scrolling list of rows
            storageSummarySection
            songsSection
        }
    }

    /// A one-row section showing how many songs are downloaded and how much
    /// space they take up on disk.
    private var storageSummarySection: some View {
        Section {
            // ^ A grouped section in the list
            HStack {
                // ^ Horizontal row: "Storage Used" on the left, stats on the right
                Text("Storage Used")
                // ^ Label describing what the row shows
                Spacer()
                // ^ Pushes the stats to the right

                // Show count and total size.
                // The storage size is computed before the string so the
                // ByteCountFormatter call stays out of string interpolation
                // (keeps the parser happy and the code readable).
                let storageText = ByteCountFormatter.string(
                    fromByteCount: offlineManager.totalStorageUsed(),
                    countStyle: .file
                )
                Text("\(offlineManager.downloads.count) songs • \(storageText)")
                    .foregroundColor(.secondary)
                // ^ Grey text for the statistics
            }
        }
    }

    /// The section listing every downloaded song, with tap-to-play and
    /// swipe-to-delete support.
    private var songsSection: some View {
        Section {
            // ^ A second section containing the actual song rows
            ForEach(offlineManager.downloads) { song in
                // ^ Loop over every downloaded song (uses Identifiable conformance,
                // a protocol requirement that gives each `DownloadedSong` a
                // stable `id` SwiftUI can use to track which row is which)
                DownloadRow(song: song)
                    // ^ The visual row for a downloaded song
                    .onTapGesture {
                        // ^ When the user taps the row…
                        playSong(song)
                        // ^ …play that song from the local cache
                    }
            }
            .onDelete(perform: deleteSongs)
            // ^ Swipe-to-delete handler for the list rows, implemented
            // below in `deleteSongs(at:)`.
        }
    }

    /// Toolbar contents for the navigation bar, just the "Clear All" button,
    /// only shown when there's something to clear.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // ^ Add buttons to the top navigation bar
        if !offlineManager.downloads.isEmpty {
            // ^ Only show the toolbar button when there are downloads

            // "Clear All" button in the top-right
            ToolbarItem(placement: .navigationBarTrailing) {
                // ^ Place a button on the right side of the bar
                Button("Clear All") {
                    // ^ A text button labelled "Clear All"
                    showClearAllAlert = true
                    // ^ Show the confirmation alert when tapped
                }
                .foregroundColor(.red)
                // ^ Red text indicating a destructive action
            }
        }
    }

    // MARK: - List Editing Helpers

    /// Deletes the swiped-away songs from `offlineManager`.
    ///
    /// BUG FIX: the previous version looped over `indexSet` and read
    /// `offlineManager.downloads[index]` *inside* the loop, deleting one song
    /// per iteration as it went. That's unsafe whenever more than one row is
    /// removed at once (e.g. deleting rows 0 and 2 together via Edit mode):
    /// after the first deletion, `offlineManager.downloads` shrinks and every
    /// later index shifts down by one, so the second `downloads[index]` reads
    /// the *wrong* song, or, if it was the last row, indexes past the end of
    /// the array and crashes the app with an out-of-range error.
    ///
    /// The fix is to first snapshot which *songs* (not index numbers) the
    /// given indices point to, all before any deletions happen, then delete
    /// each one by its stable `videoId`. Deleting by identity instead of by
    /// position means later deletions can never be thrown off by earlier ones.
    /// - Parameter indexSet: the row positions the user swiped/selected to delete
    private func deleteSongs(at indexSet: IndexSet) {
        // Capture the actual songs at these positions *before* mutating anything.
        let songsToDelete = indexSet.map { offlineManager.downloads[$0] }
        for song in songsToDelete {
            // ^ Loop over the captured songs, not shifting indices
            offlineManager.delete(videoId: song.videoId)
            // ^ Remove its cached file and metadata from storage
        }
    }

    // MARK: - Playback Helpers

    /// Play a downloaded song from the local cache.
    ///
    /// FLOW:
    /// 1. Get the local file URL from OfflineManager
    /// 2. Pass it to AudioPlayer's new playLocal() method
    /// 3. AudioPlayer plays from the file instead of streaming
    /// - Parameter song: The downloaded song to play
    private func playSong(_ song: DownloadedSong) {
        // ^ Private method called when the user taps a downloaded song row
        guard let localURL = offlineManager.localURL(for: song.videoId) else {
            // ^ Ask OfflineManager for the file path of the cached video.
            // `guard let` unwraps the optional URL if it exists, or runs the
            // `else` block and exits the function early if it's `nil`.
            print("Downloaded file not found for \(song.videoId)")
            // ^ Log a warning to the console for debugging
            return
        }

        // Play from local cache.
        // playLocal is async, so we wrap the call in a Task.
        Task {
            // `Task { ... }` starts a new unit of asynchronous work. `await`
            // (below) pauses this task, without blocking the rest of the
            // app, until `playLocal` finishes.
            await audioPlayer.playLocal(
                // ^ Call the player with a local file instead of streaming
                videoId: song.videoId,
                // ^ The unique YouTube video identifier
                title: song.title,
                // ^ The song title for the now-playing display
                artist: song.artist,
                // ^ The artist name for the now-playing display
                thumbnailUrl: song.thumbnailUrl,
                // ^ The album art URL for the now-playing display
                localURL: localURL,
                // ^ The local file URL, player reads from disk, not the network
                duration: 0 // Duration unknown for cached songs, AudioPlayer will detect it
                // ^ Pass 0 so the player auto-detects the track length from the file
            )
        }
    }
}

// MARK: - Download Row

/// A single row in the downloads list.
///
/// Shows: album art, title, artist, and download date.
struct DownloadRow: View {
    // ^ A small reusable view used inside ForEach in DownloadsView

    let song: DownloadedSong
    // ^ The downloaded-song model to display (title, artist, thumbnail, video ID, etc.)

    var body: some View {
        // ^ The row's visual layout
        HStack(spacing: 12) {
            // ^ Horizontal stack with 12 points between elements
            thumbnail
            songInfo
            Spacer()
            // ^ Pushes everything to the left; keeps the row full-width
            offlineIndicator
        }
    }

    /// Album art thumbnail, loaded asynchronously from the network with a
    /// gray-box placeholder while it downloads.
    private var thumbnail: some View {
        // AsyncImage loads an image from a URL in the background (off the
        // main thread) so it never freezes the UI while the network request
        // is in flight. `URL(string:)` returns an *optional* URL, if
        // `song.thumbnailUrl` were ever malformed, this becomes `nil` and
        // AsyncImage simply falls through to the `placeholder` closure below
        // instead of crashing, which is why no force-unwrap (`!`) is needed here.
        AsyncImage(url: URL(string: song.thumbnailUrl)) { image in
            // ^ The successfully loaded image
            image
                .resizable()
                // ^ Allow the image to stretch/shrink to fit its frame
                .aspectRatio(contentMode: .fill)
            // ^ Crop to fill the frame while keeping proportions
        } placeholder: {
            // ^ What to show while the image is downloading
            Rectangle()
                // ^ A simple grey rectangle placeholder
                .fill(Color.gray.opacity(0.3))
            // ^ Light grey fill so the row still has a visible thumbnail area
        }
        .frame(width: 48, height: 48)
        // ^ Fixed 48×48 point bounding box for the thumbnail
        .cornerRadius(6)
        // ^ Slightly rounded corners (6 point radius)
    }

    /// Title + artist text stack.
    private var songInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            // ^ Vertical stack, left-aligned, tight spacing
            Text(song.title)
                // ^ The song title
                .font(.subheadline)
                // ^ Slightly smaller than body text
                .lineLimit(1)
                // ^ Truncate to a single line if the title is long

            Text(song.artist)
                // ^ The artist name
                .font(.caption)
                // ^ Very small text for secondary info
                .foregroundColor(.secondary)
                // ^ Grey colour to de-emphasise it
                .lineLimit(1)
            // ^ Truncate to a single line if the artist name is long
        }
    }

    /// Small green "available offline" badge.
    private var offlineIndicator: some View {
        Image(systemName: "arrow.down.circle.fill")
            // ^ A filled circle with a down-arrow, shows this song is cached
            .foregroundColor(.green)
        // ^ Green colour signals "available offline"
    }
}

#Preview {
    // ^ Xcode preview canvas, renders this view without building the full app
    DownloadsView()
        .environmentObject(OfflineManager())
        // ^ Inject a fresh OfflineManager for preview
        .environmentObject(AudioPlayer())
        // ^ Inject a fresh AudioPlayer for preview
}
