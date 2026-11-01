import SwiftUI

// MARK: - Winamp palette
// The classic Winamp look: brushed dark-metal panels, a black LCD with
// green LED text, and chunky raised transport buttons. Ronda 6 turned
// the player into that face at David's request ("estilo retro tipo
// Winamp"), with the 31-band EQ window to match.

/// LED green used across the whole Winamp face.
private let waGreen = Color(red: 0.16, green: 0.96, blue: 0.26)
/// Dimmer green for secondary LCD text.
private let waGreenDim = Color(red: 0.10, green: 0.55, blue: 0.16)
/// Near-black LCD background.
private let waLCD = Color(red: 0.02, green: 0.05, blue: 0.02)
/// Panel metal gradient stops.
private let waPanelTop = Color(red: 0.16, green: 0.16, blue: 0.20)
private let waPanelBottom = Color(red: 0.07, green: 0.07, blue: 0.09)

/// The full-screen music player, Winamp-style (ronda 6).
///
/// HOW IT WORKS:
/// - Presented as a full-screen cover when the mini player is tapped
/// - One "main window": LCD (time, spectrum visualizer, marquee title),
///   position slider, transport buttons, VOL/BAL sliders, toggle chips
/// - Below it, the "playlist window": the live queue, monospace green
///   on black, current track highlighted; already-played rows can be
///   tapped to jump back (same rule as QueueView's History section)
/// - All playback actions still go through AudioPlayer; the EQ window,
///   queue sheet, lyrics, sleep timer, car mode, related songs and the
///   speed picker are the same sheets the old player had.
struct PlayerView: View {

    @EnvironmentObject var audioPlayer: AudioPlayer
    @Environment(\.dismiss) var dismiss
    @Binding var isShowing: Bool

    @State private var showLyrics = false
    @State private var showCarMode = false
    @State private var showSleepTimer = false
    @State private var showEqualizer = false
    @State private var showQueue = false
    @State private var showRelated = false
    @State private var showSpeedPicker = false
    /// Winamp's time display toggles elapsed/remaining when tapped.
    @State private var showRemaining = false

    @EnvironmentObject var offlineManager: OfflineManager
    @EnvironmentObject var equalizer: EqualizerManager
    @EnvironmentObject var apiClient: APIClient

