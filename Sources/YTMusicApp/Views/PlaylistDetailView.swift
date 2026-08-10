// Imports the SwiftUI framework, this gives us access to all
// Apple's UI building blocks: Views, Lists, Buttons, Images, etc.
import SwiftUI

/// Shows all songs in a playlist with options to play, reorder, and remove.
///
/// Users can:
/// - Tap a song to play the entire playlist starting from that song
/// - Swipe to remove songs from the playlist
/// - Drag to reorder songs
/// - Tap "Play All" to play the playlist from the beginning
/// - Tap "Download All" to save all songs for offline playback
struct PlaylistDetailView: View {
    // ↓ A struct is like a blueprint. Every line inside defines
    //   what this screen looks like and how it behaves.

    /// The playlist to display
    // This is a constant property, it gets set when this view is created
    // and never changes. It holds all the data for the playlist being shown.
    let playlist: Playlist

    /// The playlist manager for modifying the playlist
    // @EnvironmentObject means SwiftUI injects this from the parent view
    // automatically. PlaylistManager handles saving/loading/deleting playlists.
    @EnvironmentObject var playlistManager: PlaylistManager

    /// The audio player for playback
    // Another environment object provided higher up in the app.
    // AudioPlayer controls music playback (play, pause, skip, etc.).
    @EnvironmentObject var audioPlayer: AudioPlayer

    /// The offline manager for downloading songs
    @EnvironmentObject var offlineManager: OfflineManager

    /// The API client for fetching external playlist data
    @EnvironmentObject var apiClient: APIClient

    /// Whether to show the rename alert
    // @State tells SwiftUI to watch this value and re-render the view
    // whenever it changes. Starts as false, the alert is hidden.
    @State private var showRenameAlert = false

    /// The new name for renaming
    // Stores whatever the user types into the rename text field.
    // Starts as an empty string.
    @State private var renameText = ""

    /// Whether downloads are in progress for "Download All"
    @State private var isDownloadingAll = false

    // body is the required property of the View protocol.
    // It describes the entire screen layout and behavior.
    //
    // NOTE ON STRUCTURE: this body used to be one very long expression with
    // every section inlined. It's now split into small computed properties
    // (playlistHeaderSection, emptyStateSection, songsSection, toolbarMenu)
    // below. A "computed property" is a property that isn't stored, instead
    // its value is calculated by running a small chunk of code every time you
    // read it. Splitting a view this way makes each piece easier to read,
    // easier for the Swift compiler to type-check, and easier to reuse.
    var body: some View {
        // List is a scrolling container that can have sections and rows.
        // It also supports swipe-to-delete and drag-to-reorder.
        List {
            // ── PLAYLIST HEADER ──────────────────────────────────
            playlistHeaderSection

            // ── SONGS LIST ──────────────────────────────────────
            // If there are no songs, show a friendly empty-state message,
            // otherwise show the real list of songs. This is a ternary-like
            // branch using a plain `if/else`, SwiftUI is fine with either
            // branch appearing since both produce "some View".
            if playlist.songs.isEmpty {
                emptyStateSection
            } else {
                songsSection
            }
        }
        // Sets the navigation bar title to the playlist's name.
        .navigationTitle(playlist.name)
        // Makes the title appear in the center of the nav bar (small style).
        .navigationBarTitleDisplayMode(.inline)
        // Adds buttons and menus to the navigation bar area.
        .toolbar {
            // Places this item on the right side of the navigation bar.
            ToolbarItem(placement: .navigationBarTrailing) {
                toolbarMenu
            }
        }
        // Presents an alert dialog for renaming the playlist.
        .alert("Rename Playlist", isPresented: $showRenameAlert) {
            // A text input field inside the alert, bound to renameText.
            TextField("Playlist Name", text: $renameText)
            // A "Save" button that commits the rename.
            Button("Save") {
                // Trim whitespace; if the result is empty, do nothing and return.
                guard !renameText.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                // Tells the manager to update the playlist's name.
                playlistManager.renamePlaylist(playlist, newName: renameText)
            }
            // A "Cancel" button that dismisses the alert without saving.
            Button("Cancel", role: .cancel) { }
        }
    }

