import SwiftUI

/// Displays lyrics for the currently playing song.
///
/// Supports two modes:
/// 1. **Synced mode**: Highlights the current line as the song plays (karaoke-style)
/// 2. **Plain mode**: Shows all lyrics as scrollable text (when synced not available)
///
/// Also supports translation to other languages via a translate button.
///
/// HOW IT WORKS:
/// - Fetches lyrics from lrclib.net when the song changes
/// - Uses a Timer to check playback position every 0.5 seconds
/// - Scrolls to and highlights the line that matches the current time
/// - Falls back to plain text if synced lyrics aren't available
/// - Users can tap translate to see lyrics in another language
struct LyricsView: View {

    /// `@EnvironmentObject` is a property wrapper (a special annotation that
    /// changes how a property behaves) meaning: "some ancestor view already
    /// placed an `AudioPlayer` into the shared environment, give me a
    /// reference to that same shared instance" rather than creating a new
    /// one here.
    /// The audio player, provides current playback time and song info
    @EnvironmentObject var audioPlayer: AudioPlayer

    /// `@StateObject` is like `@State`, but for reference types that
    /// conform to (implement) the `ObservableObject` protocol, a protocol
    /// (a contract a type promises to fulfill) that lets an object announce
    /// "one of my properties changed, please redraw anything that reads
    /// me." Unlike `@EnvironmentObject`, this view *creates and owns* the
    /// object itself (SwiftUI creates it once and keeps the same instance
    /// alive across re-renders, rather than recreating it every time body
    /// runs).
    /// The lyrics client for fetching lyrics
    @StateObject private var lyricsClient = LyricsClientWrapper()

    /// The lyrics translator for multi-language support
    @StateObject private var translator = LyricsTranslator()

    /// `Lyrics?` is an "optional" `Lyrics`, it can hold either a real
    /// `Lyrics` value or nothing (`nil`). `nil` here means "haven't fetched
    /// lyrics yet" or "fetch found nothing."
    /// The fetched lyrics (nil while loading)
    @State private var lyrics: Lyrics?

    /// Whether lyrics are currently being fetched
    @State private var isLoading = false

    /// The index of the currently highlighted line (synced mode)
    @State private var currentLineIndex: Int = -1

    /// `Timer?` optional because there's no timer running until
    /// `startTimer()` creates one, and we set it back to `nil` in
    /// `stopTimer()` once it's been cancelled.
    /// Timer that checks playback position for synced lyrics
    @State private var timer: Timer?

    /// Whether to show the translated lyrics instead of original
    @State private var showTranslated = false

    /// Whether the language picker is showing
    @State private var showLanguagePicker = false

    /// The target language for translation
    @State private var targetLanguage = ("es", "Spanish")

    /// Translated synced lines (preserving timestamps)
    @State private var translatedSyncedLines: [SyncedLine]?

    /// Translated plain text
    @State private var translatedPlainText: String?

