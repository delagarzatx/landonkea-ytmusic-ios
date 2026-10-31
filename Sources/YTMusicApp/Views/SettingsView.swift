import SwiftUI
// NOTE: This file previously also imported UniformTypeIdentifiers, but nothing
// here actually uses it (no UTType values appear anywhere below), so it was
// removed. An unused import doesn't crash anything, but it's dead code,
// it makes a reader wonder "wait, where is this used?" for no reason.

/// Settings screen where users can customize app behavior.
///
/// HOW IT WORKS:
/// - Uses `@AppStorage` to persist settings in UserDefaults (iOS key-value store)
/// - Settings are automatically saved when changed and loaded on app launch
/// - Some settings (like streamQuality) are stored but not yet wired up to AudioPlayer
/// - Future work: connect these to actual behavior + add login for YouTube Music account
///
/// GLOSSARY (terms explained here the first time they appear in this file):
/// - **property wrapper**: a `@SomethingLikeThis` annotation placed before a
///   property that changes how that property is stored/read/written behind
///   the scenes. `@AppStorage`, `@State`, and `@EnvironmentObject` (below) are
///   all property wrappers.
/// - **@EnvironmentObject**: reads a shared object that some ancestor view
///   injected into the "environment" (with `.environmentObject(...)`), rather
///   than the object being passed down explicitly through every initializer.
///   Any view can reach into the environment for it, and the view
///   automatically refreshes whenever that object's published data changes.
/// - **Binding**: a two-way connection to a value owned somewhere else. A `$`
///   prefix on a state property (e.g. `$darkMode`) creates a `Binding<Bool>`
///   that a control like `Toggle` can both read from and write to, so the
///   toggle changes the *real* underlying value, not a copy of it.
/// - **closure**: a self-contained block of code (like `{ showClearCacheAlert = true }`)
///   that can be passed around and executed later, used heavily as button
///   actions and callback handlers throughout SwiftUI.
struct SettingsView: View {

    // MARK: - Persisted Settings

    // @AppStorage is a SwiftUI property wrapper that reads/writes to UserDefaults.
    // It works like @State, but the value persists between app launches.
    // The string key ("darkMode") is how it's stored in UserDefaults.

    /// Whether dark mode is enabled. When toggled, it immediately affects
    /// the `.preferredColorScheme` modifier at the bottom of this view.
    @AppStorage("darkMode") private var darkMode = true

    /// Whether to follow the system appearance.
    /// When true, ignores darkMode and uses the device's light/dark setting.
    @AppStorage("autoAppearance") private var autoAppearance = false

    /// Audio stream quality preference for playback.
    /// Controls which audio stream the player requests (affects data usage + quality).
    @AppStorage("streamQuality") private var streamQuality = "high"

    /// Audio stream quality preference for downloads.
    /// Separate from stream quality, lets users save storage by downloading lower quality.
    @AppStorage("downloadQuality") private var downloadQuality = "high"

    /// Whether crossfade between songs is enabled.
    /// Saved to UserDefaults so AudioPlayer can read it on launch.
    @AppStorage("crossfadeEnabled") private var crossfadeEnabled = false

    /// Crossfade duration in seconds (the overlap time between songs).
    /// Stored as a Double via string key for simplicity.
    @AppStorage("crossfadeDuration") private var crossfadeDuration = 5.0

    /// Whether to only download songs over Wi-Fi.
    @AppStorage("downloadOverWifiOnly") private var downloadOverWifiOnly = true

    /// Font size scale factor (0 = small, 1 = medium, 2 = large).
    /// Applied globally via a custom view modifier in ContentView.
    @AppStorage("fontSizeScale") private var fontSizeScale = 1

    /// The offline manager for storage info.
    /// Declared with `@EnvironmentObject` (see glossary above), some parent
    /// view further up the hierarchy supplied this with `.environmentObject(...)`.
    @EnvironmentObject var offlineManager: OfflineManager

    /// The stats manager for listening statistics.
    @EnvironmentObject var statsManager: StatsManager

    /// Whether to show the clear cache confirmation alert.
    /// A `@State` property: local, private, in-memory-only state that is NOT
    /// saved anywhere, it resets to `false` every time this view is recreated.
    @State private var showClearCacheAlert = false

    // MARK: - Body