    // MARK: - Body sub-sections
    // Each computed property below returns "some View", a shorthand type
    // that means "some concrete SwiftUI view type, but I won't tell you
    // exactly which one." That's what lets SwiftUI's declarative style
    // (describing WHAT the UI should look like, rather than writing
    // step-by-step instructions for HOW to build it) work without every
    // view needing an explicit, spelled-out type name.

    /// The header at the top of the screen: icon, name, song count/duration,
    /// and the "Play All" / "Download All" action buttons.
    @ViewBuilder
    private var playlistHeaderSection: some View {
        // Section groups related rows together in a List.
        Section {
            // VStack arranges children vertically with 12 pts spacing.
            VStack(spacing: 12) {
                // Playlist icon
                // SF Symbol for a stack of squares, a generic playlist icon.
                Image(systemName: "square.stack.fill")
                    // Sets the icon size to 50 pts (large title size).
                    .font(.system(size: 50))
                    // Colors the icon blue.
                    .foregroundColor(.blue)

                // Playlist name
                // Shows the playlist's name as a text label.
                Text(playlist.name)
                    // Uses title2 font style (medium-large heading).
                    .font(.title2)
                    // Makes the text bold for emphasis.
                    .fontWeight(.bold)

                // Song count and duration
                // Displays e.g. "12 songs • 45:30" using string interpolation.
                Text("\(playlist.songCount) songs • \(playlist.totalDuration)")
                    // Uses the subheadline font style (smaller than body).
                    .font(.subheadline)
                    // Uses the secondary color (usually gray) for less emphasis.
                    .foregroundColor(.secondary)

                // Play All / Download All buttons
                // Only show the buttons if the playlist has at least one song.
                if !playlist.songs.isEmpty {
                    playAllButton
                    downloadAllButton
                }
            }
            // Makes the VStack stretch across the full width of the screen.
            .frame(maxWidth: .infinity)
            // Adds vertical padding around the entire header area.
            .padding(.vertical)
        }
        // Removes the default gray background from this section row.
        .listRowBackground(Color.clear)
    }

    /// A tappable button that triggers playAll() when pressed.
    private var playAllButton: some View {
        Button(action: {
            // Calls the private method below to start playback.
            playAll()
        }) {
            // HStack arranges the icon and text side-by-side.
            HStack {
                // Play icon from SF Symbols.
                Image(systemName: "play.fill")
                // Label text.
                Text("Play All")
            }
            // Uses headline font style (slightly bold body text).
            .font(.headline)
            // White text on the blue button.
            .foregroundColor(.white)
            // Stretches the button to fill the whole width.
            .frame(maxWidth: .infinity)
            // Adds 12 pts of vertical padding inside the button.
            .padding(.vertical, 12)
            // Fills the background with Apple's blue color.
            .background(Color.blue)
            // Rounds the corners by 12 pts.
            .cornerRadius(12)
        }
        // Lets VoiceOver announce a clear label for this button.
        .accessibilityLabel("Play all songs")
    }

    /// Downloads every song in the playlist for offline playback.
    ///
    /// BUG FIX: `isDownloadingAll` used to be set to `true`/`false` by
    /// downloadAll() but nothing in the UI ever read it, so the button
    /// never visibly reacted while a bulk download was running, a classic
    /// "dead state" bug (a variable that's written but never observed).
    /// Now the button shows a spinner and disables itself while the
    /// download is in progress, so isDownloadingAll actually does something.
    private var downloadAllButton: some View {
        Button(action: {
            downloadAll()
        }) {
            // HStack arranges the icon and text side-by-side.
            HStack {
                if isDownloadingAll {
                    // A small spinning activity indicator, tinted white to
                    // match the button's text/icon color.
                    ProgressView()
                        .tint(.white)
                } else {
                    // Download icon from SF Symbols.
                    Image(systemName: "arrow.down.circle")
                }
                // Label text changes while the download is running so the
                // user gets feedback that something is actually happening.
                Text(isDownloadingAll ? "Downloading…" : "Download All")
            }
            // Uses headline font style (slightly bold body text).
            .font(.headline)
            // White text on the blue button.
            .foregroundColor(.white)
            // Stretches the button to fill the whole width.
            .frame(maxWidth: .infinity)
            // Adds 12 pts of vertical padding inside the button.
            .padding(.vertical, 12)
            // Fills the background with green (download color).
            .background(Color.green)
            // Rounds the corners by 12 pts.
            .cornerRadius(12)
        }
        // Prevents double-tapping "Download All" while one run is already
        // in progress, which would kick off a second overlapping Task loop.
        .disabled(isDownloadingAll)
        .accessibilityLabel(isDownloadingAll ? "Downloading all songs" : "Download all songs")
    }

