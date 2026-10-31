import SwiftUI

// MARK: - Main Content View

/// The root view of the app, contains the tab bar and the mini player.
///
/// HOW IT WORKS:
/// - TabView at the bottom provides 4 tabs: Home, Search, Library, Settings
/// - MiniPlayer overlays at the very bottom when a song is playing
/// - Tapping the mini player opens the full-screen PlayerView
/// - ZStack layers the mini player ON TOP of the TabView
struct ContentView: View {
    
    /// The audio player, shared across all views via the environment.
    /// @EnvironmentObject means this was created by the App and injected.
    /// Any view in the hierarchy can access it without explicit passing.
    @EnvironmentObject var audioPlayer: AudioPlayer
    
    /// The API client, also shared across all views.
    @EnvironmentObject var apiClient: APIClient

    /// The offline manager, used here only to surface a "Wi-Fi Only"
    /// alert app-wide when a download is skipped because the device isn't
    /// on Wi-Fi (downloads can be triggered from several different screens,
    /// so this is caught once at the root instead of in every view).
    @EnvironmentObject var offlineManager: OfflineManager

    /// Controls whether the full-screen player is shown.
    /// @State = owned by this view. When it changes, the view re-renders.
    @State private var showFullPlayer = false
    
    /// Controls whether the queue sheet is shown (swipe up on mini player).
    @State private var showQueue = false
    
    var body: some View {
        // ZStack = layers views on top of each other (like Photoshop layers).
        // `.alignment: .bottom` = when child views are different sizes,
        // align them to the bottom edge. This ensures the mini player
        // stays at the bottom of the screen.
        ZStack(alignment: .bottom) {
            
            // ── TAB BAR ────────────────────────────────────────────
            // TabView creates the standard iOS bottom tab bar.
            // Each child with .tabItem becomes a tab.
            TabView {
                // Home tab, shows recommended music
                HomeView()
                    .tabItem {
                        // Label combines an icon + text (standard iOS pattern)
                        Label("Home", systemImage: "house.fill")
                    }
                
                // Search tab, search for songs, artists, albums
                SearchView()
                    .tabItem {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                
                // Explore tab, new releases, moods, genres
                NavigationStack {
                    ExploreView()
                }
                .tabItem {
                    Label("Discover", systemImage: "square.grid.2x2")
                }
                
                // Library tab, playlists and downloads
                PlaylistsView()
                    .tabItem {
                        Label("Library", systemImage: "square.stack.fill")
                    }
                
                // Settings tab, app preferences
                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gearshape.fill")
                    }
            }
            // The mini player lives in the TabView's bottom safe-area
            // inset so it docks directly ABOVE the tab bar instead of
            // floating over it (as a ZStack sibling it covered the bar).
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if audioPlayer.currentSong != nil {
                    MiniPlayer()
                        // .transition defines how this view appears/disappears.
                        // .move(edge: .bottom) = slides up from the bottom when appearing,
                        // slides down when disappearing.
                        .transition(.move(edge: .bottom))
                        // Tap gesture on the mini player opens the full-screen player
                        .onTapGesture {
                            showFullPlayer = true
                        }
                        // Swipe up on mini player to show queue
                        .gesture(
                            DragGesture(minimumDistance: 20)
                                .onEnded { value in
                                    // If the user swiped UP (negative vertical translation),
                                    // show the queue sheet
                                    if value.translation.height < -40 {
                                        showQueue = true
                                    }
                                }
                        )
                }
            }
            // NOTE: iPad/Mac keyboard shortcuts for playback control are
            // implemented below via hidden Buttons + .keyboardShortcut
            // (search "Space = Play/Pause"). That's the one working
            // mechanism, .keyboardShortcut has no effect when applied
            // directly to a container view like TabView (it only works on
            // Button/MenuItem-like views), and a previous .onKeyPress(.space)
            // handler here returned .handled without ever calling
            // togglePlayPause(), which meant it silently swallowed the
            // space key instead of pausing/playing. Both were removed.

            // The mini player moved into the TabView's bottom
            // safe-area inset (see above) so it no longer covers
            // the tab bar.
        }
        // .fullScreenCover = presents a view that covers the ENTIRE screen
        // (including the status bar). Unlike .sheet, it can't be swiped down
        // to dismiss, the user must tap a button.
        // We pass $showFullPlayer as a binding so PlayerView can dismiss itself.
        .fullScreenCover(isPresented: $showFullPlayer) {
            PlayerView(isShowing: $showFullPlayer)
        }
        // Queue sheet, slides up when user swipes up on mini player
        .sheet(isPresented: $showQueue) {
            QueueView()
        }
        // Apply the user's font size preference from Settings.
        // Reads @AppStorage("fontSizeScale") and adjusts DynamicTypeSize.
        .withFontScale()
        // iPad/Mac keyboard shortcuts for playback control.
        // `.background { ... }` tucks a view behind everything else in the
        // ZStack, here we (ab)use it purely to smuggle the invisible
        // shortcut buttons into the view hierarchy so they can receive key
        // presses, not to draw anything visible.
        .background {
            keyboardShortcutButtons
        }
        // "Wi-Fi Only" alert, shown whenever OfflineManager skips a
        // download because Wi-Fi Only is enabled and we're on cellular.
        // Bound at the root so it works no matter which screen (search
        // results, a playlist, song detail, the player) started the
        // download.
        .alert(
            "Wi-Fi Required",
            isPresented: Binding(
                get: { offlineManager.wifiOnlyBlockedMessage != nil },
                set: { isPresented in
                    if !isPresented { offlineManager.wifiOnlyBlockedMessage = nil }
                }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(offlineManager.wifiOnlyBlockedMessage ?? "")
        }
    }

