import SwiftUI // Imports the SwiftUI framework for building the user interface with native iOS components

/// A modal view that allows the user to set a sleep timer for music playback.
///
/// This view presents a list of preset durations (15, 30, 45, 60 minutes) and an
/// "End of current track" option. When a preset is selected, the timer is activated
/// on the audio player and the modal is dismissed. If a timer is already active,
/// the view shows the remaining time and a cancel button.
///
/// NOTE ON STYLE: The `body` property below is kept intentionally small. Instead of
/// writing one giant block of nested views, each section of the screen is broken out
/// into its own small "computed property" (a property whose value is calculated by
/// running code, rather than stored directly, declared with `var name: Type { ... }`).
/// This mirrors how you'd break a long function into smaller helper functions: it makes
/// each piece easier to read, name, and reason about on its own.
struct SleepTimerView: View { // Declares a SwiftUI View struct. "View" is a protocol (a contract listing capabilities a type must provide); conforming to it means this struct can describe part of the on-screen UI.

    /// The audio player instance from the environment, which provides sleep timer controls.
    ///
    /// `@EnvironmentObject` is a "property wrapper", special syntax (the `@` prefix) that
    /// attaches extra behavior to a property. This one says: "don't create this value here;
    /// instead, fetch it from the shared environment that an ancestor view injected with
    /// `.environmentObject(...)`." Because `AudioPlayer` is a class that publishes changes
    /// (via `@Published` properties inside it), SwiftUI automatically re-runs `body` whenever
    /// something on the player changes, keeping the screen in sync with playback state.
    @EnvironmentObject var audioPlayer: AudioPlayer

    /// The dismiss action provided by the SwiftUI environment to close this modal sheet.
    ///
    /// `@Environment(\.dismiss)` reads a built-in environment value. `dismiss` is a closure
    /// (a self-contained chunk of code you can call like a function) that, when invoked,
    /// tells whatever presented this view (usually `.sheet`) to close it.
    @Environment(\.dismiss) var dismiss

    /// The array of preset minute values displayed as options in the list.
    /// This is a plain constant (`let`), not `@State`, because its contents never change
    /// after the view is created, it's just a fixed menu of choices.
    let presets = [15, 30, 45, 60]

    /// Whether the "Custom Duration" naming alert is showing.
    /// Added so users aren't limited to the four fixed presets above,
    /// e.g. "37 minutes" for an odd-length nap wasn't representable before.
    @State private var showCustomDurationAlert = false

    /// The text typed into the custom-duration alert's numeric TextField.
    @State private var customMinutesText = ""

    /// The required computed property that defines the layout and content of this view.
    /// Every type that conforms to `View` must provide a `body`. SwiftUI calls this
    /// property (potentially many times) to figure out what to draw on screen, this is
    /// what people mean by "declarative UI": you describe *what* the screen should look
    /// like for the current state, and SwiftUI figures out *how* to update the real
    /// pixels to match.
    var body: some View {
        NavigationView { // Wraps the content in a navigation controller, providing a title bar and toolbar
            List { // Creates a grouped list that displays the timer sections and options
                activeTimerSection // Only actually renders content when a timer is running (see below)
                presetOptionsSection // The list of selectable preset durations
                endOfTrackSection // The "End of current track" option
                endOfQueueSection // The "Stop after this album/playlist finishes" smart option
            }
            .navigationTitle("Sleep Timer") // Sets the title displayed in the navigation bar
            .navigationBarTitleDisplayMode(.inline) // Uses inline (compact) title mode instead of large titles
            .toolbar { // Adds buttons to the navigation bar
                ToolbarItem(placement: .navigationBarTrailing) { // Places this button on the trailing (right) side of the navigation bar
                    Button("Done") { // A simple "Done" button
                        dismiss() // Dismisses the modal without changing the timer
                    }
                }
            }
            // Custom-duration alert, lets the user type any number of
            // minutes instead of being limited to the four fixed presets.
            .alert("Custom Duration", isPresented: $showCustomDurationAlert) {
                TextField("Minutes", text: $customMinutesText)
                    .keyboardType(.numberPad)
                Button("Start") {
                    // `Int(...)` returns nil for empty/non-numeric text, and
                    // the `guard` also rejects 0 or negative values, both
                    // cases just leave the alert's text as-is instead of
                    // starting a nonsensical timer.
                    guard let minutes = Int(customMinutesText), minutes > 0 else { return }
                    audioPlayer.setSleepTimer(minutes: minutes)
                    customMinutesText = ""
                    dismiss()
                }
                Button("Cancel", role: .cancel) {
                    customMinutesText = ""
                }
            } message: {
                Text("Enter a number of minutes")
            }
        }
    }