    // The body is intentionally short: it just assembles the List out of
    // section builders defined further down. Each section used to be written
    // directly inline inside one giant `body`, which made the file hard to
    // scan. Splitting each section into its own small, named computed
    // property makes every piece easy to find, read, and reason about on its
    // own, and each one's job is described by its name alone.
    var body: some View {
        // NavigationView provides the nav bar with title
        NavigationView {
            // List = scrollable grouped table (like iOS Settings app)
            List {
                appearanceSection
                playbackSection
                downloadsSection
                storageSection
                statsSection
                aboutSection
            }
            .navigationTitle("Settings")
            // This modifier overrides the app's color scheme based on the toggle.
            // When autoAppearance is on → use nil (follow system).
            // When autoAppearance is off → use darkMode toggle value.
            // nil is Swift's way of representing "no value here." An optional
            // color scheme of `nil` specifically means "don't override,
            // inherit whatever the system/device is set to" (auto mode).
            .preferredColorScheme(autoAppearance ? nil : (darkMode ? .dark : .light))
        }
    }

    // MARK: - Sections

    /// Appearance section: dark mode / auto / font size controls.
    private var appearanceSection: some View {
        Section {
            // Auto-appearance, follows the system light/dark setting
            // When enabled, overrides the manual dark mode toggle
            Toggle(isOn: $autoAppearance) {
                Label("Auto (Follow System)", systemImage: "iphone")
            }

            // Manual dark mode toggle, only adjustable when auto is off
            // Dimmed appearance when auto is enabled to indicate it's disabled
            Toggle(isOn: $darkMode) {
                Label("Dark Mode", systemImage: "moon.fill")
            }
            .opacity(autoAppearance ? 0.5 : 1.0)
            .disabled(autoAppearance)

            // Font size picker, adjusts text size across the app
            // 0 = small, 1 = medium (default), 2 = large.
            // Picker is a dropdown/segmented control for choosing among fixed
            // options; `.tag(0)` marks each Text as the value that gets
            // written into `fontSizeScale` when the user picks that row.
            Picker("Font Size", selection: $fontSizeScale) {
                Text("Small").tag(0)
                Text("Medium").tag(1)
                Text("Large").tag(2)
            }
        } header: {
            Text("Appearance")
        } footer: {
            // Footer text appears below the section in smaller gray text
            Text("Auto follows your device's light/dark mode setting")
        }
    }

    /// Playback section: stream quality, crossfade toggle + duration.
    private var playbackSection: some View {
        Section {
            // Picker = dropdown/segment selector for choosing from options.
            // The `selection` binding tells SwiftUI which option is active.
            // Each `.tag()` marks a case as a possible value for the picker.
            Picker("Stream Quality", selection: $streamQuality) {
                Text("Low (72kbps)").tag("low")
                Text("Medium (128kbps)").tag("medium")
                Text("High (256kbps)").tag("high")
            }

            // Crossfade toggle, smooth transitions between songs
            Toggle(isOn: $crossfadeEnabled) {
                Label("Crossfade", systemImage: "shuffle")
            }

            // Crossfade duration picker, only shown when crossfade is enabled.
            // This `if` inside a SwiftUI view builder conditionally includes
            // or excludes a whole chunk of UI, based on plain Swift state,
            // that's what "declarative UI" means: describe what should show
            // *given* the current state, and let SwiftUI handle animating
            // the row in/out.
            if crossfadeEnabled {
                Picker("Fade Duration", selection: $crossfadeDuration) {
                    Text("2 seconds").tag(2.0)
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                    Text("8 seconds").tag(8.0)
                    Text("10 seconds").tag(10.0)
                }
            }
        } header: {
            Text("Playback")
        } footer: {
            Text("Higher quality uses more data")
        }
    }

    /// Downloads section: download quality + Wi-Fi-only toggle.
    private var downloadsSection: some View {
        Section {
            // Download quality picker, controls audio bitrate for downloads
            Picker("Download Quality", selection: $downloadQuality) {
                Text("Low (72kbps)").tag("low")
                Text("Medium (128kbps)").tag("medium")
                Text("High (256kbps)").tag("high")
            }

            Toggle(isOn: $downloadOverWifiOnly) {
                Label("Wi-Fi Only", systemImage: "wifi")
            }
        } header: {
            Text("Downloads")
        } footer: {
            Text("Lower quality uses less storage space")
        }
    }