    // MARK: - Keyboard Shortcuts (iPad / Mac)

    /// Hidden buttons that let a hardware keyboard control playback.
    ///
    /// WHY HIDDEN BUTTONS INSTEAD OF SOMETHING SIMPLER:
    /// SwiftUI's `.keyboardShortcut(_:modifiers:)` view modifier only takes
    /// effect on a `Button` (or similar tappable/menu-item view), it does
    /// NOT work when applied directly to a container like `TabView`. So to
    /// make Space/←/→ control playback anywhere in the app, we create three
    /// invisible buttons, give each one a keyboard shortcut, and hide them
    /// with `.hidden()`. `.hidden()` keeps a view "in" the hierarchy (so it
    /// can still receive events like key presses) while making it invisible
    /// and non-interactive to touch/taps, unlike simply not including the
    /// view at all.
    ///
    /// A return type of `some View` (used throughout this file) means "this
    /// computed property returns some concrete type that conforms to the
    /// `View` protocol, but callers don't need to know exactly which type it
    /// is", SwiftUI calls this an "opaque return type", and it's what lets
    /// us break a big `body` into smaller, named pieces like this one.
    private var keyboardShortcutButtons: some View {
        // `Group` bundles multiple views together without adding any layout
        // of its own (no extra stacking or spacing), we need it here
        // because a computed property can only return ONE view, and we have
        // three buttons to return together.
        Group {
            // Space = Play/Pause.
            // The trailing closure `{ audioPlayer.togglePlayPause() }` is
            // the button's action: the block of code that runs when the
            // button is triggered, here, via the keyboard shortcut below
            // rather than a finger tap.
            Button("") {
                audioPlayer.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            .hidden()

            // Right arrow = Next track
            Button("") {
                audioPlayer.playNext()
            }
            .keyboardShortcut(.rightArrow, modifiers: [])
            .hidden()

            // Left arrow = Previous track
            Button("") {
                audioPlayer.playPrevious()
            }
            .keyboardShortcut(.leftArrow, modifiers: [])
            .hidden()
        }
    }
}

// MARK: - Mini Player

/// The small player bar that shows at the bottom when music is playing.
///
/// Shows: progress bar, thumbnail, song title, artist, and play/pause button.
/// Tapping it opens the full PlayerView (handled by the parent ContentView).
/// Swipe left to skip to next song, swipe right to go to previous song.
struct MiniPlayer: View {
    
    @EnvironmentObject var audioPlayer: AudioPlayer
    
    /// Tracks the horizontal drag offset for swipe gestures.
    /// When the user drags, this value changes and we use it to
    /// show a visual hint (the song slides slightly with the finger).
    @State private var dragOffset: CGFloat = 0
    
    /// Threshold for triggering a skip (in points).
    /// If the user swipes more than 80 points horizontally, we skip.
    private let swipeThreshold: CGFloat = 80
    
    var body: some View {
        // `if let song = ...` is "optional binding": `audioPlayer.currentSong`
        // is an OPTIONAL (`NowPlaying?`), meaning it might hold a value or
        // might be `nil` (nothing). This line only runs the code inside the
        // braces when there IS a value, and it unwraps that value into a new,
        // non-optional local constant called `song`. If `currentSong` is nil
        // (nothing playing), the `if` is false and the whole body renders as
        // nothing, this is how the mini player disappears when playback stops.
        if let song = audioPlayer.currentSong {
            VStack(spacing: 0) {
                progressBar
                songInfoRow(for: song)
            }
            // Apply the drag gesture for swiping between songs
            .offset(x: dragOffset) // Visual feedback, slides with the finger
            .gesture(swipeGesture)
            // White/light background for the mini player bar
            .background(Color(.systemBackground))
            // Subtle shadow below the mini player for depth
            .shadow(color: .black.opacity(0.1), radius: 5, x: 0, y: -2)
        }
    }

