import SwiftUI
// ^ Import Apple's SwiftUI framework for building user interfaces

/// The Library tab showing downloaded songs and local playlists.
///
/// This is the main library screen where users can:
/// - View their downloaded songs for offline playback
/// - Create and manage local playlists
/// - Tap a playlist to see its songs
///
/// GLOSSARY (terms explained here the first time they appear in this file):
/// - **@EnvironmentObject**: reads a shared object injected by a parent view
///   via `.environmentObject(...)`, instead of being passed in explicitly.
///   The view automatically re-renders when that object's data changes.
/// - **@State**: a property wrapper for small pieces of view-local state kept
///   only in memory. Changing it tells SwiftUI to redraw whatever part of the
///   view depends on it.
/// - **Binding**: a two-way, live connection to a value owned elsewhere. A
///   `$` prefix (e.g. `$newPlaylistName`) turns a `@State` property into a
///   `Binding` that a control like `TextField` can both read and write.
/// - **NavigationLink**: a tappable row that pushes a new screen onto the
///   navigation stack when tapped, the standard way to drill down from a
///   list into a detail view in SwiftUI.
/// - **guard**: an early-exit check, `guard condition else { return }` means
///   "require this to be true, otherwise stop here," keeping the rest of the
///   function free of extra nested `if` indentation.
struct PlaylistsView: View {

    // MARK: - Injected Dependencies

    /// The playlist manager for creating/managing playlists
    @EnvironmentObject var playlistManager: PlaylistManager

    /// The audio player for playing songs
    @EnvironmentObject var audioPlayer: AudioPlayer

    /// The offline manager for downloaded songs
    @EnvironmentObject var offlineManager: OfflineManager

    // MARK: - Local State

    /// Whether to show the "New Playlist" alert
    @State private var showNewPlaylistAlert = false

    /// The name for the new playlist being created
    @State private var newPlaylistName = ""

    // MARK: - UI Body

    // `body` stays short by delegating each section of the list, the
    // toolbar, and the alert to their own computed properties below,
    // each one named for exactly what it shows, so the overall structure
    // of the screen is readable at a glance.
    var body: some View {
        // ^ The main view content, SwiftUI renders this on screen
        NavigationView {
            // ^ Wraps everything in a navigation controller (top bar + titles)
            List {
                // ^ A vertical scrolling list of sections and rows
                playlistsSection
                downloadedSongsSection
            }
            .navigationTitle("Library")
            // ^ Set the title shown in the navigation bar at the top
            .toolbar { toolbarContent }
            // Alert for creating a new playlist
            .alert("New Playlist", isPresented: $showNewPlaylistAlert) {
                // ^ A modal alert that appears when showNewPlaylistAlert is true
                TextField("Playlist Name", text: $newPlaylistName)
                // ^ A text field where the user types the playlist name
                Button("Create") {
                    // ^ The "Create" button inside the alert
                    guard !newPlaylistName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    // ^ Don't create if the name is empty or only spaces
                    playlistManager.createPlaylist(name: newPlaylistName)
                    // ^ Tell the manager to persist the new playlist
                    newPlaylistName = ""
                    // ^ Reset the text field for next time
                }
                Button("Cancel", role: .cancel) {
                    // ^ Dismisses the alert without doing anything
                    newPlaylistName = ""
                    // ^ Clear the text field on cancel too
                }
            } message: {
                // ^ The body text below the alert title
                Text("Enter a name for your new playlist")
            }
        }
    }

    // MARK: - Playlists Section

    /// The "Playlists" section: either an empty-state hint, or the list of
    /// existing playlists with pin/delete actions. Header includes the "+"
    /// button for creating a new playlist.
    private var playlistsSection: some View {
        Section {
            // ^ A grouped section in the list with a header
            if playlistManager.playlists.isEmpty {
                // ^ Check if the user has any playlists yet
                playlistsEmptyState
            } else {
                // ^ User has playlists, show them
                playlistRows
            }
        } header: {
            playlistsSectionHeader
        }
    }

    /// Shown inside `playlistsSection` when there are no playlists yet.
    private var playlistsEmptyState: some View {
        VStack(spacing: 8) {
            // ^ Vertical stack to lay out empty-state elements
            Image(systemName: "music.note.list")
                // ^ A music-note list icon from SF Symbols
                .font(.title2)
                // ^ Set the icon size to title2
                .foregroundColor(.secondary)
                // ^ Use the secondary (grey) tint color

            Text("No playlists yet")
                // ^ A label telling the user no playlists exist
                .font(.subheadline)
                // ^ Smaller font than body text
                .foregroundColor(.secondary)
                // ^ Grey text to keep it subtle
        }
        .frame(maxWidth: .infinity)
        // ^ Stretch the VStack to fill the row width
        .padding(.vertical, 8)
        // ^ Add 8 points of vertical spacing around it
    }