    /// Storage section: total download size + destructive "clear all" action.
    private var storageSection: some View {
        Section {
            // Show total storage used by downloads
            HStack {
                Label("Downloads", systemImage: "arrow.down.circle")
                Spacer()
                Text(downloadsSize)
                    .foregroundColor(.secondary)
            }

            // Clear cache button. `role: .destructive` tells SwiftUI (and
            // accessibility tools like VoiceOver) that this action is
            // dangerous/irreversible, which is also why the label is styled red.
            Button(role: .destructive) {
                showClearCacheAlert = true
            } label: {
                Label("Clear All Downloads", systemImage: "trash")
                    .foregroundColor(.red)
            }
            // .disabled(true) grays the button out and blocks taps, here it's
            // disabled whenever there's nothing to clear.
            .disabled(offlineManager.downloads.isEmpty)
        } header: {
            Text("Storage")
        } footer: {
            Text("Downloads are stored on your device for offline playback")
        }
        // .alert attaches a modal confirmation dialog to this section. It only
        // appears when the bound Bool (`$showClearCacheAlert`) becomes true,
        // and SwiftUI automatically flips it back to false when the alert is
        // dismissed either way.
        .alert("Clear All Downloads?", isPresented: $showClearCacheAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Clear", role: .destructive) {
                offlineManager.deleteAll()
            }
        } message: {
            Text("This will remove all \(offlineManager.downloads.count) downloaded songs. This action cannot be undone.")
        }
    }

    /// Listening stats section: total time, songs played, top artists.
    private var statsSection: some View {
        Section {
            HStack {
                Label("Total Time", systemImage: "clock")
                Spacer()
                Text(statsManager.formattedTotalTime)
                    .foregroundColor(.secondary)
            }

            HStack {
                Label("Songs Played", systemImage: "music.note")
                Spacer()
                Text("\(statsManager.totalSongsPlayed)")
                    .foregroundColor(.secondary)
            }

            // Top artists.
            // `let` inside a view builder computes a plain Swift value once,
            // which the rows below can then reuse without recalculating it.
            let topArtists = statsManager.topArtists(limit: 3)
            if !topArtists.isEmpty {
                topArtistsList(topArtists)
            }
        } header: {
            Text("Listening Stats")
        }
    }

    /// The "Top Artists" mini-list shown inside `statsSection`.
    /// Pulled into its own method (rather than being written inline) because
    /// it has its own internal loop and layout, separating it keeps
    /// `statsSection` readable as a flat list of rows.
    /// - Parameter topArtists: array of (artist, play count) pairs, already
    ///   limited to the top 3 by `StatsManager`.
    private func topArtistsList(_ topArtists: [(artist: String, count: Int)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Top Artists", systemImage: "person.2.fill")
                .padding(.bottom, 4)
            // ForEach repeats a row of UI once per element in a collection.
            // `Array(topArtists.enumerated())` pairs each artist with its
            // index (0, 1, 2, ...) so we can show "1. ArtistName" etc.
            // `id: \.offset` uses that index as the unique identifier SwiftUI
            // needs to track each row (safe here because the list is short
            // and rebuilt fresh each time, not reordered in place).
            ForEach(Array(topArtists.enumerated()), id: \.offset) { index, entry in
                HStack {
                    Text("\(index + 1). \(entry.artist)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(entry.count) plays")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    /// About section: version, developer, and external links.
    private var aboutSection: some View {
        Section {
            // Static info rows, just display text, no action
            HStack {
                Text("Version")
                Spacer() // Pushes version number to the right
                Text("1.0.0")
                    .foregroundColor(.secondary) // Gray color
            }

            HStack {
                Text("Developer")
                Spacer()
                Text("Landon")
                    .foregroundColor(.secondary)
            }

            // Link = tappable row that opens a URL in Safari.
            // We use a force-unwrap `URL(string:)!` here because these are
            // hardcoded string literals written directly in this file, the
            // compiler guarantees the exact same text every time the app
            // runs, so this can never actually be nil. This is different
            // from force-unwrapping a URL built from data that came back
            // from a network response (like a thumbnail URL from the API),
            // which SHOULD use `if let`/`guard let` because malformed or
            // unexpected server data really can fail to parse into a URL.
            Link(destination: URL(string: "https://github.com/landonkea/landonkea-ytmusic-ios")!) {
                HStack {
                    Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    Spacer()
                    // External link indicator icon
                    Image(systemName: "arrow.up.right.square")
                        .foregroundColor(.secondary)
                }
            }

            Link(destination: URL(string: "https://github.com/landonkea/landonkea-ytmusic-ios/issues")!) {
                HStack {
                    Label("Report a Bug", systemImage: "ant.fill")
                    Spacer()
                    Image(systemName: "arrow.up.right.square")
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("About")
        }
    }

    // MARK: - Computed Properties

    /// Human-readable download storage size.
    private var downloadsSize: String {
        let totalBytes = offlineManager.totalStorageUsed()
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalBytes)
    }
}

#Preview {
    SettingsView()
}
