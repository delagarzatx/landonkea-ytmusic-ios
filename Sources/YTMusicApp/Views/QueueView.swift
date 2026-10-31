import SwiftUI // SwiftUI provides the declarative UI building blocks (View, List, Section, etc.) used throughout this file

/// Winamp playlist palette (ronda 6): near-black green-tinted rows,
/// LED-green accents, monospace text.
private let queueRowBg = Color(red: 0.03, green: 0.06, blue: 0.03)
private let queueGreen = Color(red: 0.16, green: 0.96, blue: 0.26)

/// The queue screen showing what's currently playing and what comes next.
///
/// HOW IT WORKS:
/// - Shows the currently playing song at the top
/// - Shows "Up Next" songs below it
/// - Users can remove songs (swipe or tap X) and reorder (drag)
///
/// IMPORTANT: The "Up Next" list is a SLICE of the full queue.
/// The full queue looks like: [past songs..., CURRENT, up next...]
/// `upNext` only returns songs AFTER currentIndex, so we do
/// index math to map from "up next index" back to "full queue index".
///
/// NOTE ON STYLE: `body` only lays out the top-level `List` structure and delegates each
/// section (now playing, up next, empty state) and each row to its own small computed
/// property or helper method below. This mirrors breaking a long function into smaller,
/// well-named helper functions, each piece can be read on its own.
struct QueueView: View {

    /// Grab the audio player from the environment so we can read/modify the queue.
    /// "EnvironmentObject" means this view automatically stays updated
    /// whenever the audio player's published properties change.
    @EnvironmentObject var audioPlayer: AudioPlayer

    /// The playlist manager, used by "Save Queue as Playlist" below.
    @EnvironmentObject var playlistManager: PlaylistManager

    /// `dismiss` is a SwiftUI environment value that lets us close this screen.
    /// We call `dismiss()` when the user taps "Done".
    @Environment(\.dismiss) var dismiss

    /// Whether the "Save Queue as Playlist" naming alert is showing.
    @State private var showSaveAsPlaylistAlert = false

    /// The name typed into that alert's TextField.
    @State private var newPlaylistName = ""

