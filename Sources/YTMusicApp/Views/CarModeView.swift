// CarModeView.swift, A simplified, full-screen player interface optimized for use while driving.

import SwiftUI // SwiftUI provides the declarative UI building blocks (View, VStack, Button, etc.) used throughout this file

/// A simplified player view with large buttons for safe driving.
///
/// HOW IT WORKS:
/// - Full-screen dark interface with minimal distractions
/// - Giant buttons that are easy to tap without looking
/// - Only essential controls: previous, play/pause, next
/// - Shows song title and artist (no album art to reduce distraction)
/// - Swipe down or tap X to exit car mode
///
/// WHY THIS EXISTS:
/// Using a phone while driving is dangerous. Car mode makes the controls
/// large enough to use with a quick glance, reducing distraction.
/// This is similar to what Apple Music and Spotify offer.
///
/// NOTE ON STYLE: `body` only lays out the overall structure and delegates each visual
/// chunk (header, song info, progress bar, transport controls, shuffle/repeat row) to its
/// own small computed property below. This is the same idea as splitting a long function
/// into smaller, well-named helper functions, each section can be read and understood on
/// its own.
struct CarModeView: View {

    /// The audio player, provides playback controls and song info.
    /// `@EnvironmentObject` is a property wrapper (the `@` marks it as adding special
    /// behavior) that reads a shared `AudioPlayer` instance from the SwiftUI environment
    /// rather than creating a new one. Because `AudioPlayer` publishes its changes, SwiftUI
    /// automatically redraws this view whenever playback state (song, progress, etc.) changes.
    @EnvironmentObject var audioPlayer: AudioPlayer

    /// Dismiss this view when the user taps the close button.
    /// `@Environment(\.dismiss)` reads a built-in environment value: a closure that closes
    /// whatever presented this view.
    @Environment(\.dismiss) var dismiss

    /// The main view content, the required `body` computed property every `View` must
    /// implement. SwiftUI calls it to determine what to draw on screen.
    var body: some View {
        // Full-screen black background for maximum contrast
        ZStack { // Stacks views on top of each other (unlike VStack/HStack, which lay them out side-by-side); later children draw above earlier ones
            // Set the entire background to black
            Color.black
                .ignoresSafeArea() // Extend black beyond safe areas (notch, home indicator)

            // Vertical stack holds all UI elements in a column
            VStack(spacing: 40) {
                headerView
                Spacer() // An invisible, flexible view that expands to fill space, pushing everything toward the vertical center
                songInfoView
                Spacer()
                progressBarView
                playbackControlsView
                Spacer()
                shuffleRepeatView
            }
        }
        // Hide the status bar for a cleaner, more immersive look
        .statusBarHidden(true)
    }

    // MARK: - Sections
    // "MARK:" comments are bookmarks for Xcode's navigator/minimap and don't affect behavior.

    /// Top row: close button, title, empty spacer (for symmetry).
    private var headerView: some View {
        HStack {
            // Exit car mode button
            Button(action: {
                dismiss() // Call the system dismiss to go back
            }) {
                // X mark icon
                Image(systemName: "xmark")
                    .font(.title) // Large title font size
                    .foregroundColor(.white) // White icon on black
                    .frame(width: 50, height: 50) // Fixed size for easy tapping
            }

            Spacer() // Push content apart

            // "Car Mode" label
            Text("Car Mode")
                .font(.headline) // Bold, medium-sized font
                .foregroundColor(.white.opacity(0.6)) // Slightly transparent white

            Spacer() // Push content apart

            // Placeholder for future settings
            Color.clear // Invisible spacer, same size as the close button
                .frame(width: 50, height: 50) // Keeps layout balanced
        }
        .padding(.horizontal) // Add padding on left and right edges
    }

    /// Large text showing the current song, easy to read at a glance.
    /// Marked `@ViewBuilder` so this property can conditionally return either the song
    /// info or nothing at all (when no song is loaded) without both branches needing to
    /// produce the exact same concrete view type.
    @ViewBuilder
    private var songInfoView: some View {
        // `if let song = audioPlayer.currentSong` is "optional binding": `currentSong` is
        // an Optional (it might hold a song, or might be `nil` meaning "nothing playing").
        // This safely unwraps it into `song` and only runs the block when a song exists,
        // which avoids ever trying to read `.title`/`.artist` off of "nothing."
        if let song = audioPlayer.currentSong {
            VStack(spacing: 12) {
                // Song title, large and bold
                Text(song.title)
                    .font(.title) // Large font
                    .fontWeight(.bold) // Bold weight
                    .foregroundColor(.white) // White text
                    .lineLimit(2) // Wrap at most 2 lines
                    .multilineTextAlignment(.center) // Center-align text

                // Artist name, slightly smaller, less prominent
                Text(song.artist)
                    .font(.title3) // Medium-large font
                    .foregroundColor(.white.opacity(0.7)) // Slightly transparent
                    .lineLimit(1) // Single line only (truncate with ...)
            }
            .padding(.horizontal, 32) // Side padding so text doesn't touch edges
        }
    }