    // MARK: - Progress Bar

    /// Thin bar across the top of the mini player showing playback progress.
    private var progressBar: some View {
        // `GeometryReader` is a container view that, instead of drawing
        // anything itself, measures the space SwiftUI has given it and
        // hands that size to its closure as `geometry`. We need this here
        // because the filled portion of the bar must be a FRACTION of
        // whatever width is available (e.g. iPhone vs iPad), not a fixed
        // number of points, something a plain `Rectangle` can't do alone.
        GeometryReader { geometry in
            Rectangle()
                .fill(Color.blue)
                // audioPlayer.progress is a Double from 0.0 (just started)
                // to 1.0 (finished). Multiplying it by the full width gives
                // us the width of just the "filled" portion of the bar.
                .frame(width: geometry.size.width * audioPlayer.progress, height: 3)
        }
        .frame(height: 3)
    }

    // MARK: - Song Info Row

    /// Thumbnail, title/artist, and the play/pause button for the currently
    /// playing song.
    ///
    /// `song` is `NowPlaying`, the model type that describes whatever track
    /// is currently loaded into the player (title, artist, artwork URL, etc).
    private func songInfoRow(for song: NowPlaying) -> some View {
        HStack {
            // Album art thumbnail (48x48 points).
            // `AsyncImage` downloads and displays an image from a URL. This
            // is the two-closure form: the first closure receives the loaded
            // `Image` once the download succeeds, and `placeholder` supplies
            // a stand-in view to show while loading (or if the URL is bad).
            // `URL(string: song.thumbnailUrl)` is itself an optional,
            // `AsyncImage` handles a nil URL gracefully by just showing the
            // placeholder, so no force-unwrap is needed here.
            AsyncImage(url: URL(string: song.thumbnailUrl)) { image in
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
            }
            .frame(width: 48, height: 48)
            .cornerRadius(8)

            // Song title and artist, stacked vertically
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(song.artist)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer() // Pushes play button to the right

            // Play/pause button
            Button(action: {
                Haptics.tap()
                audioPlayer.togglePlayPause()
            }) {
                Image(systemName: audioPlayer.state == .playing ? "pause.fill" : "play.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Swipe Gesture

    /// Horizontal swipe-to-skip gesture: swipe left for next track, right
    /// for previous track.
    ///
    /// The property type `some Gesture` works the same way `some View` does
    /// elsewhere in this file, it says "this returns some concrete type
    /// conforming to the `Gesture` protocol" without spelling out SwiftUI's
    /// full (and rather ugly) generic gesture type.
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20) // 20pt minimum to avoid accidental swipes
            // `.onChanged` fires repeatedly WHILE the finger is moving.
            // `value` describes the drag so far; `value.translation.width`
            // is how far (in points) the finger has moved horizontally from
            // where the drag started. We ignore vertical movement entirely.
            .onChanged { value in
                dragOffset = value.translation.width
            }
            // `.onEnded` fires once, when the finger lifts off the screen.
            .onEnded { value in
                // Check if the swipe was far enough to trigger a skip
                if value.translation.width < -swipeThreshold {
                    // Swiped LEFT → next song
                    audioPlayer.playNext()
                } else if value.translation.width > swipeThreshold {
                    // Swiped RIGHT → previous song
                    audioPlayer.playPrevious()
                }
                // Reset the drag offset (snap back to center).
                // `withAnimation` wraps a state change so SwiftUI animates
                // the resulting UI update instead of jumping instantly,
                // here, the mini player slides back to its resting position.
                withAnimation(.easeOut(duration: 0.2)) {
                    dragOffset = 0
                }
            }
    }
}

// MARK: - Library Placeholder

/// Placeholder view for the Library tab.
///
/// Currently shows a "coming soon" message. Will be replaced with
/// playlists, saved songs, and albums when login is implemented.
///
/// NOTE FOR READERS: the Library tab in the `TabView` above actually uses
/// `PlaylistsView()`, not this struct, `LibraryView` isn't referenced
/// anywhere else in the app right now. It's kept here as a simple, working
/// example of the "coming soon" pattern rather than deleted, but if you're
/// looking for the real Library tab's code, see `PlaylistsView`.
struct LibraryView: View {
    var body: some View {
        // `NavigationView` is the older API for wrapping content in a
        // navigation bar (with a title, back buttons, etc). Newer code in
        // this app (see the TabView above) uses `NavigationStack` instead,
        // which has more predictable behavior, `NavigationView` still
        // works but is considered legacy.
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: "square.stack.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.secondary)

                Text("Library")
                    .font(.title)

                Text("Playlists, albums, and saved songs will appear here")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center) // Center multi-line text
            }
            .navigationTitle("Library")
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environmentObject(AudioPlayer())
        .environmentObject(APIClient())
}