    /// Friendly empty-state message shown when the playlist has no songs.
    private var emptyStateSection: some View {
        Section {
            // Centers the empty-state content vertically.
            VStack(spacing: 12) {
                // A small music note icon.
                Image(systemName: "music.note")
                    // Uses title2 font size.
                    .font(.title2)
                    // Gray color for subtle appearance.
                    .foregroundColor(.secondary)

                // Main empty-state heading.
                Text("No songs in this playlist")
                    // Small font below the body size.
                    .font(.subheadline)
                    // Gray color.
                    .foregroundColor(.secondary)

                // Instructional sub-text explaining how to add songs.
                Text("Add songs from the player or search results")
                    // Even smaller caption font.
                    .font(.caption)
                    // Gray color like the rest of the empty state.
                    .foregroundColor(.secondary)
                    // Allows the text to wrap to multiple lines and center.
                    .multilineTextAlignment(.center)
            }
            // Centers the stack horizontally in the List.
            .frame(maxWidth: .infinity)
            // Adds padding around the entire empty-state area.
            .padding()
        }
    }

    /// The real list of songs, with tap-to-play, swipe-to-remove, and
    /// drag-to-reorder support.
    private var songsSection: some View {
        Section {
            // Loops over each song with its index (0, 1, 2...).
            // .enumerated() gives us (index, song) pairs.
            // ForEach is SwiftUI's way of turning a collection into a list
            // of views, it re-runs its closure for every element.
            // id: \.element.id tells SwiftUI each row is unique by song.id,
            // which is how it knows which row moved/was removed on updates.
            ForEach(Array(playlist.songs.enumerated()), id: \.element.id) { index, song in
                // The entire row is a button, tapping it starts playback.
                Button(action: {
                    // Play this song and the rest of the playlist
                    // Calls the private method below starting at this index.
                    playFrom(index: index)
                }) {
                    // The row is a separate function so the compiler can
                    // type-check it on its own (the combined expression
                    // was too large for Swift's type-checker).
                    songRow(song: song, index: index)
                }
                // Removes the default blue highlight when tapping the row.
                .buttonStyle(.plain)
                // Adds a swipe gesture on the right edge of the row.
                .swipeActions(edge: .trailing) {
                    // A red "destructive" button that appears when swiping.
                    Button(role: .destructive) {
                        // Removes this specific song from the playlist.
                        playlistManager.removeSong(song, from: playlist)
                    } label: {
                        // The button shows a trash icon with "Remove" label.
                        Label("Remove", systemImage: "trash")
                    }
                }
            }
            // Enables drag-to-reorder on the list rows.
            // source: the positions being moved; destination: where they land.
            .onMove { source, destination in
                // Reorder songs within the playlist
                // Calls the private reorder method defined below.
                reorderSongs(from: source, to: destination)
            }
        }
    }