    /// Simple progress indicator (no time labels next to the bar itself, time is shown
    /// below it, keeps the bar minimal).
    private var progressBarView: some View {
        VStack(spacing: 8) {
            // `GeometryReader` is a view that doesn't draw anything itself; instead it
            // reports the size/position available to it (via the `geometry` parameter) so
            // its children can size themselves relative to their container. Here it's used
            // to compute the filled portion of the progress bar as a fraction of the total
            // available width.
            GeometryReader { geometry in
                ZStack(alignment: .leading) { // Align fill bar to the left
                    // Background track (gray)
                    RoundedRectangle(cornerRadius: 4) // Rounded rectangle shape
                        .fill(Color.white.opacity(0.2)) // Faded white fill
                        .frame(height: 8) // 8 points tall

                    // Filled portion (white).
                    // `audioPlayer.progress` is expected to be a fraction from 0.0 (start)
                    // to 1.0 (end); multiplying it by the total width gives the pixel width
                    // of the "played so far" portion.
                    RoundedRectangle(cornerRadius: 4) // Rounded rectangle shape
                        .fill(Color.white) // Solid white fill
                        .frame(
                            // Width = total width × progress (0.0 to 1.0)
                            width: geometry.size.width * audioPlayer.progress,
                            height: 8 // Match background height
                        )
                }
            }
            .frame(height: 8) // Constrain GeometryReader to match bar height

            // Time labels, larger font for readability
            HStack {
                // Current playback time (elapsed)
                Text(formatTime(audioPlayer.currentTime))
                    .font(.body) // Standard body font
                    .foregroundColor(.white.opacity(0.6)) // Semi-transparent white

                Spacer() // Push times to opposite sides

                // Total song duration
                Text(formatTime(audioPlayer.duration))
                    .font(.body) // Standard body font
                    .foregroundColor(.white.opacity(0.6)) // Semi-transparent white
            }
        }
        .padding(.horizontal, 40) // Side padding for progress bar
    }

    /// Giant transport buttons, 80pt minimum tap target for safe driving.
    private var playbackControlsView: some View {
        HStack(spacing: 60) {
            // Previous button (large)
            Button(action: {
                audioPlayer.playPrevious() // Skip to previous track
            }) {
                Image(systemName: "backward.fill") // Skip back icon
                    .font(.system(size: 50)) // Very large icon
                    .foregroundColor(.white) // White icon
            }
            .frame(width: 80, height: 80) // Large tap target

            // Play/pause button (extra large, the most important button)
            Button(action: {
                audioPlayer.togglePlayPause() // Play if paused, pause if playing
            }) {
                // Dynamic icon: show pause when playing, play when not.
                // The `? :` operator is Swift's "ternary conditional": it reads as
                // "if `audioPlayer.state == .playing` is true, use the first value,
                // otherwise use the second", a compact one-line if/else for picking a value.
                Image(systemName: audioPlayer.state == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 70)) // Extra-large icon
                    .foregroundColor(.white) // White icon
            }
            .frame(width: 100, height: 100) // Largest tap target in the UI

            // Next button (large)
            Button(action: {
                audioPlayer.playNext() // Skip to next track
            }) {
                Image(systemName: "forward.fill") // Skip forward icon
                    .font(.system(size: 50)) // Very large icon
                    .foregroundColor(.white) // White icon
            }
            .frame(width: 80, height: 80) // Large tap target
        }
    }

    /// Shuffle + repeat toggles, smaller and less prominent than the transport controls,
    /// since they're used less often while driving.
    private var shuffleRepeatView: some View {
        HStack(spacing: 60) {
            // Shuffle toggle button
            Button(action: {
                audioPlayer.toggleShuffle() // Toggle shuffle mode on/off
            }) {
                Image(systemName: "shuffle") // Shuffle icon
                    .font(.title2) // Medium size, less prominent than transport
                    // Bright when on, faded when off
                    .foregroundColor(audioPlayer.isShuffled ? .white : .white.opacity(0.4))
            }

            // Repeat mode toggle button
            Button(action: {
                audioPlayer.toggleRepeat() // Cycle repeat modes: off → all → one
            }) {
                // Show "repeat.1" when repeating a single track
                Image(systemName: audioPlayer.repeatMode == .one ? "repeat.1" : "repeat")
                    .font(.title2) // Medium size
                    // Bright when active, faded when off
                    .foregroundColor(audioPlayer.repeatMode != .none ? .white : .white.opacity(0.4))
            }
        }
        .padding(.bottom, 40) // Space between controls and bottom edge
    }

    // MARK: - Helpers

    /// Format seconds into MM:SS string.
    /// Same logic as PlayerView's formatTime, could be extracted to a shared utility.
    private func formatTime(_ seconds: Double) -> String {
        // `guard` checks a condition up front and exits early (via `return`) if it fails,
        // rather than nesting the "happy path" inside an `if`. This protects against
        // `Double.nan` ("not a number") or `.infinity`, which can happen transiently while
        // the player is loading a new track and duration/time haven't been reported yet,
        // formatting those with `%d` would otherwise produce garbage or crash.
        guard !seconds.isNaN && !seconds.isInfinite else {
            return "0:00" // Safe fallback for invalid time values
        }
        let mins = Int(seconds) / 60 // Calculate whole minutes
        let secs = Int(seconds) % 60 // Calculate remaining seconds
        return String(format: "%d:%02d", mins, secs) // Format as "M:SS" with leading zero on seconds
    }
}

#Preview {
    CarModeView()
        .environmentObject(AudioPlayer()) // Provide a mock AudioPlayer for preview rendering
}