    var body: some View {
        // Group so the auto-dismiss modifier below applies no matter
        // which branch is on screen.
        Group {
        if let song = audioPlayer.currentSong {
            ZStack {
                LinearGradient(colors: [waPanelTop, waPanelBottom],
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 10) {
                        titleBar(for: song)
                        lcdPanel(for: song)
                        positionSlider
                        transportRow
                        volBalRow
                        toggleRow
                        secondaryRow(for: song)
                        playlistWindow(for: song)
                    }
                    .padding(10)
                }
            }
            .transition(.move(edge: .bottom))
            .sheet(isPresented: $showRelated) {
                relatedSongsSheet(for: song)
            }
            .sheet(isPresented: $showCarMode) {
                CarModeView()
                    .environmentObject(audioPlayer)
            }
            .sheet(isPresented: $showSleepTimer) {
                SleepTimerView()
                    .environmentObject(audioPlayer)
            }
            .sheet(isPresented: $showEqualizer) {
                EqualizerView()
                    .environmentObject(equalizer)
            }
            .sheet(isPresented: $showQueue) {
                QueueView()
            }
            .sheet(isPresented: $showSpeedPicker) {
                speedPickerSheet
            }
            .gesture(
                DragGesture()
                    .onEnded { value in
                        if value.translation.height > 80 {
                            isShowing = false
                        }
                    }
            )
            .preferredColorScheme(.dark)
        } else {
            nothingPlayingView
        }
        }
        // When the current song goes away entirely (Stop button, Next
        // on the last song in the queue), close the cover on its own:
        // a full-screen cover whose content vanished would otherwise
        // sit there black, with no controls and no swipe to escape.
        // The else branch above is the safety net if this never fires.
        .onChange(of: audioPlayer.currentSong?.id) { newId in
            if newId == nil {
                isShowing = false
            }
        }
    }

    /// Fallback face for "cover is up but nothing is playing": same
    /// panel background, an LCD-style label and a working Close, so
    /// the full-screen player can never become a black dead end.
    private var nothingPlayingView: some View {
        ZStack {
            LinearGradient(colors: [waPanelTop, waPanelBottom],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Text("NOTHING PLAYING")
                    .font(.system(size: 13, weight: .black, design: .monospaced))
                    .foregroundColor(waGreen)
                Button {
                    isShowing = false
                } label: {
                    Text("CLOSE")
                        .font(.system(size: 11, weight: .black, design: .monospaced))
                        .foregroundColor(Color(white: 0.88))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .background(LinearGradient(colors: [Color(white: 0.38), Color(white: 0.16)],
                                                   startPoint: .top, endPoint: .bottom))
                        .overlay(Rectangle().stroke(Color(white: 0.55), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close player")
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Title bar

    /// Winamp-style title bar: app name left, share + close right.
    private func titleBar(for song: NowPlaying) -> some View {
        HStack(spacing: 8) {
            Text("▚ WINAMP")
                .font(.system(size: 13, weight: .black, design: .monospaced))
                .foregroundColor(waGreen)
            Text("HERON MUSIC")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.45))
            Spacer()
            ShareLink(
                item: URL(string: "https://music.youtube.com/watch?v=\(song.id)")
                    ?? URL(string: "https://music.youtube.com")!,
                preview: SharePreview(song.title)
            ) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(waGreen)
            }
            Button {
                isShowing = false
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .black))
                    .foregroundColor(waGreen)
            }
            .accessibilityLabel("Close player")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.35))
        .overlay(Rectangle().stroke(Color.white.opacity(0.15), lineWidth: 1))
    }

    // MARK: - LCD panel

    /// The black LCD: big green time, the spectrum visualizer, the
    /// scrolling title, and the source line (local file vs streaming).
    private func lcdPanel(for song: NowPlaying) -> some View {
        VStack(spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                // Time + play state. Tap toggles elapsed / remaining.
                VStack(alignment: .leading, spacing: 2) {
                    Text(timeText)
                        .font(.system(size: 30, weight: .bold, design: .monospaced))
                        .foregroundColor(waGreen)
                        .onTapGesture { showRemaining.toggle() }
                    HStack(spacing: 5) {
                        Image(systemName: audioPlayer.state == .playing ? "play.fill" : "pause.fill")
                            .font(.system(size: 8))
                            .foregroundColor(waGreen)
                        Text(audioPlayer.state == .playing ? "PLAY" : "PAUSE")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(waGreenDim)
                    }
                }

                Spacer()

                spectrumView

                // Small artwork, like Winamp's video/vis window thumbnail.
                AsyncImage(url: URL(string: song.thumbnailUrl)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(Color.white.opacity(0.08))
                        .overlay(Image(systemName: "music.note").foregroundColor(waGreenDim))
                }
                .frame(width: 54, height: 54)
                .clipped()
                .overlay(Rectangle().stroke(waGreenDim, lineWidth: 1))
            }

            MarqueeText(text: "\(song.title)  —  \(song.artist)")
                .frame(height: 16)

            HStack {
                Text(sourceLabel(for: song))
                Spacer()
                Text("\(formatTime(audioPlayer.duration)) TOTAL")
            }
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(waGreenDim)
        }
        .padding(10)
        .background(waLCD)
        .overlay(Rectangle().stroke(Color.white.opacity(0.25), lineWidth: 1))
        .overlay(Rectangle().stroke(Color.black, lineWidth: 3).opacity(0.6))
    }

    /// Elapsed time, or "-remaining" after tapping the LCD clock.
    private var timeText: String {
        if showRemaining {
            return "-" + formatTime(max(0, audioPlayer.duration - audioPlayer.currentTime))
        }
        return formatTime(audioPlayer.currentTime)
    }

    /// Honest source line: the EQ and visualizer only exist on the local
    /// (downloaded) path; streamed songs say so instead of faking it.
    private func sourceLabel(for song: NowPlaying) -> String {
        if offlineManager.isDownloaded(song.id) {
            return equalizer.isEnabled ? "LOCAL • 31-BAND EQ ON" : "LOCAL FILE"
        }
        if offlineManager.isDownloading(song.id) {
            return "DOWNLOADING…"
        }
        return "STREAMING"
    }

    /// The 24-bar spectrum, fed by the engine's real FFT tap. On the
    /// AVPlayer (streaming) path the levels stay zero and the bars rest
    /// flat: no fake animation.
    private var spectrumView: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<24, id: \.self) { i in
                let level = i < audioPlayer.spectrumLevels.count
                    ? CGFloat(audioPlayer.spectrumLevels[i]) : 0
                Rectangle()
                    .fill(barColor(level))
                    .frame(width: 4.5, height: max(2, level * 40))
            }
        }
        .frame(height: 42, alignment: .bottom)
        .padding(.top, 4)
    }

    private func barColor(_ level: CGFloat) -> Color {
        if level > 0.85 { return Color(red: 0.98, green: 0.25, blue: 0.15) }
        if level > 0.62 { return Color(red: 0.98, green: 0.85, blue: 0.20) }
        return waGreen
    }

    // MARK: - Position

    private var positionSlider: some View {
        Slider(
            value: Binding(
                get: { audioPlayer.progress },
                set: { newValue in audioPlayer.seek(to: newValue) }
            )
        ) { _ in }
        .tint(waGreen)
        .accessibilityLabel("Song progress")
    }

    // MARK: - Transport

    /// Chunky metal transport: previous / play-pause / stop / next,
    /// plus the speed readout as an LCD chip on the right.
    private var transportRow: some View {
        HStack(spacing: 8) {
            metalButton("backward.end.fill") { audioPlayer.playPrevious() }
            metalButton(audioPlayer.state == .playing ? "pause.fill" : "play.fill") {
                audioPlayer.togglePlayPause()
            }
            metalButton("stop.fill") { audioPlayer.stop() }
            metalButton("forward.end.fill") { audioPlayer.playNext() }
            Spacer()
            Button {
                showSpeedPicker = true
            } label: {
                Text("\(audioPlayer.playbackRate, specifier: "%.1f")×")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(abs(audioPlayer.playbackRate - 1.0) > 0.01 ? .yellow : waGreen)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(waLCD)
                    .overlay(Rectangle().stroke(Color.white.opacity(0.2), lineWidth: 1))
            }
            .accessibilityLabel("Playback speed")
        }
    }

    private func metalButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Color(white: 0.88))
                .frame(width: 46, height: 32)
                .background(LinearGradient(colors: [Color(white: 0.38), Color(white: 0.16)],
                                           startPoint: .top, endPoint: .bottom))
                .overlay(Rectangle().stroke(Color(white: 0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Volume / Balance

    /// Winamp had VOL and BAL mini-sliders side by side; here they are.
    /// Balance only affects the local (engine) path: AVPlayer can't pan.
    private var volBalRow: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Text("VOL")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(waGreenDim)
                Slider(
                    value: Binding(
                        get: { audioPlayer.volume },
                        set: { newValue in audioPlayer.setVolume(newValue) }
                    )
                ) { _ in }
                .tint(waGreen)
            }
            HStack(spacing: 6) {
                Text("BAL")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(waGreenDim)
                Slider(
                    value: Binding(
                        get: { audioPlayer.balance },
                        set: { newValue in audioPlayer.setBalance(newValue) }
                    ),
                    in: -1...1
                ) { _ in }
                .tint(waGreen)
            }
        }
    }

    // MARK: - Toggles

    /// LCD chips: SHUFFLE / REPEAT / EQ / PLAYLIST / LYRICS.
    private var toggleRow: some View {
        HStack(spacing: 8) {
            lcdToggle("SHUFFLE", active: audioPlayer.isShuffled) {
                audioPlayer.toggleShuffle()
            }
            lcdToggle(repeatLabel, active: audioPlayer.repeatMode != .none) {
                audioPlayer.toggleRepeat()
            }
            lcdToggle("EQ", active: equalizer.isEnabled) {
                showEqualizer = true
            }
            lcdToggle("PLAYLIST", active: false) {
                showQueue = true
            }
            lcdToggle("LYRICS", active: showLyrics) {
                showLyrics.toggle()
            }
            Spacer()
        }
    }

    private var repeatLabel: String {
        audioPlayer.repeatMode == .one ? "REPEAT 1" : "REPEAT"
    }

    private func lcdToggle(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .black, design: .monospaced))
                .foregroundColor(active ? .black : waGreen)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(active ? waGreen : Color.black.opacity(0.55))
                .overlay(Rectangle().stroke(waGreen.opacity(0.55), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Secondary actions

    /// Download state, car mode, sleep timer and related songs, the
    /// functions the old player's bottom row carried.
    private func secondaryRow(for song: NowPlaying) -> some View {
        HStack(spacing: 22) {
            Button {
                downloadCurrentSong()
            } label: {
                if offlineManager.isDownloading(song.id) {
                    ProgressView().tint(waGreen)
                } else if offlineManager.isDownloaded(song.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(waGreen)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .foregroundColor(.white.opacity(0.55))
                }
            }
            .disabled(offlineManager.isDownloaded(song.id) || offlineManager.isDownloading(song.id))
            .accessibilityLabel("Download song")

            Button {
                showCarMode = true
            } label: {
                Image(systemName: "car.fill").foregroundColor(.white.opacity(0.55))
            }
            .accessibilityLabel("Car mode")

            Button {
                showSleepTimer = true
            } label: {
                Image(systemName: audioPlayer.isSleepTimerActive ? "moon.fill" : "moon")
                    .foregroundColor(audioPlayer.isSleepTimerActive ? .purple : .white.opacity(0.55))
            }
            .accessibilityLabel("Sleep timer")

            Button {
                showRelated.toggle()
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundColor(.white.opacity(0.55))
            }
            .accessibilityLabel("Related songs")

            Spacer()
        }
        .font(.system(size: 17))
        .padding(.horizontal, 4)
    }

    // MARK: - Playlist window

    /// The Winamp playlist editor, embedded under the main window:
    /// numbered monospace rows on black, current track lit green.
    /// Tapping an already-played row jumps back to it (playFromHistory);
    /// upcoming rows are managed from the PLAYLIST sheet (QueueView).
    /// When lyrics are on, this window shows the lyrics instead.
    private func playlistWindow(for song: NowPlaying) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("PLAYLIST")
                    .font(.system(size: 10, weight: .black, design: .monospaced))
                    .foregroundColor(waGreen)
                Spacer()
                Text("\(audioPlayer.queue.count) TRACKS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundColor(waGreenDim)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.5))

            if showLyrics {
                LyricsView()
                    .frame(height: 280)
            } else {
                VStack(spacing: 0) {
                    // Rows are identified by position, NOT by song id:
                    // the same song can legitimately sit in the queue
                    // twice, and ForEach with duplicate ids is undefined
                    // behavior (corrupted diffs, crashes).
                    ForEach(Array(audioPlayer.queue.enumerated()), id: \.offset) { index, item in
                        playlistRow(index: index, item: item)
                        if index < audioPlayer.queue.count - 1 {
                            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
                        }
                    }
                }
            }
        }
        .background(waLCD)
        .overlay(Rectangle().stroke(Color.white.opacity(0.25), lineWidth: 1))
    }

    private func playlistRow(index: Int, item: NowPlaying) -> some View {
        let isCurrent = index == audioPlayer.currentIndex
        let isPast = index < audioPlayer.currentIndex
        return HStack(spacing: 8) {
            Text(String(format: "%02d.", index + 1))
                .foregroundColor(isCurrent ? waGreen : waGreenDim)
            Text("\(item.title) — \(item.artist)")
                .lineLimit(1)
                .foregroundColor(isCurrent ? waGreen : Color(white: 0.75))
            Spacer()
            if isCurrent {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 9))
                    .foregroundColor(waGreen)
            }
            Text(formatTime(Double(item.duration)))
                .foregroundColor(waGreenDim)
        }
        .font(.system(size: 11, weight: isCurrent ? .bold : .regular, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(isCurrent ? waGreen.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            // Only history jumps exist in AudioPlayer (same rule as
            // QueueView); upcoming rows stay display-only here.
            if isPast {
                audioPlayer.playFromHistory(at: index)
            }
        }
    }

    // MARK: - Sheets kept from the old player

    private func relatedSongsSheet(for song: NowPlaying) -> some View {
        NavigationView {
            ScrollView {
                RelatedSongsView(videoId: song.id)
                    .padding()
            }
            .navigationTitle("Related Songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        showRelated = false
                    }
                }
            }
        }
        .environmentObject(apiClient)
        .environmentObject(audioPlayer)
    }

    private var speedPickerSheet: some View {
        NavigationView {
            List {
                Section("Playback Speed") {
                    ForEach(PlaybackRate.allCases, id: \.rawValue) { rate in
                        Button {
                            audioPlayer.setPlaybackRate(rate.rawValue)
                            showSpeedPicker = false
                        } label: {
                            HStack {
                                Text(rate.label)
                                    .foregroundColor(.primary)
                                Spacer()
                                if abs(audioPlayer.playbackRate - rate.rawValue) < 0.01 {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.purple)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { showSpeedPicker = false }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Download the current song for offline playback (unchanged logic:
    /// re-fetch player info at the download quality, then hand the URL
    /// to OfflineManager).
    private func downloadCurrentSong() {
        guard let song = audioPlayer.currentSong else { return }
        guard !offlineManager.isDownloaded(song.id),
              !offlineManager.isDownloading(song.id) else { return }

        Task {
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
                print("Failed to get download URL: \(error)")
            }
        }
    }

    /// Seconds → "3:45", with a NaN/infinite guard.
    private func formatTime(_ seconds: Double) -> String {
        guard !seconds.isNaN && !seconds.isInfinite else {
            return "0:00"
        }
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

// MARK: - Marquee

/// A single-line scrolling text, Winamp's signature title crawl.
/// Short text renders static; long text loops with a linear animation.
private struct MarqueeText: View {
    let text: String

    @State private var offset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            // ~7.3 pt per character at 12 pt monospaced bold.
            let textWidth = CGFloat(text.count) * 7.3
            if textWidth > geo.size.width {
                HStack(spacing: 40) {
                    label
                    label
                }
                .offset(x: offset)
                .onAppear {
                    offset = 0
                    withAnimation(.linear(duration: Double(textWidth) / 45.0).repeatForever(autoreverses: false)) {
                        offset = -(textWidth + 40)
                    }
                }
            } else {
                label
            }
        }
        .clipped()
    }

    private var label: some View {
        Text(text)
            .font(.system(size: 12, weight: .bold, design: .monospaced))
            .foregroundColor(waGreen)
            .lineLimit(1)
            .fixedSize()
    }
}

#Preview {
    PlayerView(isShowing: .constant(true))
        .environmentObject(AudioPlayer())
}