    /// The actual list of playlist rows, shown when at least one playlist exists.
    private var playlistRows: some View {
        // Using `Group` lets us attach `.onDelete` to the whole ForEach as if
        // it were a single child of the List, matching how SwiftUI expects
        // swipe-to-delete to be wired up.
        Group {
            // List of playlists
            ForEach(playlistManager.playlists) { playlist in
                // ^ Loop over every playlist using its Identifiable conformance
                // (a protocol requirement giving each Playlist a stable `id`)
                NavigationLink(destination: PlaylistDetailView(playlist: playlist)) {
                    // ^ A tappable row that navigates to the detail view
                    PlaylistRow(playlist: playlist)
                    // ^ The visual row showing playlist name / counts
                }
                .contextMenu {
                    // .contextMenu shows this menu on a long-press, an
                    // alternative, discoverable way to reach the same actions
                    // as swiping.
                    // Pin/Unpin toggle
                    Button {
                        playlistManager.togglePin(playlist)
                    } label: {
                        Label(
                            playlist.isPinned ? "Unpin" : "Pin to Top",
                            systemImage: playlist.isPinned ? "pin.slash" : "pin"
                        )
                    }

                    // Delete
                    Button(role: .destructive) {
                        playlistManager.deletePlaylist(playlist)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .onDelete(perform: deletePlaylists)
            // ^ Attach swipe-to-delete to each row, implemented below in
            // `deletePlaylists(at:)`.
        }
    }

    /// Header row for the playlists section: title + "add playlist" button.
    private var playlistsSectionHeader: some View {
        HStack {
            // ^ Horizontal row for "Playlists" label + plus button
            Text("Playlists")
            // ^ Section title
            Spacer()
            // ^ Pushes the button to the right side

            // Add playlist button
            Button(action: {
                // ^ Tapping this button…
                showNewPlaylistAlert = true
                // ^ …shows the alert for naming a new playlist
            }) {
                Image(systemName: "plus")
                    // ^ A "+" icon from SF Symbols
                    .font(.subheadline)
                    // ^ Small font to match the header size
            }
        }
    }

    // MARK: - Downloaded Songs Section

    /// The "Downloads" section, only shown when at least one song is
    /// downloaded. Reuses `DownloadRow` from DownloadsView.swift so a
    /// downloaded song looks the same everywhere it appears.
    @ViewBuilder
    private var downloadedSongsSection: some View {
        // @ViewBuilder lets this computed property conditionally return
        // "nothing" (via the implicit empty case below) or a full Section,
        // which a plain `some View` return type can't express on its own.
        if !offlineManager.downloads.isEmpty {
            // ^ Only show this section if at least one song is downloaded
            Section {
                // ^ A second grouped section
                ForEach(offlineManager.downloads) { song in
                    // ^ Loop over every downloaded song
                    DownloadRow(song: song)
                        // ^ The visual row for a downloaded song
                        .onTapGesture {
                            // ^ When the user taps the row…
                            playSong(song)
                            // ^ …play that song from the local cache
                        }
                }
                .onDelete(perform: deleteDownloadedSongs)
                // ^ Swipe-to-delete for downloaded songs, implemented below.
            } header: {
                // ^ Section header showing download count
                Text("Downloads (\(offlineManager.downloads.count))")
                // ^ E.g. "Downloads (3)"
            }
        }
    }

    // MARK: - Toolbar

    private var toolbarContent: some ToolbarContent {
        // ^ Add buttons to the top navigation bar
        ToolbarItem(placement: .navigationBarTrailing) {
            // ^ Place a button on the right side of the bar
            Button(action: {
                // ^ Tapping shows the new-playlist alert
                showNewPlaylistAlert = true
            }) {
                Image(systemName: "plus")
                // ^ "+" icon in the toolbar
            }
        }
    }

    // MARK: - List Editing Helpers

    /// Deletes the swiped-away playlists from `playlistManager`.
    ///
    /// BUG FIX: this used to loop over `indexSet` and call
    /// `playlistManager.deletePlaylist(playlistManager.playlists[index])`
    /// inside the loop, reading `playlists[index]` fresh on every
    /// iteration. That's broken for multi-row deletes: deleting one playlist
    /// shrinks the `playlists` array, which shifts every later index down by
    /// one, so the next iteration deletes the wrong playlist (or, if the
    /// deleted row was near the end, indexes past the array and crashes).
    /// Instead, we snapshot the actual `Playlist` values at the given
    /// indices *before* deleting anything, then delete each one by its own
    /// identity, which stays correct no matter what order deletions happen in.
    /// - Parameter indexSet: the row positions the user swiped/selected to delete
    private func deletePlaylists(at indexSet: IndexSet) {
        let playlistsToDelete = indexSet.map { playlistManager.playlists[$0] }
        for playlist in playlistsToDelete {
            // ^ Loop over the captured playlists, not shifting indices
            playlistManager.deletePlaylist(playlist)
            // ^ Remove that playlist from storage
        }
    }

    /// Deletes the swiped-away downloaded songs from `offlineManager`.
    /// Same index-shift hazard and fix as `deletePlaylists(at:)` above and as
    /// `DownloadsView.deleteSongs(at:)`, indices are snapshotted into actual
    /// songs before any deletion happens.
    /// - Parameter indexSet: the row positions the user swiped/selected to delete
    private func deleteDownloadedSongs(at indexSet: IndexSet) {
        let songsToDelete = indexSet.map { offlineManager.downloads[$0] }
        for song in songsToDelete {
            // ^ Loop over the captured songs, not shifting indices
            offlineManager.delete(videoId: song.videoId)
            // ^ Remove its cached file and metadata
        }
    }

    // MARK: - Playback Helpers

    /// Play a downloaded song from the local cache.
    /// - Parameter song: The downloaded song to play
    private func playSong(_ song: DownloadedSong) {
        // ^ Private method called when the user taps a downloaded song
        guard let localURL = offlineManager.localURL(for: song.videoId) else {
            // ^ Ask OfflineManager for the file path of the cached video.
            // `guard let` unwraps the optional URL, or exits the function
            // early via the `else` block if it's `nil` (file missing).
            return
        }

        // playLocal is async, wrap the call in a Task.
        Task {
            // `Task { ... }` starts a new unit of asynchronous work; `await`
            // pauses just this task (not the whole app) until playLocal finishes.
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
                duration: 0
                // ^ Duration unknown for cached songs; AudioPlayer will detect it
            )
        }
    }
}

// MARK: - Playlist Row

/// A single row in the playlists list.
///
/// Shows: playlist name, song count, and total duration.
struct PlaylistRow: View {
    // ^ A small reusable view used inside ForEach in PlaylistsView

    let playlist: Playlist
    // ^ The playlist model to display (name, song count, duration, etc.)

    var body: some View {
        // ^ The row's visual layout
        HStack(spacing: 12) {
            // ^ Horizontal stack with 12 points between elements
            icon
            info
            Spacer()
            // ^ Pushes everything to the left; keeps the row full-width
        }
    }

    /// The stacked-squares playlist icon on the left of the row.
    private var icon: some View {
        Image(systemName: "square.stack.fill")
            // ^ SF Symbol: stacked squares (represents a playlist)
            .font(.title2)
            // ^ Medium-large icon size
            .foregroundColor(.blue)
            // ^ Blue tint for the icon
            .frame(width: 48, height: 48)
            // ^ Fixed 48×48 point bounding box
            .background(Color.blue.opacity(0.1))
            // ^ Light blue background circle/square
            .cornerRadius(8)
            // ^ Rounded corners (8 point radius)
    }

    /// Playlist name + song count/duration summary text.
    private var info: some View {
        VStack(alignment: .leading, spacing: 4) {
            // ^ Vertical stack, left-aligned, tight spacing
            Text(playlist.name)
                // ^ The playlist's display name
                .font(.body)
                // ^ Standard body text size
                .fontWeight(.medium)
                // ^ Slightly bold for emphasis
                .lineLimit(1)
                // ^ Truncate to a single line if the name is long

            // Song count and total duration
            Text("\(playlist.songCount) songs • \(playlist.totalDuration)")
                // ^ E.g. "12 songs • 45 min"
                .font(.subheadline)
                // ^ Smaller secondary text
                .foregroundColor(.secondary)
                // ^ Grey colour to de-emphasise it
        }
    }
}

#Preview {
    // ^ Xcode preview canvas, renders this view without building the full app
    PlaylistsView()
        .environmentObject(PlaylistManager())
        // ^ Inject a fresh PlaylistManager for preview
        .environmentObject(AudioPlayer())
        // ^ Inject a fresh AudioPlayer for preview
        .environmentObject(OfflineManager())
        // ^ Inject a fresh OfflineManager for preview
}
