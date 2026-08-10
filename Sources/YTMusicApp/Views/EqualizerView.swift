// EqualizerView.swift, The equalizer screen where users can adjust audio frequencies and apply presets.

import SwiftUI // SwiftUI provides the declarative UI building blocks (View, VStack, Slider, etc.) used throughout this file

/// The equalizer screen where users adjust audio frequencies and select presets.
///
/// Shows a scrollable list of frequency band sliders and a grid of preset buttons.
/// Each slider controls one frequency band (32Hz to 16KHz).
/// Presets apply pre-configured settings for common listening scenarios.
///
/// NOTE ON STYLE: Rather than one huge `body` with everything nested inside, each visual
/// section (power toggle, active preset label, frequency sliders, preset grid) is pulled
/// out into its own small computed property below `body`. This is analogous to breaking a
/// long function up into smaller, well-named helper functions, each piece is easier to
/// read, and `body` itself reads like a short outline of the screen.
struct EqualizerView: View {

    /// The equalizer manager, handles audio processing and settings.
    /// `@EnvironmentObject` is a property wrapper (special `@`-prefixed syntax that adds
    /// behavior to a property) that reads a shared class instance from the SwiftUI
    /// environment instead of creating one locally. Because `EqualizerManager` publishes
    /// its changes (via `@Published` properties), SwiftUI automatically redraws this view
    /// whenever the manager's settings change, e.g. a slider moving.
    @EnvironmentObject var equalizer: EqualizerManager

    /// Dismiss this modal. `@Environment(\.dismiss)` reads a built-in environment value:
    /// a closure that closes whatever presented this view (typically a `.sheet`).
    @Environment(\.dismiss) var dismiss

    /// Whether the "name this preset" alert (for saving the current band
    /// gains as a new custom preset) is showing.
    @State private var showSavePresetAlert = false

    /// The name typed into that alert's TextField.
    @State private var newPresetName = ""