    // MARK: - Sections
    // "MARK:" comments create a jump-to bookmark in Xcode's minimap/navigator; they're
    // purely organizational and have no effect on how the code runs.

    /// Active timer section, shown only when a sleep timer is already running.
    ///
    /// This is a `some View` computed property, just like `body`. Extracting it out of
    /// `body` means `body` itself stays short and reads almost like a table of contents.
    /// `@ViewBuilder` semantics apply automatically here (SwiftUI infers it for `some View`
    /// computed properties that return view content), which is what lets us write an
    /// `if` statement directly inside the returned view hierarchy below.
    @ViewBuilder
    private var activeTimerSection: some View {
        // Conditional block: only produce a `Section` when the player reports an active
        // timer. `if` inside a `@ViewBuilder` context works like a conditional "either
        // show this view or show nothing," rather than an ordinary control-flow branch.
        if audioPlayer.isSleepTimerActive { // Reads the player's boolean property to decide visibility
            Section { // A grouped section in the list with its own visual divider
                HStack { // Horizontally arranges the moon icon, timer info, and cancel button
                    Image(systemName: "moon.fill") // SF Symbol for a filled moon, representing the sleep timer
                        .foregroundColor(.purple) // Colors the moon icon in the app's accent purple

                    VStack(alignment: .leading) { // Stacks the "Timer Active" label and remaining time vertically
                        Text("Timer Active") // A label indicating that the sleep timer is currently running
                            .font(.headline) // Uses the system headline font for emphasis

                        // Format remaining time as MM:SS (or H:MM:SS if more than an hour)
                        Text(formatRemaining(audioPlayer.sleepTimerRemaining)) // Calls formatRemaining to display a user-friendly countdown
                            .font(.title2) // Uses a title-2 font for the remaining time, making it prominent
                            .fontWeight(.bold) // Bold weight to make the countdown stand out
                            .foregroundColor(.purple) // Purple color to match the app's theme
                    }

                    Spacer() // A flexible, invisible view that expands to fill remaining space, pushing the cancel button to the right edge of the row

                    // Cancel button, stops the active timer and dismisses the modal
                    Button(action: { // `Button` takes an `action` closure (code to run on tap) and a label (what it looks like)
                        audioPlayer.stopSleepTimer() // Calls the player's method to cancel the active sleep timer
                        dismiss() // Calls the environment dismiss function to close this modal view
                    }) {
                        Text("Cancel") // The button's label
                            .foregroundColor(.red) // Red text color to indicate a destructive action
                    }
                }
            }
        }
    }