    /// The "…" drop-down menu in the navigation bar: share, rename, delete.
    @ViewBuilder
    private var toolbarMenu: some View {
        // A drop-down menu (three-dot menu on iPhone).
        Menu {
            // Share playlist as text
            // Only show the Share option if there are songs.
            if !playlist.songs.isEmpty {
                // A built-in SwiftUI share sheet button.
                ShareLink(
                    // The text content to share.
                    item: playlistShareText,
                    // Preview shows the playlist name when sharing.
                    preview: SharePreview(playlist.name)
                ) {
                    // The menu item label with share icon.
                    Label("Share Playlist", systemImage: "square.and.arrow.up")
                }
            }

            // A "Rename" button in the menu.
            Button(action: {
                // Pre-fills the text field with the current name.
                renameText = playlist.name
                // Shows the rename alert as a pop-up.
                showRenameAlert = true
            }) {
                // Menu item with pencil icon.
                Label("Rename", systemImage: "pencil")
            }

            // A red "Delete Playlist" button in the menu.
            Button(role: .destructive, action: {
                // Permanently deletes the entire playlist.
                playlistManager.deletePlaylist(playlist)
            }) {
                // Menu item with trash icon.
                Label("Delete Playlist", systemImage: "trash")
            }
        } label: {
            // The three-dot circle icon that opens the menu.
            Image(systemName: "ellipsis.circle")
        }
        // Lets VoiceOver announce what this button does before it's tapped.
        .accessibilityLabel("Playlist options")
    }

    // MARK: - Playback
    // Everything below this point is helper logic (not UI layout).

    /// Play the entire playlist from the beginning.
    // This is called when the user taps the "Play All" button.
    private func playAll() {
        // Safety check: if there are no songs, exit early.
        guard !playlist.songs.isEmpty else { return }
        // Donate a Siri shortcut for this playlist so user can say "Play My Playlist Name".
        SiriShortcutsManager.donatePlayPlaylist(name: playlist.name)
        // Tell the audio player to play all songs starting at index 0 (the first song).
        audioPlayer.playAll(playlist.songs, startAt: 0)
    }

    /// Play the playlist starting from a specific song index.
    // This is called when the user taps an individual song row.
    private func playFrom(index: Int) {
        // Safety check: make sure the index is within the song list bounds.
        guard index < playlist.songs.count else { return }
        // Donate a Siri shortcut for this playlist so Siri learns it.
        SiriShortcutsManager.donatePlayPlaylist(name: playlist.name)
        // Tell the audio player to play all songs starting from the given index.
        audioPlayer.playAll(playlist.songs, startAt: index)
    }

    /// Download all songs in the playlist for offline playback.
    private func downloadAll() {
        guard !playlist.songs.isEmpty else { return }
        
        isDownloadingAll = true
        
        Task {
            for song in playlist.songs {
                // Skip if already downloaded
                guard !offlineManager.isDownloaded(song.id),
                      !offlineManager.isDownloading(song.id) else { continue }
                
                do {
                    let playerInfo = try await apiClient.getPlayerInfoForDownload(videoId: song.id)
                    await offlineManager.download(
                        videoId: song.id,
                        title: song.title,
                        artist: song.artist,
                        audioUrl: playerInfo.audioUrl,
                        thumbnailUrl: song.thumbnailUrl
                    )
                } catch {
                    print("Failed to download \(song.title): \(error)")
                }
            }
            
            isDownloadingAll = false
        }
    }
    
    /// Reorder songs within the playlist.
    // Triggered when the user drags a song to a new position in the list.
    private func reorderSongs(from source: IndexSet, to destination: Int) {
        // Find the index of the current playlist inside the manager's playlists array.
        guard let playlistIndex = playlistManager.playlists.firstIndex(where: { $0.id == playlist.id }) else { return }

        // Get the mutable playlist
        // Make a copy of the playlist so we can edit its songs array.
        var updatedPlaylist = playlistManager.playlists[playlistIndex]

        // Perform the move on the songs array
        // Swift's built-in move method handles the offset calculations.
        updatedPlaylist.songs.move(fromOffsets: source, toOffset: destination)

        // Update the playlist
        // Write the modified playlist back into the manager's array.
        playlistManager.playlists[playlistIndex] = updatedPlaylist
        // Persist the updated playlists to disk (UserDefaults or file).
        playlistManager.savePlaylists()
    }

    /// Format duration as "M:SS" or "H:MM:SS".
    // Converts a raw number of seconds into a human-readable time string.
    private func formatDuration(_ seconds: Int) -> String {
        // Calculate hours: 3600 seconds per hour.
        let hours = seconds / 3600
        // Calculate minutes: remaining seconds after hours divided by 60.
        let minutes = (seconds % 3600) / 60
        // Calculate remaining seconds after minutes and hours.
        let secs = seconds % 60

        // If the duration is an hour or longer, include hours in the string.
        if hours > 0 {
            // Returns e.g. "1:23:45" (hours:minutes:seconds with zero-padding).
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            // Returns e.g. "23:45" (minutes:seconds with zero-padding).
            return String(format: "%d:%02d", minutes, secs)
        }
    }