    /// The main view content, the required `body` computed property every `View` must
    /// provide. SwiftUI calls it to figure out what to draw; this "declarative" style
    /// means you describe *what* the UI should look like for the current data, not the
    /// step-by-step instructions for updating it.
    var body: some View {
        NavigationView { // Embeds content in a navigation controller with title bar
            ScrollView { // Makes all content scrollable if it exceeds screen height
                VStack(spacing: 24) { // Vertical stack; stacks each section top to bottom with 24pt gaps
                    powerToggleSection
                    activePresetSection
                    frequencyBandsSection
                    presetsGridSection
                }
                .padding(.vertical) // Top and bottom padding for the entire stack
            }
            .navigationTitle("Equalizer") // Title displayed in the navigation bar
            .navigationBarTitleDisplayMode(.inline) // Compact title (not large)
            .toolbar {
                // Done button in the top-right corner
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss() // Close the equalizer view
                    }
                }
            }
            // Alert for naming a new custom preset from the current sliders.
            .alert("Save Preset", isPresented: $showSavePresetAlert) {
                TextField("Preset Name", text: $newPresetName)
                Button("Save") {
                    equalizer.saveCustomPreset(name: newPresetName)
                    newPresetName = ""
                }
                Button("Cancel", role: .cancel) {
                    newPresetName = ""
                }
            } message: {
                Text("Save the current band settings as a named preset you can reuse later.")
            }
        }
    }

    // MARK: - Sections
    // "MARK:" comments create bookmarks in Xcode's navigator/minimap; they have no effect on behavior.

    /// Master on/off switch for the equalizer.
    private var powerToggleSection: some View {
        HStack {
            // "Equalizer" title label
            Text("Equalizer")
                .font(.title2) // Slightly smaller than title
                .fontWeight(.bold) // Bold text

            Spacer() // An invisible, flexible view that expands to fill space, pushing the toggle to the right

            // Toggle switch, green when on, gray when off.
            // `Binding` is a two-way connection to a value: it lets this `Toggle` both
            // *read* the current state and *write* changes back, without the Toggle
            // needing to own the data itself. Here we build a custom `Binding` manually
            // (instead of using `$someState`) because turning the toggle on/off needs to
            // run custom logic (`equalizer.toggle()`) rather than just overwriting a stored value.
            Toggle("", isOn: Binding(
                // Read current enabled state from manager
                get: { equalizer.isEnabled },
                // When toggled, call the manager's toggle method.
                // The `_` parameter name means "the new value SwiftUI would have set is
                // intentionally ignored", we don't need it because `toggle()` flips the
                // state itself.
                set: { _ in equalizer.toggle() }
            ))
            .labelsHidden() // Hide the empty label so no extra space appears
        }
        .padding(.horizontal) // Side padding
    }

    /// Shows which preset is currently active.
    private var activePresetSection: some View {
        HStack {
            // "Active:" label
            Text("Active:")
                .font(.subheadline) // Small font
                .foregroundColor(.secondary) // Gray secondary color

            // Name of the active preset
            Text(equalizer.activePreset)
                .font(.subheadline) // Small font
                .fontWeight(.medium) // Medium weight (not bold, not light)
                .foregroundColor(.blue) // Blue text to make it stand out

            Spacer() // Push content to the left
        }
        .padding(.horizontal) // Side padding
    }

    /// 10 vertical sliders, one per frequency band. Each slider goes from -12dB to +12dB.
    private var frequencyBandsSection: some View {
        VStack(spacing: 8) {
            // Section header
            Text("Frequency Bands")
                .font(.headline) // Bold section header
                .frame(maxWidth: .infinity, alignment: .leading) // Stretch left

            // Horizontal scroll of vertical sliders
            ScrollView(.horizontal, showsIndicators: false) { // No scroll bar
                HStack(spacing: 16) { // Horizontal row of band sliders
                    // `0..<10` is a "range" literal meaning "0 up to but not including 10"
                    // (10 values total). `ForEach` turns each value in the range into a
                    // view; `id: \.self` tells it to use the Int itself as the unique
                    // identifier, which works because each band index is distinct.
                    ForEach(0..<10, id: \.self) { band in
                        frequencyBandSlider(band: band)
                    }
                }
                .padding(.horizontal, 4) // Minimal side padding for the scroll
            }
        }
        .padding(.horizontal) // Side padding
    }

    /// A single vertical slider controlling one frequency band's gain.
    /// - Parameter band: The index (0–9) of the frequency band this slider controls.
    private func frequencyBandSlider(band: Int) -> some View {
        VStack(spacing: 8) {
            // Gain value display (e.g. "+4 dB")
            Text("\(Int(equalizer.bandGains[band]))dB")
                .font(.caption2) // Very small font
                .foregroundColor(.secondary) // Gray color
                .frame(width: 40) // Fixed width for alignment

            // Vertical slider for this band.
            // Rotation effect makes it vertical (bottom to top).
            VStack {
                Slider(
                    value: Binding(
                        // Read current gain for this band
                        get: { equalizer.bandGains[band] },
                        // Update gain in the manager when user drags
                        set: { newValue in
                            equalizer.setBand(band, gain: newValue)
                        }
                    ),
                    in: -12...12, // Range: -12dB to +12dB
                    step: 1 // Snap to whole decibel values
                )
                .rotationEffect(.degrees(-90)) // Rotate horizontal slider to vertical
                .frame(width: 120) // Width becomes height after rotation
            }
            .frame(height: 160) // Actual visible height of the slider

            // Frequency label (e.g. "1K", "4K")
            Text(EqualizerManager.bandLabels[band])
                .font(.caption2) // Very small font
                .foregroundColor(.secondary) // Gray color
        }
    }

    /// Grid of preset buttons for quick EQ settings.
    private var presetsGridSection: some View {
        VStack(spacing: 12) {
            // Section header + "Save Current" button, side by side.
            HStack {
                Text("Presets")
                    .font(.headline) // Bold section header

                Spacer()

                // Lets the user name and persist whatever they've currently
                // got dialed in on the sliders, previously the app's only
                // "Custom" state was transient: switching presets, or
                // relaunching the app, lost it with no way to get it back.
                Button {
                    showSavePresetAlert = true
                } label: {
                    Label("Save Current", systemImage: "plus.circle")
                        .font(.subheadline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading) // Stretch left

            // LazyVGrid creates a responsive grid.
            // "Lazy" means rows are only created as they're about to become visible,
            // which keeps large grids fast. `.flexible()` columns adapt to screen width;
            // 3 columns = 3 buttons per row.
            LazyVGrid(
                columns: [
                    GridItem(.flexible()), // Column 1, flexible width
                    GridItem(.flexible()), // Column 2, flexible width
                    GridItem(.flexible())  // Column 3, flexible width
                ],
                spacing: 10 // Vertical spacing between rows
            ) {
                // "Custom" preset (only shown when user manually adjusts bands)
                if equalizer.activePreset == "Custom" {
                    PresetButton(
                        name: "Custom", // Preset name
                        isActive: true, // Always true in this branch, since the condition above already checked it's the active preset
                        action: {} // No action needed, already on Custom, so tapping does nothing
                    )
                }

                // All built-in presets from the EqualizerManager presets dictionary.
                // `EqualizerManager.presets.keys` gives the dictionary's keys (an
                // unordered collection); `.sorted()` puts them in a stable, predictable
                // (alphabetical) order so the grid doesn't reshuffle between app launches.
                // `Array(...)` converts the sorted sequence into a concrete array that
                // `ForEach` can iterate.
                ForEach(Array(EqualizerManager.presets.keys.sorted()), id: \.self) { name in
                    PresetButton(
                        name: name, // Preset name (e.g. "Bass Boost")
                        isActive: equalizer.activePreset == name, // Highlight if active
                        action: {
                            equalizer.applyPreset(name) // Apply the selected preset
                        }
                    )
                }

                // The user's own named custom presets, sorted the same way
                // as the built-in list above. Long-press (or on iPad,
                // right-click) to delete, matches the standard iOS pattern
                // for removing a saved item without a dedicated edit mode.
                ForEach(Array(equalizer.customPresets.keys.sorted()), id: \.self) { name in
                    PresetButton(
                        name: name,
                        isActive: equalizer.activePreset == name,
                        action: {
                            equalizer.applyPreset(name)
                        }
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            equalizer.deleteCustomPreset(name: name)
                        } label: {
                            Label("Delete Preset", systemImage: "trash")
                        }
                    }
                }
            }
        }
        .padding(.horizontal) // Side padding
    }
}