    var body: some View {
        VStack(spacing: 0) {
            // Only shows once lyrics have loaded successfully.
            if lyrics != nil && !isLoading {
                translateButtonBar
            }

            mainContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.3))
        .cornerRadius(16)
        .padding(.horizontal)
        // `.onAppear` runs a closure once, right when this view first
        // becomes visible on screen.
        .onAppear {
            fetchLyrics()
            startTimer()
        }
        // `.onDisappear` runs when the view is removed from screen, we use
        // it to stop the timer so it doesn't keep firing (and wasting
        // battery/CPU) after the lyrics view is gone.
        .onDisappear {
            stopTimer()
        }
        // `.onChange(of:)` watches a specific value and runs a closure
        // whenever it changes. `audioPlayer.currentSong?.id` is an optional
        // String (nil if nothing is playing); watching it means "run this
        // whenever the currently-playing song switches to a different one."
        // The `_` parameter name means we don't need the new value itself,
        // just the fact that it changed.
        .onChange(of: audioPlayer.currentSong?.id) { _ in
            // Song changed, fetch new lyrics and clear translation
            fetchLyrics()
            showTranslated = false
            translator.clearTranslation()
        }
        // Language picker sheet for translation target
        .sheet(isPresented: $showLanguagePicker) {
            LanguagePickerSheet(
                targetLanguage: $targetLanguage,
                onSelect: { translateLyrics() },
                onCancel: { showLanguagePicker = false }
            )
        }
    }

    // MARK: - Translate Button Bar

    /// The small pill button in the top-right corner that opens the
    /// language picker and toggles between original/translated lyrics.
    private var translateButtonBar: some View {
        HStack {
            Spacer()

            // Language picker button
            Button(action: {
                showLanguagePicker = true
            }) {
                HStack(spacing: 4) {
                    // Show the flag of the target language.
                    // This is a chain of "ternary" expressions
                    // (`condition ? valueIfTrue : valueIfFalse`), each one
                    // checks the language name and falls through to the
                    // next check if it doesn't match, ending in a globe
                    // emoji as the fallback for any language without a
                    // specific flag listed here.
                    Text(flagEmoji(for: targetLanguage.1))
                    Text(showTranslated ? "Original" : "Translate")
                        .font(.caption)
                }
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.15))
                .cornerRadius(12)
            }
            // `.disabled` greys out and blocks taps on the button while a
            // translation request is already in flight, so the user can't
            // start a second overlapping translation.
            .disabled(translator.isTranslating)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    /// Maps a language name to its flag emoji for the translate button.
    /// Falls back to a globe emoji for languages without a specific flag.
    private func flagEmoji(for languageName: String) -> String {
        switch languageName {
        case "Spanish": return "🇪🇸"
        case "French": return "🇫🇷"
        case "Japanese": return "🇯🇵"
        case "Korean": return "🇰🇷"
        case "German": return "🇩🇪"
        default: return "🌐"
        }
    }

    // MARK: - Main Content

    /// Chooses between the translating spinner, the loading spinner, the
    /// actual lyrics display, or a "no lyrics found" message, depending on
    /// current state.
    ///
    /// `@ViewBuilder` lets this computed property return a different
    /// concrete view type from each `if`/`else if`/`else` branch, normally
    /// a Swift property must return one fixed type, but `@ViewBuilder`
    /// stitches the branches together behind the scenes.
    @ViewBuilder
    private var mainContent: some View {
        if translator.isTranslating {
            // Translation loading state
            centeredMessage { ProgressView("Translating...") }
        } else if isLoading {
            // Loading state
            centeredMessage { ProgressView("Loading lyrics...") }
        } else if let lyrics = lyrics {
            lyricsDisplay(for: lyrics)
        } else {
            // No lyrics found
            centeredMessage { NoLyricsFoundMessage() }
        }
    }

    /// Wraps arbitrary content between two `Spacer()`s so it's vertically
    /// centered, a small helper to avoid repeating the `Spacer/content/
    /// Spacer` pattern for each loading/empty state.
    private func centeredMessage<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack {
            Spacer()
            content()
            Spacer()
        }
    }

    /// Chooses between the karaoke-style synced display and the plain
    /// scrollable text display, based on whether this song has line-level
    /// timestamps.
    @ViewBuilder
    private func lyricsDisplay(for lyrics: Lyrics) -> some View {
        if lyrics.hasSyncedLyrics {
            // Synced lyrics mode (karaoke-style)
            // Show translated lines if available and toggle is on
            let displayLines = showTranslated ? translatedSyncedLines : lyrics.syncedLines

            SyncedLyricsDisplay(
                lyrics: Lyrics(
                    trackName: lyrics.trackName,
                    artistName: lyrics.artistName,
                    plainText: lyrics.plainText,
                    syncedLines: displayLines
                ),
                currentLineIndex: currentLineIndex,
                onLineTap: { index in
                    // `guard let ... else { return }` is Swift's "early
                    // exit" pattern: try to unwrap the optional
                    // `displayLines?[index]`, and if that fails (index out
                    // of range, or `displayLines` is nil), immediately
                    // leave the closure instead of crashing. Only if the
                    // line is found do we proceed to seek playback to it.
                    // Seek to the tapped line's timestamp
                    guard let line = displayLines?[index] else { return }
                    audioPlayer.seekToTime(line.time)
                }
            )
        } else {
            // Plain text mode
            // Show translated text if available and toggle is on
            let displayText = showTranslated ? (translatedPlainText ?? lyrics.plainText) : lyrics.plainText

            PlainLyricsDisplay(lyrics: Lyrics(
                trackName: lyrics.trackName,
                artistName: lyrics.artistName,
                plainText: displayText,
                syncedLines: nil
            ))
        }
    }

    // MARK: - Lyrics Fetching

    /// Fetch lyrics for the current song.
    private func fetchLyrics() {
        // `guard let song = ... else { ... return }` unwraps the optional
        // `audioPlayer.currentSong`. If nothing is currently playing
        // (`currentSong` is nil), we clear any old lyrics and bail out
        // early instead of trying to fetch lyrics for "nothing."
        guard let song = audioPlayer.currentSong else {
            lyrics = nil
            return
        }

        isLoading = true
        lyrics = nil
        currentLineIndex = -1

        // `Task { ... }` starts a new asynchronous unit of work. We're
        // inside a synchronous function (`fetchLyrics` isn't marked
        // `async`), so `Task` is how we bridge into `await`-able code
        // without blocking the UI while we wait for the network request.
        Task {
            let fetchedLyrics = await lyricsClient.client.fetchLyrics(
                trackName: song.title,
                artistName: song.artist
            )

            // `@State` properties must only be changed on the "main
            // actor" (the thread responsible for updating the UI).
            // `await MainActor.run { ... }` hops back onto that main
            // thread to safely assign `self.lyrics` after the background
            // fetch completes.
            await MainActor.run {
                self.lyrics = fetchedLyrics
                self.isLoading = false
            }
        }
    }

    // MARK: - Translation

    /// Translate the current lyrics to the target language.
    ///
    /// Called when the user taps the translate button.
    /// Handles both synced and plain lyrics.
    private func translateLyrics() {
        guard let lyrics = lyrics else { return }

        // Toggle between original and translated
        if showTranslated {
            // Already showing translated, switch back to original
            showTranslated = false
            return
        }

        // If we already have a translation, just show it
        if translator.translatedText != nil || translatedSyncedLines != nil {
            showTranslated = true
            return
        }

        // Perform the translation
        if lyrics.hasSyncedLyrics, let syncedLines = lyrics.syncedLines {
            // Translate synced lyrics (preserving timestamps)
            Task {
                let translated = await translator.translateSyncedLines(
                    syncedLines,
                    to: targetLanguage.0
                )
                await MainActor.run {
                    self.translatedSyncedLines = translated
                    self.showTranslated = true
                }
            }
        } else {
            // Translate plain text
            translator.translate(lyrics.plainText, to: targetLanguage.0)
            // Observe when translation completes
            Task {
                // Wait for translation to complete.
                // This is a "polling loop": rather than being notified when
                // translation finishes, we repeatedly check
                // `translator.isTranslating` every 0.1 seconds and only
                // proceed once it flips back to false.
                // `Task.sleep(nanoseconds:)` pauses this async task (without
                // blocking the whole app) for the given duration,
                // 100_000_000 nanoseconds = 0.1 seconds. `try?` converts a
                // throwing call into an optional, silently ignoring the
                // (rare) case where sleeping itself throws, since there's
                // nothing useful to do if it does.
                while translator.isTranslating {
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                }
                await MainActor.run {
                    self.translatedPlainText = translator.translatedText
                    self.showTranslated = true
                }
            }
        }
    }

    // MARK: - Synced Lyrics Timer

    /// Start a timer that checks playback position for synced lyrics.
    ///
    /// The timer fires every 0.5 seconds and finds the current line
    /// based on the audio player's currentTime.
    private func startTimer() {
        // `Timer.scheduledTimer` repeatedly calls its closure on the given
        // interval (here, every 0.5 seconds) until it's invalidated.
        // `repeats: true` means it keeps firing rather than firing once.
        // The `_` parameter name means we ignore the Timer instance handed
        // back into the closure each time it fires (we already hold a
        // reference to it in `self.timer`).
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            // `Task { @MainActor in ... }` runs this closure on the main
            // actor (the UI thread), which is required since
            // `updateCurrentLine()` touches @State. Timer callbacks aren't
            // guaranteed to fire on the main thread, so this keeps the
            // @State mutation safe.
            Task { @MainActor in
                updateCurrentLine()
            }
        }
    }

    /// Stop the timer when the view disappears.
    private func stopTimer() {
        // `invalidate()` tells the Timer to stop firing and release its
        // resources; setting `timer = nil` afterward drops our own
        // reference to it too.
        timer?.invalidate()
        timer = nil
    }

    /// Find and highlight the line that matches the current playback time.
    ///
    /// ALGORITHM:
    /// 1. Get the current playback time from the audio player
    /// 2. Walk through synced lines from the current position
    /// 3. Find the last line whose timestamp is ≤ currentTime
    /// 4. Highlight that line
    private func updateCurrentLine() {
        // `guard ... else { return }` bails out early if there are no
        // synced lines to search through (either lyrics haven't loaded, or
        // this song only has plain-text lyrics).
        guard let syncedLines = lyrics?.syncedLines,
              !syncedLines.isEmpty else {
            return
        }

        let currentTime = audioPlayer.currentTime

        // Find the line that should be highlighted
        // Walk backwards from the end to find the last line at or before currentTime
        var foundIndex = -1
        // `enumerated()` gives us both the index and the line for each
        // element as we loop, since we need the index to store in
        // `foundIndex`/`currentLineIndex`.
        for (index, line) in syncedLines.enumerated() {
            if line.time <= currentTime {
                foundIndex = index
            } else {
                // We've passed this line's time, stop looking
                break
            }
        }

        // Only update if the index changed (avoids unnecessary view updates)
        if foundIndex != currentLineIndex {
            currentLineIndex = foundIndex
        }
    }
}