    var body: some View {
        // NavigationView wraps the screen with a nav bar (title + toolbar buttons)
        NavigationView {
            // List = scrollable table view (like UITableView in UIKit)
            List {
                historySection
                nowPlayingSection
                upNextOrEmptySection
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .preferredColorScheme(.dark)
            .navigationTitle("Queue")
            // .inline = smaller title that doesn't become large on scroll
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // "Done" button on the left side of the nav bar
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        dismiss() // Closes this modal screen
                    }
                }

                // "Clear" and "Save as Playlist" on the right, only shown
                // when there's actually a queue worth acting on.
                ToolbarItem(placement: .navigationBarTrailing) {
                    if !audioPlayer.queue.isEmpty {
                        HStack {
                            // "Save Queue as Playlist", lets the user turn
                            // whatever they've queued up into a reusable
                            // playlist without retyping every song.
                            Button {
                                showSaveAsPlaylistAlert = true
                            } label: {
                                Image(systemName: "plus.square.on.square")
                            }

                            if audioPlayer.queue.count > 1 {
                                Button("Clear") {
                                    audioPlayer.clearQueue() // Keeps current song, removes everything else
                                }
                                .foregroundColor(.red) // Red = destructive action
                            }
                        }
                    }
                }
            }
            .alert("Save Queue as Playlist", isPresented: $showSaveAsPlaylistAlert) {
                TextField("Playlist Name", text: $newPlaylistName)
                Button("Save") {
                    let trimmed = newPlaylistName.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    // Saves the FULL queue (current song + up next), in
                    // order, as a new playlist, see PlaylistManager's
                    // createPlaylist(name:songs:) for why this is a single
                    // batched call rather than one addSong per song.
                    playlistManager.createPlaylist(name: trimmed, songs: audioPlayer.queue)
                    newPlaylistName = ""
                }
                Button("Cancel", role: .cancel) {
                    newPlaylistName = ""
                }
            } message: {
                Text("Save the \(audioPlayer.queue.count) song\(audioPlayer.queue.count == 1 ? "" : "s") in your queue as a new playlist.")
            }
        }
    }

    // MARK: - Sections
    // "MARK:" comments are bookmarks for Xcode's navigator/minimap and don't affect behavior.

    /// SECTION 0: HISTORY, songs already played earlier in this queue.
    /// Tapping one jumps straight back to it (via `AudioPlayer.playFromHistory`)
    /// without disturbing the rest of the queue; everything after it just
    /// becomes "up next" again, same as stepping back one at a time would.
    ///
    /// Shown ABOVE "Now Playing" so the section order reads top-to-bottom as
    /// a timeline: past → present → future.
    @ViewBuilder
    private var historySection: some View {
        if !audioPlayer.history.isEmpty {
            Section {
                // `audioPlayer.history` is already reversed (most recently
                // played first). Its element at local index `i` sits at full
                // queue index `currentIndex - 1 - i`, see the index math
                // note on `upNextOrEmptySection` for the general pattern;
                // this is the mirror-image version since history counts
                // backward from currentIndex instead of forward.
                ForEach(Array(audioPlayer.history.enumerated()), id: \.element.id) { index, song in
                    historyRow(song: song)
                        .listRowBackground(queueRowBg)
                        .contentShape(Rectangle()) // Makes the whole row tappable, not just the text/image
                        .onTapGesture {
                            playHistoryItem(atLocalIndex: index)
                        }
                }
            } header: {
                Text("History")
            }
        }
    }

    /// A single row in the History list: artwork, title, artist, and a
    /// "replay" icon hinting that tapping jumps back to this song.
    private func historyRow(song: NowPlaying) -> some View {
        HStack(spacing: 12) {
            queueThumbnail(url: song.thumbnailUrl, size: 48, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 4) {
                Text(song.title)
                    .font(.subheadline)
                    .lineLimit(1)

                Text(song.artist)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .foregroundColor(.secondary) // Dim past songs slightly vs. up-next rows

            Spacer()

            Image(systemName: "arrow.counterclockwise.circle")
                .foregroundColor(.secondary)
        }
    }

    /// SECTION 1: NOW PLAYING.
    /// `@ViewBuilder` lets this computed property conditionally return either the section
    /// or nothing at all (when nothing is playing), without both branches needing to
    /// produce the exact same concrete view type.
    @ViewBuilder
    private var nowPlayingSection: some View {
        // `if let` safely unwraps the optional. `currentSong` is an Optional, it might
        // hold a song, or might be `nil` ("no value"). If nothing is playing, currentSong
        // is nil and this entire section is skipped, which avoids ever trying to read
        // `.title`/`.artist` off of "nothing."
        if let currentSong = audioPlayer.currentSong {
            Section {
                nowPlayingRow(song: currentSong)
                    .listRowBackground(queueRowBg)
            } header: {
                Text("Now Playing")
            }
        }
    }

    /// A single row showing the currently playing song's artwork, title, artist, and a
    /// speaker icon indicating it's the active track.
    private func nowPlayingRow(song currentSong: NowPlaying) -> some View {
        // HStack = horizontal stack (row of items side by side)
        HStack(spacing: 12) {
            queueThumbnail(url: currentSong.thumbnailUrl, size: 56, cornerRadius: 8)

            // Song title and artist, stacked vertically
            VStack(alignment: .leading, spacing: 4) {
                Text(currentSong.title)
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(queueGreen)
                    .lineLimit(1) // Truncate with "..." if too long

                Text(currentSong.artist)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(.secondary) // Gray color
                    .lineLimit(1)
            }

            Spacer() // Invisible, flexible view that expands to fill space, pushing everything to the left

            // Speaker icon shows this song is currently playing
            Image(systemName: "speaker.wave.2.fill")
                .foregroundColor(queueGreen)
        }
    }

    /// SECTION 2: UP NEXT (or the empty-state placeholder when there's nothing queued).
    /// `upNext` is a computed property that returns queue[currentIndex+1...].
    /// If there are no songs after the current one, we show an empty-state message instead.
    @ViewBuilder
    private var upNextOrEmptySection: some View {
        if !audioPlayer.upNext.isEmpty {
            Section {
                // ── THE INDEX MATH EXPLANATION ────────────────
                // `upNext` contains songs at positions [currentIndex+1, currentIndex+2, ...]
                // in the full queue. But `enumerated()` gives us indices starting at 0.
                //
                // So if currentIndex=5, upNext[0] = queue[6], upNext[1] = queue[7], etc.
                //
                // To get the REAL index in the full queue from the "up next" index:
                //   globalIndex = currentIndex + upNextIndex + 1
                //
                // Example: currentIndex=5, upNextIndex=0 → globalIndex=6
                //          currentIndex=5, upNextIndex=2 → globalIndex=8
                //
                // We need the global index because removeFromQueue() and moveQueue()
                // work on the FULL queue array, not the upNext slice.

                // `Array(audioPlayer.upNext.enumerated())` pairs each song with its
                // position (0, 1, 2, ...) in the upNext slice. `ForEach` then builds one
                // row per pair. `id: \.element.id` tells ForEach how to uniquely identify
                // each row (needed so SwiftUI can animate insertions/removals/reorders
                // correctly) by using the song's own `id`, not its position.
                ForEach(Array(audioPlayer.upNext.enumerated()), id: \.element.id) { index, song in
                    upNextRow(index: index, song: song)
                        .listRowBackground(queueRowBg)
                        // SwipeActions = swipe left to reveal buttons (like iOS mail)
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { // .destructive = red color
                                // Same index math as the X button inside the row
                                removeUpNextItem(atLocalIndex: index)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                }
                // onMove enables drag-to-reorder. When the user drags a row,
                // SwiftUI calls this closure with the source indices and destination index.
                .onMove { source, destination in
                    // `source` is an IndexSet of positions *within the upNext list*
                    // (SwiftUI reports drag positions relative to the rows produced by this
                    // ForEach, which only spans the "up next" slice). `AudioPlayer.moveQueue`
                    // operates on the FULL queue array though, so both the source indices
                    // AND the destination index must be converted using the same "+
                    // currentIndex + 1" offset from the explanation above. The destination
                    // conversion was already here; the source conversion was missing, which
                    // meant dragging a row could move the wrong song in the full queue
                    // (e.g. one still playing earlier in the list), fixed by mapping every
                    // index in `source` through the same offset before calling moveQueue.
                    let adjustedSource = IndexSet(source.map { audioPlayer.currentIndex + $0 + 1 })
                    let adjustedDestination = audioPlayer.currentIndex + destination + 1
                    audioPlayer.moveQueue(from: adjustedSource, to: adjustedDestination)
                }
            } header: {
                // Show count in parentheses, e.g. "Up Next (5)"
                Text("Up Next (\(audioPlayer.upNext.count))")
            }
        } else {
            emptyQueueSection
        }
    }

    /// A single row in the "Up Next" list: drag handle, position number, artwork, title,
    /// artist, and a remove (X) button.
    /// - Parameters:
    ///   - index: This song's position within the `upNext` slice (0-based).
    ///   - song: The song to display in this row.
    private func upNextRow(index: Int, song: NowPlaying) -> some View {
        HStack(spacing: 12) {
            // Drag handle icon, indicates this row can be dragged to reorder.
            // The three horizontal lines (hamburger icon) is the standard
            // iOS drag handle pattern used in Reminders, Notes, etc.
            Image(systemName: "line.3.horizontal")
                .font(.caption)
                .foregroundColor(.secondary)

            // Position number (1, 2, 3...), display as index+1 so it starts at 1
            Text("\(index + 1)")
                .font(.system(.subheadline, design: .monospaced))
                .foregroundColor(queueGreen)
                .frame(width: 24)

            queueThumbnail(url: song.thumbnailUrl, size: 48, cornerRadius: 6)

            // Song title and artist
            VStack(alignment: .leading, spacing: 4) {
                Text(song.title)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(Color(white: 0.85))
                    .lineLimit(1)

                Text(song.artist)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // X button to remove this song from the queue
            Button(action: {
                removeUpNextItem(atLocalIndex: index)
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain) // Prevents blue button highlight
        }
    }

    /// Album art thumbnail, shared shape/behavior for both the "now playing" and
    /// "up next" rows (only the size and corner radius differ between the two).
    /// - Parameters:
    ///   - url: The thumbnail image URL string, as returned by the API.
    ///   - size: The width and height, in points, to render the thumbnail at.
    ///   - cornerRadius: How rounded the thumbnail's corners should be.
    private func queueThumbnail(url: String, size: CGFloat, cornerRadius: CGFloat) -> some View {
        // AsyncImage loads an image from a URL asynchronously.
        // While loading, it shows the gray placeholder rectangle.
        // `URL(string:)` returns an Optional<URL> (the string might not be a valid URL);
        // AsyncImage handles a `nil` URL gracefully by showing the placeholder, so this
        // can never crash even if the API returns a malformed thumbnail URL.
        AsyncImage(url: URL(string: url)) { image in
            // When loaded: fill the frame with the image
            image
                .resizable()
                .aspectRatio(contentMode: .fill)
        } placeholder: {
            // While loading: gray box
            Rectangle()
                .fill(Color.gray.opacity(0.3))
        }
        .frame(width: size, height: size)
        .cornerRadius(cornerRadius)
    }

    /// Empty state shown when there's nothing in the queue after the current song.
    private var emptyQueueSection: some View {
        Section {
            VStack(spacing: 12) {
                Image(systemName: "list.bullet")
                    .font(.title2)
                    .foregroundColor(.secondary)

                Text("No songs in queue")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity) // Center horizontally
            .padding()
            .listRowBackground(queueRowBg)
        }
    }

    // MARK: - Helpers

    /// Jumps back to a song in the History list, converting its local
    /// (history-relative, most-recent-first) index into the full queue's
    /// index before calling into the player.
    /// - Parameter localIndex: The song's position within the `history` slice (0-based, index 0 = most recently played).
    private func playHistoryItem(atLocalIndex localIndex: Int) {
        // `history` is `queue[0..<currentIndex]` reversed, so local index 0
        // (most recent) maps to full queue index `currentIndex - 1`, local
        // index 1 maps to `currentIndex - 2`, etc.
        let globalIndex = audioPlayer.currentIndex - 1 - localIndex
        audioPlayer.playFromHistory(at: globalIndex)
    }

    /// Removes a song from the "up next" list, converting its local (upNext-relative)
    /// index into the full queue's index before calling into the player.
    /// - Parameter localIndex: The song's position within the `upNext` slice (0-based).
    private func removeUpNextItem(atLocalIndex localIndex: Int) {
        // Convert "up next index" to "full queue index", see the index math
        // explanation above `upNextOrEmptySection`.
        let globalIndex = audioPlayer.currentIndex + localIndex + 1
        audioPlayer.removeFromQueue(at: globalIndex)
    }
}

#Preview {
    QueueView()
        .environmentObject(AudioPlayer())
        .environmentObject(PlaylistManager())
}