// MARK: - Preset Button

/// A single preset button in the equalizer grid.
///
/// Shows the preset name with a highlight when active.
/// Tapping it applies that preset to all frequency bands.
struct PresetButton: View {

    /// The preset name (e.g. "Bass Boost", "Rock")
    let name: String

    /// Whether this preset is currently active
    let isActive: Bool

    /// Called when the button is tapped.
    /// `() -> Void` is a function type: "a closure that takes no arguments and returns
    /// nothing." Storing a closure as a property like this lets the parent view decide
    /// exactly what should happen on tap, while `PresetButton` itself only cares about
    /// *how it looks*, not *what it does*, a common pattern for reusable components.
    let action: () -> Void

    /// The button's appearance and behavior.
    var body: some View {
        Button(action: action) { // When tapped, run the provided action
            Text(name) // Display the preset name
                .font(.subheadline) // Small font
                .fontWeight(isActive ? .bold : .regular) // Bold when active, normal otherwise
                .frame(maxWidth: .infinity) // Stretch to fill available width
                .padding(.vertical, 10) // Top and bottom padding inside the button
                // Blue background when active, gray when not
                .background(isActive ? Color.blue : Color(.systemGray5))
                .foregroundColor(isActive ? .white : .primary) // White text on blue, dark on gray
                .cornerRadius(10) // Rounded corners
        }
        .buttonStyle(.plain) // Prevents default button styling (blue tint, etc.)
    }
}

#Preview {
    EqualizerView()
        .environmentObject(EqualizerManager()) // Provide a mock EqualizerManager for preview
}