    /// Preset options section, displays the available timer durations.
    private var presetOptionsSection: some View {
        Section { // A grouped list section for the preset timer options
            // `ForEach` is SwiftUI's way of turning a collection into a list of views,
            // similar to a `for` loop, but declarative: you tell it *what* view each
            // element should produce, and SwiftUI handles inserting/removing/animating rows
            // as the collection changes. `id: \.self` tells ForEach to use each Int value
            // itself as its unique identifier, which works here because Int conforms to
            // `Hashable` and the presets are all distinct.
            ForEach(presets, id: \.self) { minutes in
                presetRow(minutes: minutes)
            }

            // Custom duration, opens the alert defined on `body` above.
            Button(action: {
                showCustomDurationAlert = true
            }) {
                HStack {
                    Text("Custom…")
                        .foregroundColor(.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        } header: { // The header text for this section
            Text("Stop after") // Section header label explaining the purpose of the options below
        } footer: { // The footer text for this section
            Text("Playback will pause when the timer expires") // An explanatory note about what happens when the timer runs out
        }
    }

    /// A single row in the presets list, extracted so `presetOptionsSection` stays simple.
    /// - Parameter minutes: The preset duration, in minutes, this row represents.
    private func presetRow(minutes: Int) -> some View {
        Button(action: { // Each preset is a tappable button
            audioPlayer.setSleepTimer(minutes: minutes) // Activates the sleep timer with the selected minute duration on the player
            dismiss() // Closes the modal after the timer is set
        }) {
            HStack { // Arranges the preset label, spacer, and optional checkmark horizontally
                Text("\(minutes) minutes") // Displays the duration text, e.g. "15 minutes"
                    .foregroundColor(.primary) // Uses the system primary text color for readability

                Spacer() // Pushes the checkmark to the trailing edge of the row

                // Show checkmark if this preset is currently active
                if audioPlayer.isSleepTimerActive && // Only show a checkmark when the timer is actually running
                    Int(audioPlayer.sleepTimerRemaining) / 60 == minutes { // And the remaining minutes match this preset value
                    Image(systemName: "checkmark") // SF Symbol for a checkmark indicating the active selection
                        .foregroundColor(.purple) // Purple color to match the app's theme
                }
            }
        }
    }

    /// End of current track section, sets the timer to match the remaining duration
    /// of the current song.
    private var endOfTrackSection: some View {
        Section { // A grouped list section for the "end of track" option
            Button(action: { // A tappable button
                // Set timer to remaining duration of current song.
                // This will pause when the current song ends.
                //
                // `if let song = ...` is "optional binding": `audioPlayer.currentSong` is an
                // Optional (a value that might be present or might be `nil`, meaning "no
                // value"). This safely unwraps it into a non-optional local constant `song`
                // only if it actually has a value, the code inside the braces never runs
                // when there's no current song, which avoids crashing on a missing value.
                if let song = audioPlayer.currentSong {
                    let remaining = audioPlayer.duration - audioPlayer.currentTime // Calculates how many seconds are left in the current track
                    if remaining > 0 { // Only starts the timer if there's actually time remaining (avoids negative or zero durations)
                        audioPlayer.startSleepTimer(duration: remaining) // Activates the sleep timer with the exact remaining duration
                    }
                }
                // `song` isn't used beyond the `if let` check above, we only needed to know
                // *whether* a song exists to compute remaining time, not its details, so
                // this doesn't create any dead state; it's simply how optional binding reads.
                dismiss() // Closes the modal after the timer is set
            }) {
                Text("End of current track") // The button label explaining this option
            }
        }
    }

    /// "Stop after this album/playlist finishes" section, a smart sleep
    /// timer that isn't tied to a fixed duration. Instead it watches the
    /// current queue and stops playback once the last song in it ends,
    /// however long that actually takes.
    ///
    /// Only shown when there's something queued after the current song,
    /// with nothing left to play through, this option is indistinguishable
    /// from "End of current track" above, so hiding it avoids a
    /// meaningless duplicate row.
    @ViewBuilder
    private var endOfQueueSection: some View {
        if !audioPlayer.upNext.isEmpty {
            Section {
                Button(action: {
                    audioPlayer.startSleepTimerAtEndOfQueue()
                    dismiss()
                }) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text("Stop after this album/playlist finishes")
                                .foregroundColor(.primary)

                            // "+3 more", the current song plus everything
                            // still queued after it.
                            Text("\(audioPlayer.upNext.count + 1) songs remaining")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        // Show a checkmark if this specific mode (as opposed
                        // to a fixed-duration timer) is the one active.
                        if audioPlayer.isSleepTimerActive && audioPlayer.sleepTimerStopsAtQueueEnd {
                            Image(systemName: "checkmark")
                                .foregroundColor(.purple)
                        }
                    }
                }
            } footer: {
                Text("Playback will pause after the last song in the current queue finishes, instead of after a fixed amount of time.")
            }
        }
    }

    /// Converts a `TimeInterval` (measured in seconds) into a human-readable countdown string.
    ///
    /// Examples:
    /// - 1800 seconds → "30:00 remaining"
    /// - 90 seconds → "1:30 remaining"
    /// - 45 seconds → "0:45 remaining"
    /// - 3725 seconds → "1:02:05 remaining" (when hours are present)
    ///
    /// - Parameter seconds: The number of seconds remaining on the timer.
    /// - Returns: A formatted string like "5:30 remaining" or "1:02:05 remaining".
    private func formatRemaining(_ seconds: TimeInterval) -> String { // A helper method that formats time for display
        let totalSeconds = Int(seconds) // Converts the TimeInterval (Double) to an integer for precise math operations
        let hours = totalSeconds / 3600 // Calculates the whole number of hours (3600 seconds per hour)
        let minutes = (totalSeconds % 3600) / 60 // Calculates remaining minutes after extracting hours
        let secs = totalSeconds % 60 // Calculates remaining seconds after extracting full minutes

        if hours > 0 { // If the duration includes one or more hours, include the hour component in the format
            return String(format: "%d:%02d:%02d remaining", hours, minutes, secs) // Formats as "H:MM:SS remaining"
        } else { // If the duration is less than an hour, omit the hour component
            return String(format: "%d:%02d remaining", minutes, secs) // Formats as "MM:SS remaining"
        }
    }
}

#Preview { // SwiftUI macro that generates a live preview in Xcode's canvas or Swift Previews
    SleepTimerView() // Creates an instance of the SleepTimerView with default values
        .environmentObject(AudioPlayer()) // Injects a fresh AudioPlayer into the environment for the preview to use
}