// MARK: - No Lyrics Found Message

/// Empty-state message shown when a lyrics lookup returns nothing.
private struct NoLyricsFoundMessage: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.5))

            Text("No lyrics found")
                .font(.headline)
                .foregroundColor(.white.opacity(0.8))

            Text("Lyrics for this song aren't available")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.5))
        }
    }
}

// MARK: - Language Picker Sheet

/// The sheet (modal card that slides up from the bottom) listing supported
/// translation languages, presented when the user taps the translate
/// button's language picker.
private struct LanguagePickerSheet: View {

    /// `@Binding` is a property wrapper that holds a two-way reference to
    /// state owned by a different (usually parent) view, reading it gives
    /// the current value, and writing it writes back into the original
    /// `@State` property in `LyricsView`. This is how a child view can
    /// change data it doesn't itself own.
    @Binding var targetLanguage: (String, String)

    /// Called after the user picks a language, so the parent can kick off
    /// a new translation request.
    let onSelect: () -> Void

    /// Called when the user taps Cancel, so the parent can dismiss the sheet.
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            List {
                // `LyricsTranslator.supportedLanguages` is presumably a
                // fixed array of language options; `id: \.code` tells
                // `ForEach` to identify each row by its language code
                // (a "key path", `\.code`, pointing at that property)
                // since the language struct itself may not conform to
                // `Identifiable`.
                ForEach(LyricsTranslator.supportedLanguages, id: \.code) { lang in
                    Button(action: {
                        targetLanguage = (lang.code, lang.name)
                        onSelect()
                    }) {
                        HStack {
                            Text(lang.flag)
                            Text(lang.name)
                            Spacer()
                            if lang.code == targetLanguage.0 {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                    .foregroundColor(.primary)
                }
            }
            .navigationTitle("Translate To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }
}

// MARK: - Synced Lyrics Display

/// Karaoke-style lyrics that highlight the current line.
///
/// Shows lines in a scrollable list. The current line is bright white,
/// while other lines are dimmed. Automatically scrolls to keep the
/// current line visible. Tapping a line seeks to that timestamp.
struct SyncedLyricsDisplay: View {

    let lyrics: Lyrics
    let currentLineIndex: Int

    /// Called when the user taps a lyrics line, passes the line index
    /// so the parent can seek to that timestamp
    var onLineTap: ((Int) -> Void)?

    var body: some View {
        // `ScrollViewReader` hands us a `proxy` object that can
        // programmatically scroll to a specific view inside the
        // `ScrollView` below (using the `.id(...)` tags we attach to each
        // line), that's how we auto-scroll to keep the currently sung
        // line visible.
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 20) {
                    // `(lyrics.syncedLines ?? [])` uses the "nil-coalescing"
                    // operator `??`: if `syncedLines` is nil, use an empty
                    // array `[]` instead, so `enumerated()` always has
                    // something safe to work with. `id: \.offset` tells
                    // `ForEach` to identify each row by its position in the
                    // sequence.
                    ForEach(Array((lyrics.syncedLines ?? []).enumerated()), id: \.offset) { index, line in
                        LyricLineView(
                            text: line.text,
                            index: index,
                            currentLineIndex: currentLineIndex,
                            allText: lyrics.syncedLines?.map(\.text).joined(separator: "\n") ?? "",
                            onTap: { onLineTap?(index) }
                        )
                    }
                }
                .padding(.vertical, 60)
            }
            // `.onChange(of: currentLineIndex)` runs whenever the
            // highlighted line changes (i.e. every time the timer finds a
            // new current line), so we can scroll to keep it in view.
            .onChange(of: currentLineIndex) { newIndex in
                // Auto-scroll to keep the current line visible
                guard newIndex >= 0 else { return }
                // `withAnimation { ... }` wraps the scroll so it animates
                // smoothly instead of jumping instantly.
                withAnimation {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }
}

/// A single karaoke-style lyric line: dims/highlights based on whether it's
/// the current line, and offers a long-press menu to copy or share.
private struct LyricLineView: View {
    let text: String
    let index: Int
    let currentLineIndex: Int

    /// All lyric lines joined together, used for the "Share Lyrics" action.
    let allText: String

    let onTap: () -> Void

    /// Computed property: true only when this is the line currently being
    /// sung/highlighted. Kept as a computed property (rather than
    /// recalculating `index == currentLineIndex` repeatedly below) so the
    /// intent reads clearly at each usage site.
    private var isActive: Bool {
        index == currentLineIndex
    }

    var body: some View {
        Text(text)
            // Bigger font, title2 for inactive, title for active (karaoke feel)
            .font(isActive ? .title : .title2)
            .fontWeight(isActive ? .bold : .regular)
            // Current line is bright white, others are dimmed
            .foregroundColor(isActive ? .white : .white.opacity(0.35))
            // Current line scales up for emphasis
            .scaleEffect(isActive ? 1.1 : 1.0)
            // `.animation(_:value:)` tells SwiftUI to smoothly interpolate
            // (animate) any changes to properties above that were driven by
            // `currentLineIndex`, rather than snapping instantly.
            // Animate scale + opacity changes smoothly
            .animation(.easeInOut(duration: 0.35), value: currentLineIndex)
            .id(index) // Needed for ScrollViewReader to scroll to this view
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .padding(.vertical, 8)
            // Pill-shaped background behind the active line (karaoke highlight)
            .background(
                Group {
                    if isActive {
                        // White background pill at 15% opacity
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.white.opacity(0.15))
                    } else {
                        // "Previous" lines get a subtle purple tint,
                        // "upcoming" lines have no background
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.clear)
                    }
                }
            )
            // Tap to seek, tapping any line jumps playback to that timestamp
            .onTapGesture(perform: onTap)
            // Long press to copy this line
            .contextMenu {
                Button {
                    // `UIPasteboard.general` is the system clipboard;
                    // setting `.string` copies text to it so the user can
                    // paste it elsewhere.
                    UIPasteboard.general.string = text
                } label: {
                    Label("Copy Line", systemImage: "doc.on.doc")
                }

                Button {
                    UIPasteboard.general.string = allText
                    // `UIActivityViewController` is the system iOS "Share
                    // Sheet", the panel offering Messages, Mail, AirDrop,
                    // etc. It's a UIKit (the older, non-SwiftUI iOS UI
                    // framework) component, so we have to reach into UIKit
                    // APIs to present it.
                    let activityVC = UIActivityViewController(
                        activityItems: [allText],
                        applicationActivities: nil
                    )
                    // `UIApplication.shared.connectedScenes` lists the
                    // app's active "scenes" (roughly, windows); we cast the
                    // first one to `UIWindowScene` and dig out its root
                    // view controller, since presenting UIKit view
                    // controllers requires going through one, unlike
                    // SwiftUI's `.sheet`.
                    // Get the root view controller to present the share sheet
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let rootVC = windowScene.windows.first?.rootViewController {
                        rootVC.present(activityVC, animated: true)
                    }
                } label: {
                    Label("Share Lyrics", systemImage: "square.and.arrow.up")
                }
            }
    }
}

// MARK: - Plain Lyrics Display

/// Simple scrollable text view for plain lyrics (no timestamps).
struct PlainLyricsDisplay: View {

    let lyrics: Lyrics

    var body: some View {
        ScrollView {
            Text(lyrics.plainText)
                .font(.body)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.vertical, 40)
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = lyrics.plainText
                    } label: {
                        Label("Copy Lyrics", systemImage: "doc.on.doc")
                    }

                    Button {
                        let activityVC = UIActivityViewController(
                            activityItems: [lyrics.plainText],
                            applicationActivities: nil
                        )
                        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                           let rootVC = windowScene.windows.first?.rootViewController {
                            rootVC.present(activityVC, animated: true)
                        }
                    } label: {
                        Label("Share Lyrics", systemImage: "square.and.arrow.up")
                    }
                }
        }
    }
}

// MARK: - Lyrics Client Wrapper

/// A wrapper around LyricsClient that works with SwiftUI's @StateObject.
///
/// @StateObject requires an ObservableObject, but LyricsClient is a plain class.
/// This wrapper creates and holds the LyricsClient instance.
class LyricsClientWrapper: ObservableObject {
    /// The actual lyrics client
    let client = LyricsClient()
}

// MARK: - Preview

#Preview {
    LyricsView()
        .environmentObject(AudioPlayer())
}