    /// Build the visual row for a single song in the playlist.
    ///
    /// Extracted into its own function so Swift's type-checker can
    /// handle this expression separately (the original inline row
    /// made the compiler time out).
    @ViewBuilder
    private func songRow(song: NowPlaying, index: Int) -> some View {
        // HStack lays out the row content horizontally.
        HStack(spacing: 12) {
            // Position number
            // Shows the 1-based position (index + 1).
            Text("\(index + 1)")
                // Small font.
                .font(.subheadline)
                // Gray color.
                .foregroundColor(.secondary)
                // Fixed width so all numbers align vertically.
                .frame(width: 24)

            // Album art thumbnail
            // AsyncImage loads an image from a URL asynchronously.
            AsyncImage(url: URL(string: song.thumbnailUrl)) { image in
                // Once loaded, make the image resizable and fill its frame.
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                // While loading, show a gray rectangle placeholder.
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
            }
            // Sets thumbnail dimensions: 48 x 48 pts.
            .frame(width: 48, height: 48)
            // Rounds the thumbnail corners slightly.
            .cornerRadius(6)

            // Song info
            // Vertical stack with the song title and artist.
            VStack(alignment: .leading, spacing: 4) {
                // The song's title text.
                Text(song.title)
                    // Small font.
                    .font(.subheadline)
                    // Truncate with ellipsis if too long (single line).
                    .lineLimit(1)
                    // Black/dark text (primary color).
                    .foregroundColor(.primary)

                // The song's artist name.
                Text(song.artist)
                    // Even smaller caption font.
                    .font(.caption)
                    // Gray color.
                    .foregroundColor(.secondary)
                    // Also truncate if too long.
                    .lineLimit(1)
            }

            // Pushes everything to the left; keeps duration on the right.
            Spacer()

            // Duration
            // Formats seconds into readable "M:SS" or "H:MM:SS".
            Text(formatDuration(song.duration))
                // Small caption font.
                .font(.caption)
                // Gray color.
                .foregroundColor(.secondary)
        }
    }

    /// Generate shareable text for the playlist.
    ///
    /// Formats the playlist as a nice text list that can be shared
    /// via Messages, Notes, AirDrop, etc.
    // This is a computed property, it generates the text on the fly.
    private var playlistShareText: String {
        // Start with the playlist name followed by a newline.
        var text = "\(playlist.name)\n"
        // Add a separator line of 20 em-dashes.
        text += String(repeating: "\u{2014}", count: 20) + "\n"

        // Loop through every song with its position number (1-based).
        for (index, song) in playlist.songs.enumerated() {
            // Append e.g. "1. Song Title, Artist Name\n".
            text += "\(index + 1). \(song.title) \u{2014} \(song.artist)\n"
        }

        // Append the total song count and duration summary.
        text += "\n\(playlist.songCount) songs \u{2022} \(playlist.totalDuration)"
        // Append a branding footer.
        text += "\nShared from YouTube Music"

        // Return the fully constructed string.
        return text
    }
}

// #Preview provides a live preview in Xcode's canvas.
// It creates a sample PlaylistDetailView with placeholder data.
// This code only runs during previews, not in the actual app.
#Preview {
    // Wraps the view in a NavigationView to match the real app's context.
    NavigationView {
        // Creates a PlaylistDetailView with a sample empty playlist.
        PlaylistDetailView(playlist: Playlist(
            id: "1",               // Dummy ID for preview.
            name: "My Playlist",   // Dummy name visible in the preview.
            songs: [],             // Empty songs array, shows empty state.
            createdAt: Date()      // Sets creation date to right now.
        ))
        // Injects a fake PlaylistManager for the @EnvironmentObject.
        .environmentObject(PlaylistManager())
        // Injects a fake AudioPlayer for the @EnvironmentObject.
        .environmentObject(AudioPlayer())
    }
}
