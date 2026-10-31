import AVFoundation  // Apple's framework for audio/video playback (AVPlayer, AVPlayerItem, etc.)
import Combine       // Apple's reactive programming framework (not heavily used here, but imported for future)
import MediaPlayer   // Apple's framework for Control Center, lock screen, and AirPods integration
import SwiftUI       // Apple's UI framework (needed for @MainActor and ObservableObject)
import WidgetKit     // WidgetCenter.reloadTimelines, tells the Now Playing widget to redraw

// MARK: - Audio Player

/// Manages all audio playback in the app.
///
/// RESPONSIBILITIES:
/// - Play, pause, skip, seek songs using AVFoundation
/// - Manage a queue of songs with shuffle and repeat
/// - Show controls on lock screen and Control Center
/// - Support AirPlay and external playback
/// - Handle background audio (music continues when app is backgrounded)
///
/// ARCHITECTURE:
/// - @MainActor: All property changes happen on the main thread (required for UI updates)
/// - ObservableObject: Makes this class observable by SwiftUI views
/// - @Published: When these properties change, SwiftUI views automatically re-render
///
/// HOW VIEWS USE THIS:
/// Views get this via @EnvironmentObject, which means they can:
/// 1. Read properties like currentSong, state, progress
/// 2. Call methods like togglePlayPause(), playNext(), seek(to:)
/// 3. Automatically re-render when any @Published property changes
@MainActor
class AudioPlayer: ObservableObject {
    
    // MARK: - Published Properties (UI reads these)
    
    /// The song currently playing (nil = nothing playing).
    /// When this changes, the mini player and full player update automatically.
    @Published var currentSong: NowPlaying?
    
    /// Current playback state: .stopped, .loading, .playing, or .paused.
    /// The UI uses this to show play vs pause icons.
    @Published var state: PlayerState = .stopped

    /// Last playback failure, shown to the user as an alert instead
    /// of the old behavior: the UI sat at "playing" in silence when
    /// the stream turned out to be an error page.
    @Published var playbackError: String?
    
    /// Current playback position in seconds (e.g. 45.5 = 45.5 seconds into the song).
    /// Updated every 0.5 seconds by the time observer.
    @Published var currentTime: Double = 0
    
    /// Total duration of the current song in seconds (e.g. 225.0 = 3:45).
    @Published var duration: Double = 0
    
    /// Playback progress as a fraction (0.0 to 1.0).
    /// This is a COMPUTED property, it recalculates every time it's accessed.
    /// Used by progress bars and sliders to show playback position.
    /// Guard prevents division by zero when duration is 0.
    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }
    
    /// Whether shuffle mode is active.
    /// When toggled, the queue is shuffled (and current song stays at front).
    @Published var isShuffled: Bool = false
    
    /// Current repeat mode: .none (stop at end), .all (loop queue), .one (repeat song).
    @Published var repeatMode: RepeatMode = .none
    
    /// Current volume level (0.0 to 1.0).
    /// Controls the audio output volume. 0.0 = mute, 1.0 = maximum.
    @Published var volume: Double = 1.0
    
    /// The full queue of songs. The UI reads this for the queue screen.
    /// This is the source of truth, shuffle modifies this array.
    ///
    /// `didSet` persists the queue to disk on every change (see
    /// `saveQueueState()`), so it survives a relaunch, previously only
    /// recentlyPlayed/downloads/playlists did, and force-quitting mid-queue
    /// silently lost everything you'd lined up.
    @Published var queue: [NowPlaying] = [] {
        didSet { saveQueueState() }
    }

    /// Index of the currently playing song in the queue (-1 = nothing playing).
    /// Used to calculate "up next" songs and navigate forward/backward.
    @Published var currentIndex: Int = -1 {
        didSet { saveQueueState() }
    }
    
    /// Computed property: songs that come after the current song.
    /// Returns an empty array if nothing is playing or we're at the end.
    /// Used by QueueView to show the "Up Next" section.
    var upNext: [NowPlaying] {
        // Guard: check if currentIndex is valid and there are songs after it
        guard currentIndex >= 0 && currentIndex < queue.count - 1 else {
            return []
        }
        // Slice from currentIndex+1 to end, convert to Array
        return Array(queue[(currentIndex + 1)...])
    }

    /// Computed property: songs that came before the current song, in the
    /// order they'll be re-played if you step backward through them (most
    /// recently played first, i.e. reversed from queue order).
    ///
    /// This is the queue-position counterpart to `recentlyPlayed` (which
    /// tracks a separate, longer-lived history across the whole app rather
    /// than "what's behind me in THIS queue"). Used by QueueView's History
    /// section so users can see and jump back to songs they've already
    /// passed in the current queue.
    var history: [NowPlaying] {
        guard currentIndex > 0 && currentIndex <= queue.count else {
            return []
        }
        return Array(queue[0..<currentIndex]).reversed()
    }

    // MARK: - Private Properties (internal state)
    
    /// The AVPlayer that does the actual audio playback.
    /// Optional because there's no player when nothing is playing.
    /// AVPlayer handles buffering, decoding, and output to speakers.
    private var player: AVPlayer?
    
    /// The equalizer playback engine (nil when the EQ isn't in use).
    /// AVPlayer can't be equalized on iOS, so when the user enables the EQ
    /// and plays a LOCAL (downloaded) song, we play it through this engine
    /// instead, which routes audio through an AVAudioUnitEQ.
    /// See EqualizerEngine.swift for the full explanation.
    private var eqEngine: EqualizerEngine?
    
    /// Token returned by addPeriodicTimeObserver().
    /// We need to save this so we can remove the observer later.
    /// If we don't remove it, it leaks memory.
    /// Type is `Any?` because Apple's API returns an opaque token.
    private var timeObserverToken: Any?

    /// Whether the CURRENT song's listen session has already been reported
    /// to StatsManager (via `.songDidFinishPlaying`).
    ///
    /// WHY THIS EXISTS (reconciling PlayCountManager vs. StatsManager):
    /// Previously, StatsManager only ever learned about a song when it
    /// played through to its natural end, skip to the next track after 5
    /// seconds and StatsManager never heard about it at all, while
    /// PlayCountManager (which increments on every play START) counted it
    /// immediately. That gap meant StatsManager's "most played" data quietly
    /// under-counted anything users bail on, which is exactly the wrong bias
    /// for building recommendations from it.
    ///
    /// Now EVERY session, whether it ends naturally or gets skipped, is
    /// reported exactly once via `finalizeCurrentSession(wasSkipped:)`, with
    /// the ACTUAL elapsed listening time (`currentTime`, not the full song
    /// duration). This flag just prevents double-reporting: the natural-end
    /// path finalizes the session itself, then `stopPlayer()` runs right
    /// after (to tear down the player for the next song) and must not
    /// report the same session a second time as "skipped".
    private var sessionFinalized = true
    
    /// The original queue order before shuffling.
    /// When shuffle is turned off, we restore this exact order.
    private var savedQueueOrder: [NowPlaying] = []
    
    /// The timer that fires when the sleep timer expires.
    /// When it fires, playback pauses automatically.
    private var sleepTimer: Timer?

    /// The thumbnail URL whose artwork is currently cached in
    /// `cachedArtwork` below. Used by `updateNowPlayingInfo()` to skip
    /// redundant artwork fetches on every 0.5s time-observer tick, see the
    /// comment there for why this matters.
    private var lastArtworkThumbnailUrl: String?

    /// The `MPMediaItemArtwork` built from `lastArtworkThumbnailUrl`.
    /// Re-applied to every `nowPlayingInfo` update (not just the tick that
    /// fetched it) so lock-screen art doesn't flicker away, see
    /// `updateNowPlayingInfo()`.
    private var cachedArtwork: MPMediaItemArtwork?

    /// Identifies the last "song id + play/pause state" pushed to the
    /// Home Screen / Lock Screen widget via `updateWidgetSnapshot(song:)`.
    /// `updateNowPlayingInfo()` runs on every 0.5s progress tick (to keep
    /// the lock screen's elapsed time current), but the widget only needs
    /// a fresh App Group write + WidgetKit reload when the song or
    /// play/pause state actually changes, not every tick. Comparing
    /// against this key is what makes that skip possible.
    private var lastWidgetSnapshotKey: String?

    // MARK: - Sleep Timer
    
    /// Whether the sleep timer is active.
    /// When true, the UI shows a countdown and the timer icon is highlighted.
    @Published var isSleepTimerActive: Bool = false
    
    /// Seconds remaining until the sleep timer stops playback.
    /// Updated every second by the timer. When it reaches 0, playback pauses.
    @Published var sleepTimerRemaining: TimeInterval = 0

    /// Whether the active sleep timer is in "smart" mode, stop once the
    /// current queue (the album or playlist the user is listening to)
    /// finishes, rather than after a fixed duration.
    ///
    /// When this is true, `sleepTimerRemaining` is still kept updated every
    /// second for the countdown UI (see `updateQueueEndSleepTimerEstimate()`),
    /// but it's only an ESTIMATE, the actual stop condition, checked in
    /// `handleSongEnded()`, is queue position (currentIndex reaching the
    /// last item), not this countdown reaching zero. That estimate assumes
    /// every remaining track plays to completion at its full listed
    /// duration, which is usually right but can drift from reality (e.g.
    /// the user skips around), the real trigger never does.
    @Published private(set) var sleepTimerStopsAtQueueEnd: Bool = false

    /// The date when the sleep timer was started.
    /// Used to calculate remaining time even if the app is backgrounded.
    private var sleepTimerEndDate: Date?

    /// How many seconds before the sleep timer ends that the fade-out
    /// ramp begins. The ramp runs from full volume down to silent across
    /// this window, so playback eases to a stop instead of cutting off
    /// abruptly mid-note.
    private let sleepTimerFadeDuration: TimeInterval = 12

    /// The playback volume in effect right before the fade-out ramp
    /// started, so it can be restored once the sleep timer pauses playback
    /// (otherwise the NEXT song would start back up silently, since we
    /// ramped the actual player/engine volume down to 0 without touching
    /// the persisted `volume` property).
    private var volumeBeforeSleepFade: Double?
    
    // MARK: - Recently Played
    
    /// List of recently played songs (most recent first).
    /// Limited to 50 songs to avoid excessive memory usage.
    /// Persisted to disk so it survives app restarts.
    @Published var recentlyPlayed: [NowPlaying] = []
    
    /// Maximum number of songs to keep in history.
    private let maxRecentlyPlayed = 50
    
    /// File path for persisting recently played history.
    private let recentlyPlayedPath: URL

    // MARK: - Queue Persistence

    /// File path for persisting the current queue + position, so it
    /// survives a relaunch (force-quit or the OS terminating the app in
    /// the background). See `saveQueueState()`/`loadQueueState()`.
    private let queuePath: URL
    
    // MARK: - Crossfade
    
    /// Whether crossfade is enabled (read from UserDefaults/Settings).
    /// When true, songs overlap during transitions for smooth playback.
    @Published var isCrossfadeEnabled: Bool = false
    
    /// Duration of the crossfade in seconds (e.g. 5 = 5-second overlap).
    /// Both the outgoing and incoming songs play simultaneously during this time.
    @Published var crossfadeDuration: Double = 5.0
    
    /// Timer that manages the crossfade volume animation.
    /// Fires every 0.1 seconds to smoothly adjust both players' volumes.
    private var crossfadeTimer: Timer?
    
    // MARK: - Playback Speed
    
    /// Current playback speed/rate.
    /// 1.0 = normal speed, 0.5 = half speed, 2.0 = double speed.
    /// Stored in UserDefaults so the user's preference persists.
    @Published var playbackRate: Double = 1.0
    
    /// Set the playback speed for the current and future songs.
    /// Persists the setting and applies it immediately.
    func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
        UserDefaults.standard.set(rate, forKey: "playbackRate")
        // Apply immediately to the equalizer engine if it's active
        eqEngine?.setRate(rate)
        // Apply immediately to the current player
        player?.rate = Float(rate)
    }
    
    // MARK: - Types
    
    /// Repeat mode options for the player.
    enum RepeatMode {
        case none       // Stop after the current song ends
        case all        // When queue ends, loop back to the first song
        case one        // Repeat the current song indefinitely
    }
    
    // MARK: - Initialization
    
    /// Create the audio player and set up systems.
    /// Called once when the app starts (from YTMusicApp.swift).
    init() {
        // Set up the file path for recently played history
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.recentlyPlayedPath = documents.appendingPathComponent("recently_played.json")
        self.queuePath = documents.appendingPathComponent("queue_state.json")

        // Load crossfade settings from UserDefaults (saved by SettingsView)
        self.isCrossfadeEnabled = UserDefaults.standard.bool(forKey: "crossfadeEnabled")
        let savedDuration = UserDefaults.standard.double(forKey: "crossfadeDuration")
        self.crossfadeDuration = savedDuration > 0 ? savedDuration : 5.0
        
        // Load saved playback rate
        let savedRate = UserDefaults.standard.double(forKey: "playbackRate")
        self.playbackRate = savedRate > 0 ? savedRate : 1.0
        
        setupAudioSession()       // Configure audio for background playback
        setupRemoteCommandCenter() // Register for lock screen / AirPods controls
        loadRecentlyPlayed()      // Load history from disk
        loadQueueState()          // Restore the queue + position from the last session
    }
    
    // MARK: - Playback Controls
    
    /// Play a song immediately (clears the queue and plays just this song).
    ///
    /// This is the main entry point called by views when the user taps a song.
    /// It creates a NowPlaying object, sets up the queue with just this song,
    /// and starts playback.
    ///
    /// - Parameters:
    ///   - videoId: YouTube video ID (e.g. "dQw4w9WgXcQ")
    ///   - title: Song title
    ///   - artist: Artist name
    ///   - thumbnailUrl: URL to album art image
    ///   - audioUrl: Direct URL to the audio stream (obtained from player endpoint)
    ///   - duration: Song length in seconds
    func play(
        videoId: String,
        title: String,
        artist: String,
        thumbnailUrl: String,
        audioUrl: String,
        duration: Int
    ) async {
        // Create a NowPlaying object from the parameters
        let song = NowPlaying(
            id: videoId,
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            duration: duration,
            audioUrl: audioUrl
        )
        
        // Replace the queue with just this song and start playing
        queue = [song]
        currentIndex = 0
        
        await playSong(song)
    }
    
    /// Play a song from a local file (cached/downloaded).
    ///
    /// This is the same as play() but uses a local file URL instead of a streaming URL.
    /// Used for offline playback of downloaded songs.
    ///
    /// - Parameters:
    ///   - videoId: YouTube video ID
    ///   - title: Song title
    ///   - artist: Artist name
    ///   - thumbnailUrl: URL to album art
    ///   - localURL: Local file URL (in the app's Documents/Downloads directory)
    ///   - duration: Duration in seconds (0 if unknown, AVPlayer will detect it)
    func playLocal(
        videoId: String,
        title: String,
        artist: String,
        thumbnailUrl: String,
        localURL: URL,
        duration: Int
    ) async {
        let song = NowPlaying(
            id: videoId,
            title: title,
            artist: artist,
            thumbnailUrl: thumbnailUrl,
            duration: duration,
            audioUrl: localURL.absoluteString // Store the local URL as a string
        )
        
        queue = [song]
        currentIndex = 0
        
        // Play directly from the local file
        await playSongFromLocal(song, localURL: localURL)
    }
    
    /// Internal method: play a song from a local file URL.
    ///
    /// Same as playSong() but accepts a local file URL instead of a streaming URL.
    private func playSongFromLocal(_ song: NowPlaying, localURL: URL) async {
        stopPlayer()
        
        // If the equalizer is enabled, play through the EQ engine so the
        // 10-band equalizer actually processes the audio. AVPlayer cannot
        // be equalized on iOS, so this is the only path where EQ works.
        if let eq = EqualizerManager.shared, eq.isEnabled {
            startEQPlayback(song, localURL: localURL)
            return
        }
        
        // Create AVPlayerItem from local file (no network needed)
        let playerItem = AVPlayerItem(url: localURL)
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.allowsExternalPlayback = true
        
        // Set up a time observer so currentTime/duration stay in sync and
        // we detect when the song ends. This uses the SAME shared helper as
        // playSong() below, so every playback path (streamed, local,
        // crossfade) behaves identically, including posting the
        // songDidFinishPlaying notification used for scrobbling/stats.
        // (Previously this path built its own closure that skipped the
        // notification, that inconsistency is now fixed.)
        attachTimeObserver(to: newPlayer)

        self.player = newPlayer
        self.currentSong = song
        self.sessionFinalized = false
        self.state = .loading
        // For local files, get duration from the player item if we don't know it
        if duration == 0 {
            self.duration = playerItem.duration.seconds.isNaN ? 0 : playerItem.duration.seconds
        } else {
            self.duration = Double(song.duration)
        }
        self.currentTime = 0

        newPlayer.play()
        // Apply the current playback speed. (Previously this path never set
        // .rate, so locally-played songs silently ignored the playback
        // speed setting, fixed to match the streaming path below.)
        newPlayer.rate = Float(playbackRate)
        self.state = .playing
        updateNowPlayingInfo()
        // Track this song in recently played history
        addToRecentlyPlayed(song)
    }
    
    /// Play a local song through the equalizer engine.
    ///
    /// This is the ONLY path where the 10-band equalizer actually processes
    /// audio, because AVPlayer (the normal player) doesn't allow inserting
    /// an EQ node. It's used when the EQ is enabled and the song is local.
    ///
    /// The engine mirrors AudioPlayer's state (currentTime, duration, state)
    /// through callbacks so the rest of the app doesn't care which backend
    /// is playing.
    private func startEQPlayback(_ song: NowPlaying, localURL: URL) {
        // Stop any current AVPlayer playback first
        stopPlayer()
        
        // Create a fresh equalizer engine for this song
        let engine = EqualizerEngine()
        
        // Forward playback-position updates to the published currentTime,
        // so progress bars and Control Center stay in sync
        engine.onTimeUpdate = { [weak self] seconds in
            // The engine calls this on the main actor; hop to MainActor
            // to safely touch the published properties
            Task { @MainActor in
                guard let self = self else { return }
                self.currentTime = seconds
                self.updateNowPlayingInfo()
            }
        }
        
        // Forward "song finished" to the normal handler so the queue
        // advances (next song / repeat) exactly like AVPlayer playback
        engine.onSongEnded = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }
                self.handleSongEnded()
            }
        }
        
        // Keep a reference so pause/seek/volume/rate calls can reach it
        self.eqEngine = engine
        // Expose the song to the UI
        self.currentSong = song
        self.sessionFinalized = false
        // Show a brief loading state while the engine spins up
        self.state = .loading
        
        // Register a callback so EQ slider changes apply LIVE while playing.
        // EqualizerManager calls this whenever the user drags a slider or
        // taps a preset.
        EqualizerManager.shared?.onGainsChanged = { [weak self] gains in
            Task { @MainActor in
                self?.eqEngine?.setGains(gains)
            }
        }
        
        // Pull the current EQ settings to hand to the engine
        let gains = EqualizerManager.shared?.bandGains ?? Array(repeating: 0.0, count: 10)
        let frequencies = EqualizerManager.bandFrequencies
        
        // Start playback. The completion fires once the file is open and
        // playing, with the file's real duration in seconds.
        engine.playFile(
            url: localURL,
            rate: playbackRate,
            volume: volume,
            gains: gains,
            frequencies: frequencies
        ) { [weak self] duration in
            Task { @MainActor in
                guard let self = self else { return }
                // Use the real duration when the file reports one
                self.duration = duration > 0 ? duration : Double(song.duration)
                // Mark the player as playing
                self.state = .playing
                // Update Control Center / lock screen
                self.updateNowPlayingInfo()
                // Track this song in recently played history
                self.addToRecentlyPlayed(song)
            }
        }
    }
    /// Internal method: play a specific song from the queue.
    ///
    /// This does the heavy lifting:
    /// 1. Stops any current playback
    /// 2. Creates a new AVPlayer with the song's audio URL
    /// 3. Sets up a time observer to track playback position
    /// 4. Starts playback
    /// 5. Updates Control Center / lock screen info
    private func playSong(_ song: NowPlaying) async {
        // Step 1: Stop any current playback and clean up
        stopPlayer()
        
        // Step 2: Create the audio URL
        // `guard let` safely unwraps the optional URL(string:).
        // If the URL is invalid (shouldn't happen with our data), we log and return.
        guard let url = URL(string: song.audioUrl) else {
            print("Invalid audio URL: \(song.audioUrl)")
            return
        }
        
        // If the equalizer is enabled and this is a LOCAL file (a downloaded
        // song, queue navigation often replays local URLs), use the EQ engine.
        // This keeps the equalizer working when the queue advances to the
        // next downloaded song.
        if let eq = EqualizerManager.shared, eq.isEnabled, url.isFileURL {
            startEQPlayback(song, localURL: url)
            return
        }
        
        // Step 3: Create an AVPlayerItem (represents one audio track)
        let playerItem = AVPlayerItem(url: url)
        
        // Step 4: Create the AVPlayer (handles playback, buffering, output)
        let newPlayer = AVPlayer(playerItem: playerItem)
        newPlayer.allowsExternalPlayback = true  // Enable AirPlay output
        
        // Step 5: Set up a periodic time observer.
        // See attachTimeObserver(to:) below for the full explanation of
        // what this does and why, every playback path in this file shares
        // that one implementation so behavior stays consistent.
        attachTimeObserver(to: newPlayer)

        // Step 6: Update the player state
        self.player = newPlayer
        self.currentSong = song
        self.sessionFinalized = false
        self.state = .loading  // Brief loading state before playback starts
        self.duration = Double(song.duration) // Convert Int seconds to Double
        self.currentTime = 0   // Start at the beginning
        
        // Step 7: Start playback!
        newPlayer.play()
        // Apply current playback speed
        newPlayer.rate = Float(playbackRate)
        self.state = .playing
        
        // Step 8: Update Control Center / lock screen
        updateNowPlayingInfo()
        // Track this song in recently played history
        addToRecentlyPlayed(song)
    }
    
    /// Attach a periodic time observer to an AVPlayer and store its token.
    ///
    /// WHAT THIS DOES:
    /// Registers a callback that fires every 0.5 seconds while `player` is
    /// playing. The callback receives the current playback time and uses
    /// it to:
    ///   - Update currentTime (for progress bars and time labels)
    ///   - Update Now Playing info (for Control Center)
    ///   - Detect when the song ends (posting a notification, then
    ///     handing off to handleSongEnded() to advance the queue)
    ///
    /// WHY IT'S SHARED:
    /// Three different call sites need this exact same observer (normal
    /// streaming playback, local-file playback, and the "new" player during
    /// a crossfade). Previously each one duplicated this closure by hand,
    /// which had drifted out of sync, e.g. the local-file path forgot to
    /// post the songDidFinishPlaying notification. Having one shared
    /// implementation means every path behaves identically and future
    /// changes only need to happen in one place.
    ///
    /// - Parameter player: The AVPlayer to observe. Its token is saved into
    ///   `timeObserverToken` so `stopPlayer()` can remove it later.
    private func attachTimeObserver(to player: AVPlayer) {
        // CMTime = Core Media Time, Apple's way of representing time precisely.
        // `seconds: 0.5` = fire every 0.5 seconds
        // `preferredTimescale: 600` = time precision. 600 means times are accurate
        // to 1/600th of a second (about 1.67ms). Higher = more precise but more CPU.
        // 600 is a good balance for music playback.
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)

        // addPeriodicTimeObserver returns an opaque token we must save so
        // we can remove the observer later (see stopPlayer()), failing to
        // remove it would leak memory and keep firing after the player is
        // gone.
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main  // Run on the main thread (required for UI updates)
        ) { [weak self] time in
            // [weak self] = "don't keep a strong reference to self".
            // This prevents a RETAIN CYCLE (memory leak):
            //   AudioPlayer owns player → player's closure owns AudioPlayer → leak!
            // With [weak self], if AudioPlayer is deallocated, self becomes nil
            // instead of being kept alive forever by this closure.

            // The closure runs on a background thread, but we need to update
            // @Published properties on the main thread. Task { @MainActor in }
            // creates an async task that runs on the main actor (main thread).
            Task { @MainActor in
                // Guard: if self was deallocated, stop
                guard let self = self else { return }

                // Guard: during a crossfade, the OLD player's observer is
                // still alive (deliberately, until the fade animation
                // finishes and removes it) while `self.player`/`duration`/
                // `currentSong` have already been reassigned to the NEW
                // song. Without this check, the old player's own stale
                // ticks would overwrite currentTime/duration with the old
                // song's position, and could even re-trigger the "song
                // ended" branch below against the new song's (possibly
                // shorter) duration, firing handleSongEnded() a second
                // time mid-crossfade. Only the player currently assigned
                // to self.player is allowed to update shared state.
                guard player === self.player else { return }

                // Surface stream failures instead of sitting at
                // "playing" in silence: when the item fails (for
                // example YouTube served an error page instead of
                // audio), stop and report the error to the user.
                if let item = player.currentItem, item.status == .failed, self.playbackError == nil {
                    self.playbackError = item.error?.localizedDescription ?? "The stream could not be played."
                    player.pause()
                    self.state = .stopped
                }

                // Update the current playback position
                self.currentTime = time.seconds

                // Update Control Center / lock screen info
                self.updateNowPlayingInfo()

                // Check if the song has ended
                // `time.seconds >= self.duration` = we've reached the end
                // `self.duration > 0` = guard against duration being 0 (which would
                // cause an immediate "song ended" on playback start)
                if time.seconds >= self.duration && self.duration > 0 {
                    // Record listening stats before handling song end.
                    // `wasSkipped: false` because we only reach this branch
                    // when the song played all the way through naturally.
                    self.finalizeCurrentSession(wasSkipped: false)
                    self.handleSongEnded()
                }
            }
        }
    }

    /// Handle when a song ends naturally (not skipped by the user).
    ///
    /// The behavior depends on the current repeat mode:
    /// - .one: Replay the same song
    /// - .all or .none: Try to play the next song in the queue
    ///
    /// If crossfade is enabled and there's a next song, the transition
    /// overlaps both songs for a smooth fade instead of an abrupt cut.
    private func handleSongEnded() {
        // Smart sleep timer: if we've been asked to stop once the current
        // queue (album/playlist) finishes and this WAS the last song in
        // it, stop here, deliberately overriding repeatMode, since
        // looping (.all) or repeating (.one) here would mean the timer
        // never actually stops anything.
        if isSleepTimerActive, sleepTimerStopsAtQueueEnd, currentIndex >= queue.count - 1 {
            togglePlayPause()
            restoreVolumeAfterSleepFade()
            stopSleepTimer()
            return
        }

        switch repeatMode {
        case .one:
            // Repeat the current song, replay it from the beginning.
            // Guard instead of force-unwrapping: currentSong is normally set
            // whenever a song is ending, but this callback originates from
            // an AVPlayer/EqualizerEngine closure, so we don't want a crash
            // here if state ever changes out from under us mid-callback.
            guard let song = currentSong else { return }
            Task {
                await playSong(song)
            }
        case .all, .none:
            // Check if crossfade is enabled and there's a next song.
            // Crossfade is skipped when the equalizer engine is playing,
            // because crossfade is implemented with AVPlayer only.
            if isCrossfadeEnabled && eqEngine == nil && currentIndex < queue.count - 1 {
                // Start crossfade transition to next song
                performCrossfadeToNext()
            } else {
                // No crossfade, just play the next song normally
                playNext()
            }
        }
    }
    
    /// Perform a crossfade transition to the next song in the queue.
    ///
    /// HOW CROSSFADE WORKS:
    /// 1. Increment currentIndex to point to the next song
    /// 2. Create a NEW AVPlayer for the next song (don't touch the old one yet)
    /// 3. Start the new player at volume 0 (silent)
    /// 4. Animate: old player volume 1.0 → 0.0, new player volume 0.0 → 1.0
    /// 5. After the crossfade duration, remove the old player
    ///
    /// This creates a smooth overlap where both songs play simultaneously
    /// during the transition, like a DJ fading between tracks.
    private func performCrossfadeToNext() {
        // Move to the next song in the queue
        currentIndex += 1
        
        // Safety check: make sure we haven't gone past the end
        guard currentIndex < queue.count else {
            // At end of queue, stop playback
            state = .stopped
            currentSong = nil
            return
        }
        
        let nextSong = queue[currentIndex]
        
        // Create the audio URL for the next song
        guard let url = URL(string: nextSong.audioUrl) else {
            print("Invalid audio URL for crossfade: \(nextSong.audioUrl)")
            return
        }
        
        // Create a new player for the next song
        let nextPlayerItem = AVPlayerItem(url: url)
        let nextPlayer = AVPlayer(playerItem: nextPlayerItem)
        nextPlayer.allowsExternalPlayback = true
        nextPlayer.volume = 0 // Start silent
        
        // Start the next song playing (silently for now)
        nextPlayer.play()
        // Apply the current playback speed, same as every other playback path
        nextPlayer.rate = Float(playbackRate)

        // Save the old player for the crossfade
        guard let oldPlayer = self.player else {
            // No old player, just switch to the new one.
            // BUG FIX: this branch used to skip attaching a time observer
            // entirely, which meant currentTime would freeze and the song
            // would never be detected as "ended" (no auto-advance to the
            // next track) whenever crossfade fired with no previous player
            // to fade out. attachTimeObserver(to:) below fixes that by
            // wiring up the same observer every other path uses.
            attachTimeObserver(to: nextPlayer)
            self.player = nextPlayer
            self.currentSong = nextSong
            self.sessionFinalized = false
            self.state = .playing
            self.currentTime = 0
            self.duration = Double(nextSong.duration)
            updateNowPlayingInfo()
            addToRecentlyPlayed(nextSong)
            return
        }

        // Store old observer token to remove it later
        let oldToken = timeObserverToken

        // Set up a time observer for the new player, using the same shared
        // helper as every other playback path (see attachTimeObserver(to:)
        // above playSong() for the full explanation).
        attachTimeObserver(to: nextPlayer)

        // Update state to the new song
        self.player = nextPlayer
        self.currentSong = nextSong
        self.sessionFinalized = false
        self.state = .playing
        self.currentTime = 0
        self.duration = Double(nextSong.duration)
        updateNowPlayingInfo()
        addToRecentlyPlayed(nextSong)

        // Perform the crossfade animation
        // Animate volume from 0→1 on new player, 1→0 on old player
        let fadeSteps = 50 // Number of animation steps (0.1s intervals over 5s)
        let stepDuration = crossfadeDuration / Double(fadeSteps)
        
        crossfadeTimer = Timer.scheduledTimer(withTimeInterval: stepDuration, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                
                // Calculate progress (0.0 → 1.0)
                let progress = self.crossfadeProgress
                self.crossfadeProgress += (1.0 / Double(fadeSteps))
                
                if progress >= 1.0 {
                    // Crossfade complete, clean up
                    timer.invalidate()
                    self.crossfadeTimer = nil
                    self.crossfadeProgress = 0
                    
                    // Remove the old player and its observer
                    if let oldToken = oldToken {
                        oldPlayer.removeTimeObserver(oldToken)
                    }
                    oldPlayer.pause()
                } else {
                    // Animate volumes
                    // New player fades IN: 0.0 → 1.0
                    nextPlayer.volume = Float(progress)
                    // Old player fades OUT: 1.0 → 0.0
                    oldPlayer.volume = Float(1.0 - progress)
                }
            }
        }
    }
    
    /// Progress of the current crossfade (0.0 to 1.0).
    /// Used to animate volume levels during the transition.
    private var crossfadeProgress: Double = 0
    
    /// Toggle between play and pause.
    ///
    /// If playing → pause. If paused → play. If stopped → do nothing.
    func togglePlayPause() {
        // If the equalizer engine is active, toggle THAT instead of AVPlayer
        if let eq = eqEngine {
            if state == .playing {
                eq.pause()
                state = .paused
            } else if state == .paused {
                eq.resume()
                state = .playing
            }
            // Update Control Center with new state
            updateNowPlayingInfo()
            return
        }
        
        guard let player = player else {
            // No active AVPlayer, this happens right after launch when a
            // queue was restored from disk (see loadQueueState()) but
            // nothing has actually started playing yet. Start it now
            // instead of silently doing nothing.
            resumeFromRestoredQueueIfNeeded()
            return
        }

        if state == .playing {
            player.pause()
            state = .paused
        } else if state == .paused {
            player.play()
            state = .playing
        }
        // Update Control Center with new state
        updateNowPlayingInfo()
    }
    
    /// Report the current song's listen session to StatsManager exactly once,
    /// whether it ended naturally or is being cut short by a skip/stop.
    ///
    /// PART OF RECONCILING PlayCountManager vs. StatsManager: PlayCountManager
    /// still counts every play START (used for the lightweight "Most Played"
    /// badge on Home), but StatsManager now hears about the REAL outcome of
    /// every session, how long the user actually listened, and whether they
    /// bailed, which is the signal that matters for recommendations (see
    /// StatsManager's `mostPlayedSongs`, `onRepeatSongs`, and `skipCounts`).
    ///
    /// - Parameter wasSkipped: `false` when the song reached its natural end;
    ///   `true` when it's being interrupted (skip, stop, or switching to a
    ///   different song before this one finished).
    private func finalizeCurrentSession(wasSkipped: Bool) {
        // Guard against double-reporting: the natural-end path calls this
        // itself, and `stopPlayer()` (called right after, to tear down for
        // the next song) must not report the same session again.
        guard !sessionFinalized, let song = currentSong, currentTime > 0 else { return }
        sessionFinalized = true

        NotificationCenter.default.post(
            name: .songDidFinishPlaying,
            object: nil,
            userInfo: [
                "videoId": song.id,
                "title": song.title,
                "artist": song.artist,
                // Actual elapsed listening time, NOT the full song duration,
                // this is what makes skipped sessions honestly reported as
                // "listened to 8 of 200 seconds" instead of not reported at all.
                "durationPlayed": currentTime,
                "wasSkipped": wasSkipped
            ]
        )

        // Skip-tracking as its own first-class signal (separate from the
        // general listen-session event above) so future recommendation
        // logic can specifically down-weight songs users bail on, without
        // having to re-derive "was this a skip" from the combined event.
        if wasSkipped {
            NotificationCenter.default.post(
                name: .songWasSkipped,
                object: nil,
                userInfo: [
                    "videoId": song.id,
                    "title": song.title,
                    "artist": song.artist,
                    "afterSeconds": currentTime
                ]
            )
        }
    }

    /// Stop playback and clean up the AVPlayer.
    ///
    /// This is called internally before starting a new song.
    /// It removes the time observer, pauses the player, and resets state.
    private func stopPlayer() {
        // If the outgoing song's session hasn't been reported yet (i.e. it
        // didn't reach its natural end), report it now as a skip before we
        // reset currentTime/duration below.
        finalizeCurrentSession(wasSkipped: true)

        // Stop the equalizer engine too (if it's active)
        eqEngine?.stop()
        eqEngine = nil

        // Cancel any in-flight crossfade. Without this, skipping to a new
        // song while a crossfade is mid-animation leaves the old
        // crossfadeTimer running in the background, it keeps firing every
        // ~0.1s and mutating volumes on players that are no longer part of
        // the active playback state.
        crossfadeTimer?.invalidate()
        crossfadeTimer = nil
        crossfadeProgress = 0

        // Remove the time observer to prevent memory leaks
        if let token = timeObserverToken {
            player?.removeTimeObserver(token)
            timeObserverToken = nil
        }

        // Pause and discard the player
        player?.pause()
        player = nil
        state = .stopped
        currentTime = 0
        duration = 0
    }
    
    /// Stop and clear everything (current song, queue, state).
    ///
    /// Used when the user explicitly stops playback or queue is empty.
    func stop() {
        stopPlayer()
        currentSong = nil
        queue = []
        currentIndex = -1
    }
    
    /// Seek to a specific position in the song.
    ///
    /// - Parameter progress: Position as a fraction (0.0 = start, 1.0 = end)
    ///
    /// HOW IT WORKS:
    /// Converts the fraction to seconds (duration × progress),
    /// then tells AVPlayer to jump to that time.
    func seek(to progress: Double) {
        // If the equalizer engine is active, seek IT instead of AVPlayer
        if let eq = eqEngine {
            let targetSeconds = duration * progress
            eq.seek(toSeconds: targetSeconds)
            currentTime = targetSeconds
            return
        }
        
        guard let player = player else { return }
        
        // Convert fraction to seconds and create a CMTime
        // preferredTimescale: 600 = same precision as the time observer
        let targetTime = CMTime(seconds: duration * progress, preferredTimescale: 600)
        player.seek(to: targetTime)
        currentTime = duration * progress
    }
    
    /// Seek to a specific time in seconds.
    ///
    /// Unlike seek(to:) which takes a progress fraction (0.0-1.0),
    /// this method takes an absolute time in seconds.
    /// Used by lyrics tap-to-seek to jump to a specific timestamp.
    func seekToTime(_ seconds: Double) {
        // If the equalizer engine is active, seek IT instead of AVPlayer
        if let eq = eqEngine {
            eq.seek(toSeconds: seconds)
            currentTime = seconds
            return
        }
        
        guard let player = player else { return }
        
        let targetTime = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: targetTime)
        currentTime = seconds
    }
    
    /// Skip forward 15 seconds.
    ///
    /// `min()` ensures we don't go past the end of the song.
    func skipForward() {
        // If the equalizer engine is active, skip IT instead of AVPlayer
        if let eq = eqEngine {
            let newTime = min(currentTime + 15, duration) // Cap at song duration
            eq.seek(toSeconds: newTime)
            currentTime = newTime
            return
        }
        
        guard let player = player else { return }
        
        let newTime = min(currentTime + 15, duration) // Cap at song duration
        let targetTime = CMTime(seconds: newTime, preferredTimescale: 600)
        player.seek(to: targetTime)
        currentTime = newTime
    }
    
    /// Skip backward 15 seconds.
    ///
    /// `max()` ensures we don't go below 0 seconds.
    func skipBackward() {
        // If the equalizer engine is active, skip IT instead of AVPlayer
        if let eq = eqEngine {
            let newTime = max(currentTime - 15, 0) // Floor at 0 seconds
            eq.seek(toSeconds: newTime)
            currentTime = newTime
            return
        }
        
        guard let player = player else { return }
        
        let newTime = max(currentTime - 15, 0) // Floor at 0 seconds
        let targetTime = CMTime(seconds: newTime, preferredTimescale: 600)
        player.seek(to: targetTime)
        currentTime = newTime
    }
    
    /// Set the audio output volume.
    ///
    /// - Parameter level: Volume from 0.0 (mute) to 1.0 (maximum)
    ///
    /// This affects the AVPlayer's volume property, which controls
    /// the actual audio output. The UI reads `volume` to show the
    /// slider position.
    func setVolume(_ level: Double) {
        // Clamp the value to 0.0...1.0 to prevent invalid values
        let clamped = min(max(level, 0), 1)
        volume = clamped
        // Apply to the equalizer engine if it's active
        eqEngine?.setVolume(clamped)
        // Apply to the actual AVPlayer
        player?.volume = Float(clamped)
    }
    
    // MARK: - Queue Navigation
    
    /// Play the next song in the queue.
    ///
    /// BEHAVIOR:
    /// - If there's a next song → play it
    /// - If at end of queue and repeat is .all → loop to the first song
    /// - If at end of queue and repeat is .none → stop playback
    func playNext() {
        guard !queue.isEmpty else { return }
        
        let nextIndex = currentIndex + 1
        
        if nextIndex < queue.count {
            // There's a next song, play it
            currentIndex = nextIndex
            Task {
                await playSong(queue[currentIndex])
            }
        } else if repeatMode == .all {
            // End of queue but repeat all is on, loop back to start
            currentIndex = 0
            Task {
                await playSong(queue[currentIndex])
            }
        } else {
            // End of queue, no repeat, stop
            stop()
        }
    }
    
    /// Play the previous song in the queue.
    ///
    /// SMART BEHAVIOR:
    /// - If more than 3 seconds into the song → restart current song (like YouTube)
    /// - If less than 3 seconds → go to previous song
    /// - If at the very beginning → restart current song
    func playPrevious() {
        // If user is more than 3 seconds in, restart instead of going back
        if currentTime > 3 {
            seek(to: 0)
            return
        }
        
        guard currentIndex > 0 else {
            // At the beginning of the queue, restart current song
            seek(to: 0)
            return
        }
        
        // Go to the previous song
        currentIndex -= 1
        Task {
            await playSong(queue[currentIndex])
        }
    }
    
    /// Jump back to a song already played earlier in the current queue
    /// (i.e. a song from `history`), without disturbing the rest of the
    /// queue, everything between it and the current song simply becomes
    /// "up next" again, the same way stepping backward one song at a time
    /// via `playPrevious()` would, just in one hop.
    ///
    /// - Parameter index: The song's position in the FULL queue array (not
    ///   the reversed `history` slice, callers map from a history-relative
    ///   index the same way QueueView already maps `upNext`-relative
    ///   indices back to the full queue).
    func playFromHistory(at index: Int) {
        guard index >= 0 && index < currentIndex else { return }
        currentIndex = index
        Task {
            await playSong(queue[currentIndex])
        }
    }

    // MARK: - Queue Management

    /// Add a song to the end of the queue and start playing it immediately.
    func addToQueueAndPlay(_ song: NowPlaying) {
        queue.append(song)
        currentIndex = queue.count - 1
        Task {
            // Donate a Siri Shortcut for this song so Siri can learn play patterns
            SiriShortcutsManager.donatePlaySong(
                title: song.title,
                artist: song.artist,
                videoId: song.id
            )
            await playSong(song)
        }
    }
    
    /// Replace the entire queue with a list of songs and start playing.
    ///
    /// - Parameters:
    ///   - songs: The new queue
    ///   - index: Which song to start playing (default: first song)
    func playAll(_ songs: [NowPlaying], startAt index: Int = 0) {
        queue = songs
        currentIndex = min(index, songs.count - 1)
        Task {
            // Donate resume shortcut, Siri learns "Resume my music"
            SiriShortcutsManager.donateResumePlayback()
            await playSong(queue[currentIndex])
        }
    }
    
    /// Add a song to the END of the queue (plays after all current songs).
    func addToQueue(_ song: NowPlaying) {
        queue.append(song)
    }
    
    /// Add a song to play NEXT (insert right after the current song).
    ///
    /// If current index is 2, the new song goes at index 3.
    /// All songs after it shift down by one position.
    func playNext(_ song: NowPlaying) {
        let insertIndex = currentIndex + 1
        queue.insert(song, at: insertIndex)
    }
    
    /// Remove a song from the queue at a specific index.
    ///
    /// IMPORTANT: After removal, we must adjust currentIndex because
    /// the indices shifted. Three cases:
    ///
    /// 1. Removed song was BEFORE current → current index shifts down by 1
    /// 2. Removed song IS the current song → play the next one (or stop)
    /// 3. Removed song was AFTER current → no adjustment needed
    func removeFromQueue(at index: Int) {
        // Bounds check, don't crash on invalid indices
        guard index >= 0 && index < queue.count else { return }
        
        queue.remove(at: index)
        
        if index < currentIndex {
            // Case 1: Removed a song before the current one
            // Current song's index shifted down by 1
            currentIndex -= 1
        } else if index == currentIndex {
            // Case 2: Removed the currently playing song
            if queue.isEmpty {
                // Queue is empty, stop everything
                stop()
            } else {
                // Play the song at the same index (which is now the next song)
                // `min()` prevents crash if currentIndex is now past the end
                currentIndex = min(currentIndex, queue.count - 1)
                Task {
                    await playSong(queue[currentIndex])
                }
            }
        }
        // Case 3: Removed a song after current, no adjustment needed
    }
    
    /// Move a song within the queue (for drag-to-reorder).
    ///
    /// After moving, we find the currently playing song's new position
    /// and update currentIndex to match.
    func moveQueue(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
        
        // Find where the current song ended up after the move
        if let currentSong = currentSong,
           let newIndex = queue.firstIndex(where: { $0.id == currentSong.id }) {
            currentIndex = newIndex
        }
    }
    
    /// Clear the queue but keep the currently playing song.
    ///
    /// If nothing is playing, clears everything.
    /// If something is playing, keeps just that one song.
    func clearQueue() {
        let currentSong = self.currentSong
        // `map { [$0] }` wraps the optional in an array: Optional<Song> → Array<Song>
        // `?? []` provides a fallback if currentSong is nil
        queue = currentSong.map { [$0] } ?? []
        currentIndex = currentSong != nil ? 0 : -1
    }
    
    // MARK: - Shuffle
    
    /// Toggle shuffle on/off.
    ///
    /// HOW SHUFFLE WORKS:
    /// 1. Save the original queue order (so we can restore it later)
    /// 2. Shuffle the queue randomly
    /// 3. Move the currently playing song to position 0
    /// 4. When shuffle is turned off, restore the saved order
    func toggleShuffle() {
        isShuffled.toggle()
        
        if isShuffled {
            // ── SHUFFLE ON ──────────────────────────────────────
            // Save the current (ordered) queue so we can restore it later
            savedQueueOrder = queue
            
            // Shuffle the queue randomly
            var newQueue = queue.shuffled()
            
            // Move the currently playing song to the front
            // (so it doesn't interrupt mid-song)
            if let current = currentSong,
               let currentIndex = newQueue.firstIndex(where: { $0.id == current.id }) {
                newQueue.remove(at: currentIndex) // Remove from random position
                newQueue.insert(current, at: 0)   // Insert at front
            }
            
            queue = newQueue
            currentIndex = currentSong != nil ? 0 : -1
        } else {
            // ── SHUFFLE OFF ─────────────────────────────────────
            // Restore the original order
            let currentSong = self.currentSong
            queue = savedQueueOrder
            
            // Find the current song's position in the restored order
            if let current = currentSong,
               let newIndex = queue.firstIndex(where: { $0.id == current.id }) {
                currentIndex = newIndex
            }
        }
    }
    
    /// Cycle through repeat modes: none → all → one → none
    func toggleRepeat() {
        switch repeatMode {
        case .none:
            repeatMode = .all
        case .all:
            repeatMode = .one
        case .one:
            repeatMode = .none
        }
    }
    
    // MARK: - Sleep Timer
    
    /// Start a sleep timer that pauses playback after the given duration.
    ///
    /// - Parameter duration: Time in seconds until playback pauses
    ///   (e.g. 900 = 15 minutes, 1800 = 30 minutes, 3600 = 1 hour)
    ///
    /// HOW IT WORKS:
    /// 1. Records the end date (current time + duration)
    /// 2. Starts a 1-second timer that updates the countdown display
    /// 3. When the timer fires and time is up, pauses playback
    /// 4. The end date survives backgrounding, if the app is killed,
    ///    we can recalculate remaining time on relaunch
    func startSleepTimer(duration: TimeInterval) {
        // Cancel any existing timer first
        stopSleepTimer()

        // Calculate when the timer should fire
        sleepTimerEndDate = Date().addingTimeInterval(duration)
        sleepTimerRemaining = duration
        isSleepTimerActive = true

        // Start a 1-second timer to update the countdown display
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self, let endDate = self.sleepTimerEndDate else { return }

                // Calculate remaining time from the end date (not from a counter)
                // This is more accurate because it accounts for timer drift
                let remaining = endDate.timeIntervalSinceNow

                if remaining <= 0 {
                    // Timer expired, pause playback.
                    // togglePlayPause() pauses since a song is playing.
                    self.togglePlayPause()
                    // Restore full volume so the NEXT time the user presses
                    // play (this song or another), it isn't silent, see
                    // the fade-out ramp below, which lowers the actual
                    // player/engine volume without touching `self.volume`.
                    self.restoreVolumeAfterSleepFade()
                    self.stopSleepTimer()
                } else {
                    // Update the countdown display
                    self.sleepTimerRemaining = remaining
                    // Fade out: once we're within `sleepTimerFadeDuration`
                    // seconds of the timer ending, ease the volume down to
                    // silent instead of letting playback cut off abruptly.
                    self.applySleepFade(remaining: remaining)
                }
            }
        }
    }

    /// Ramp playback volume down as the sleep timer approaches zero.
    ///
    /// Called every second from the sleep timer's tick handler. Does
    /// nothing until `remaining` enters the last `sleepTimerFadeDuration`
    /// seconds, at which point it linearly scales the CURRENT player/engine
    /// volume down to silent by the time `remaining` reaches 0, without
    /// touching the published `volume` property (and therefore without
    /// moving the user-visible volume slider or being un-done by anything
    /// that reads `volume` elsewhere).
    private func applySleepFade(remaining: TimeInterval) {
        guard remaining <= sleepTimerFadeDuration else { return }

        // Remember the volume we're fading FROM, the first time we enter
        // the fade window, so the ramp is always relative to what the user
        // actually had it set to (not always starting from 1.0).
        if volumeBeforeSleepFade == nil {
            volumeBeforeSleepFade = volume
        }
        let baseVolume = volumeBeforeSleepFade ?? volume

        // `fraction` goes from ~1.0 (just entered the fade window) down to
        // 0.0 (timer about to fire). Clamped to 0 as a safety net against
        // any floating-point overshoot right at the boundary.
        let fraction = max(0, remaining / sleepTimerFadeDuration)
        let fadedVolume = Float(baseVolume * fraction)

        // Apply directly to whichever backend is actually playing, same
        // split AudioPlayer uses everywhere else (EQ engine for local
        // playback with the equalizer on, AVPlayer otherwise).
        if let eq = eqEngine {
            eq.setVolume(Double(fadedVolume))
        } else {
            player?.volume = fadedVolume
        }
    }

    /// Undo `applySleepFade`'s ramp once the sleep timer actually pauses
    /// playback, so the player/engine is back at the user's real volume
    /// level for whenever they resume.
    private func restoreVolumeAfterSleepFade() {
        guard let restoredVolume = volumeBeforeSleepFade else { return }
        if let eq = eqEngine {
            eq.setVolume(restoredVolume)
        } else {
            player?.volume = Float(restoredVolume)
        }
        volumeBeforeSleepFade = nil
    }
    
    /// Cancel the sleep timer without pausing playback.
    ///
    /// Used when the user manually dismisses the timer or starts a new one.
    func stopSleepTimer() {
        sleepTimer?.invalidate()
        sleepTimer = nil
        sleepTimerEndDate = nil
        sleepTimerRemaining = 0
        isSleepTimerActive = false
        sleepTimerStopsAtQueueEnd = false
        // If the user cancels the timer WHILE it was mid-fade (e.g. they
        // started a new timer or tapped Cancel during the last 12 seconds),
        // restore full volume immediately rather than leaving playback
        // stuck at whatever faded-down level it was ramping through.
        restoreVolumeAfterSleepFade()
    }

    /// Set a preset sleep timer (15, 30, 45, or 60 minutes).
    ///
    /// - Parameter minutes: Duration in minutes
    func setSleepTimer(minutes: Int) {
        startSleepTimer(duration: TimeInterval(minutes * 60))
    }

    /// Start a "smart" sleep timer that stops playback once the current
    /// queue, e.g. the album or playlist the user is listening to,
    /// finishes, instead of after a fixed duration.
    ///
    /// Unlike `startSleepTimer(duration:)`, there's no fixed end date to
    /// count down to. Instead, `handleSongEnded()` checks
    /// `sleepTimerStopsAtQueueEnd` every time a song finishes and, once
    /// we're on the LAST song in `queue`, pauses right there instead of
    /// advancing, even overriding `repeatMode` (`.all` would otherwise
    /// loop back to the start, `.one` would otherwise repeat the last
    /// song forever, both of which would mean the timer never actually
    /// stops anything).
    ///
    /// Does nothing if there's no current song to anchor the estimate to.
    func startSleepTimerAtEndOfQueue() {
        // Cancel any existing timer first, same as the duration-based path.
        stopSleepTimer()

        guard currentIndex >= 0, currentIndex < queue.count else { return }

        sleepTimerStopsAtQueueEnd = true
        isSleepTimerActive = true
        updateQueueEndSleepTimerEstimate()

        // Runs once a second purely to keep the countdown UI (and the
        // final fade-out) current, the actual stop is driven by queue
        // position in `handleSongEnded()`, not by this timer reaching zero.
        sleepTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.updateQueueEndSleepTimerEstimate()
                self.applySleepFade(remaining: self.sleepTimerRemaining)
            }
        }
    }

    /// Recompute `sleepTimerRemaining` for the "stop at end of queue" mode:
    /// however much time is left in the current song, plus the full listed
    /// duration of every song still queued after it.
    ///
    /// This is a display estimate only (see the doc comment on
    /// `sleepTimerStopsAtQueueEnd`), it assumes the rest of the queue
    /// plays straight through, which is the common case but not guaranteed.
    private func updateQueueEndSleepTimerEstimate() {
        guard currentIndex >= 0, currentIndex < queue.count else {
            sleepTimerRemaining = 0
            return
        }

        let remainingInCurrentSong = max(0, duration - currentTime)

        let upcomingSongs = currentIndex + 1 < queue.count
            ? queue[(currentIndex + 1)...]
            : ArraySlice<NowPlaying>()
        let remainingInUpcomingSongs = upcomingSongs.reduce(0.0) { $0 + Double($1.duration) }

        sleepTimerRemaining = remainingInCurrentSong + remainingInUpcomingSongs
    }

    // MARK: - Recently Played
    
    /// Add a song to the recently played history.
    ///
    /// Called automatically when a song starts playing.
    /// Moves the song to the top if it's already in the list (no duplicates).
    /// Limited to 50 songs to avoid excessive memory usage.
    private func addToRecentlyPlayed(_ song: NowPlaying) {
        // Remove the song if it's already in the list (to avoid duplicates)
        recentlyPlayed.removeAll { $0.id == song.id }
        
        // Add to the beginning (most recent first)
        recentlyPlayed.insert(song, at: 0)
        
        // Trim to max size
        if recentlyPlayed.count > maxRecentlyPlayed {
            recentlyPlayed = Array(recentlyPlayed.prefix(maxRecentlyPlayed))
        }
        
        // Save to disk
        saveRecentlyPlayed()
        
        // Track play count for statistics
        PlayCountManager.shared?.recordPlay(videoId: song.id)
    }
    
    /// Save recently played history to disk.
    ///
    /// Persists as a JSON file in the Documents directory so history
    /// survives app restarts.
    private func saveRecentlyPlayed() {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(recentlyPlayed)
            try data.write(to: recentlyPlayedPath)
        } catch {
            print("Failed to save recently played: \(error)")
        }
    }
    
    /// Load recently played history from disk.
    ///
    /// Called on init to populate the history list.
    private func loadRecentlyPlayed() {
        guard FileManager.default.fileExists(atPath: recentlyPlayedPath.path) else {
            return
        }
        
        do {
            let data = try Data(contentsOf: recentlyPlayedPath)
            recentlyPlayed = try JSONDecoder().decode([NowPlaying].self, from: data)
        } catch {
            print("Failed to load recently played: \(error)")
            recentlyPlayed = []
        }
    }
    
    // MARK: - Queue Persistence

    /// On-disk shape for the persisted queue: the songs plus which one was
    /// playing. A separate small struct (rather than reusing NowPlaying)
    /// because we need to bundle `currentIndex` alongside the song array.
    private struct PersistedQueueState: Codable {
        let songs: [NowPlaying]
        let currentIndex: Int
    }

    /// Save the current queue + position to disk.
    ///
    /// Called automatically by `queue`/`currentIndex`'s `didSet` observers,
    /// so every mutation (play, skip, reorder, shuffle, clear) keeps the
    /// on-disk copy in sync without every call site needing to remember to
    /// save explicitly.
    private func saveQueueState() {
        do {
            let state = PersistedQueueState(songs: queue, currentIndex: currentIndex)
            let data = try JSONEncoder().encode(state)
            try data.write(to: queuePath)
        } catch {
            print("Failed to save queue state: \(error)")
        }
    }

    /// Restore the queue + position from disk on launch.
    ///
    /// IMPORTANT LIMITATION: this restores the queue's METADATA (titles,
    /// artwork, position) and shows it immediately in the mini player, but
    /// does NOT start playback, YouTube's streaming URLs expire a few
    /// hours after they're issued (see the same limitation documented on
    /// OfflineManager), so a `NowPlaying.audioUrl` saved from a previous
    /// session may no longer be playable. Playback only actually starts
    /// lazily, the first time the user presses Play, see
    /// `resumeFromRestoredQueueIfNeeded()`, called from `togglePlayPause()`.
    /// Downloaded (local file) songs don't have this problem, since their
    /// `audioUrl` is a stable file:// URL rather than a temporary stream.
    private func loadQueueState() {
        guard FileManager.default.fileExists(atPath: queuePath.path) else { return }

        do {
            let data = try Data(contentsOf: queuePath)
            // Named `persisted` (not `state`) to avoid shadowing this
            // class's own `state: PlayerState` property below.
            let persisted = try JSONDecoder().decode(PersistedQueueState.self, from: data)
            guard !persisted.songs.isEmpty,
                  persisted.currentIndex >= 0,
                  persisted.currentIndex < persisted.songs.count else {
                return
            }

            queue = persisted.songs
            currentIndex = persisted.currentIndex

            // Show the restored song in the mini player / lock screen right
            // away, without touching `player`/`eqEngine`, actual playback
            // is deferred until the user taps Play (see the limitation
            // note above).
            let song = persisted.songs[persisted.currentIndex]
            currentSong = song
            duration = Double(song.duration)
            currentTime = 0
            state = .stopped
            updateNowPlayingInfo()
        } catch {
            print("Failed to load queue state: \(error)")
        }
    }

    /// If the queue/currentSong were restored from disk on launch but
    /// nothing has actually started playing yet (no AVPlayer or EQ engine
    /// running), start playback now. Called from `togglePlayPause()` so
    /// pressing Play on a freshly-launched app (with a restored queue)
    /// works exactly like pressing Play normally, instead of silently
    /// doing nothing because `player` is nil.
    private func resumeFromRestoredQueueIfNeeded() {
        guard player == nil, eqEngine == nil, let song = currentSong else { return }

        if let url = URL(string: song.audioUrl), url.isFileURL {
            // Downloaded song, the file:// URL is still valid.
            Task { await playSongFromLocal(song, localURL: url) }
        } else {
            // Streamed song, the URL may have expired since the last
            // session (see the limitation note on loadQueueState()).
            // playSong() will simply fail to load if so; there's no
            // existing error-surfacing path for playback failures in this
            // file today, so this matches how every other failed-load case
            // here already behaves.
            Task { await playSong(song) }
        }
    }

    // MARK: - Audio Session Setup
    
    /// Configure the audio session for background playback.
    ///
    /// WHY THIS IS NEEDED:
    /// By default, iOS stops audio when the app is backgrounded or when
    /// the silent mode switch is on. This configures the audio session to:
    /// - Continue playing when the app is in the background
    /// - Play even when the silent switch is set to silent
    /// - Mix with other audio (like GPS directions) instead of pausing it
    private func setupAudioSession() {
        do {
            // Get the shared audio session (one per app)
            let session = AVAudioSession.sharedInstance()
            
            // .playback = play audio even when silent switch is on
            // .mixWithOthers = don't pause other apps' audio (e.g. GPS)
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.mixWithOthers]
            )
            
            // Activate the session (must be active for audio to play)
            try session.setActive(true)
        } catch {
            print("Failed to set up audio session: \(error)")
        }
    }
    
    // MARK: - Remote Command Center
    
    /// Set up lock screen, Control Center, and AirPods button handlers.
    ///
    /// WHAT THIS DOES:
    /// Registers handlers for hardware/software buttons:
    /// - Lock screen play/pause/skip buttons
    /// - Control Center music widget
    /// - AirPods tap gestures (play/pause, next, previous)
    /// - CarPlay controls
    ///
    /// [weak self] prevents memory leaks (same reason as in playSong).
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        
        // Play button (from lock screen, AirPods, etc.)
        commandCenter.playCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success // Tell the system the command was handled
        }
        
        // Pause button
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        
        // Toggle play/pause (single button that switches between play/pause)
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.togglePlayPause()
            return .success
        }
        
        // Next track button (double-tap AirPods, lock screen next button)
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            self?.playNext()
            return .success
        }
        
        // Previous track button
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            self?.playPrevious()
            return .success
        }
        
        // Scrubbing (dragging the progress bar on lock screen / Control Center).
        // The handler receives a generic MPRemoteCommandEvent, so we cast it
        // to MPChangePlaybackPositionCommandEvent to read positionTime
        // (the time the user dragged to, in seconds).
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            // Cast the generic event to the concrete scrubbing event
            guard let position = event as? MPChangePlaybackPositionCommandEvent else {
                // If the cast fails, ignore the command
                return .commandFailed
            }
            // Convert absolute time to a fraction (0.0-1.0) for our seek method
            self?.seek(to: position.positionTime / (self?.duration ?? 1))
            return .success
        }

        // Skip forward/backward ±15s (lock screen, AirPods, CarPlay
        // "±15 seconds" buttons). Previously only next/previous TRACK and
        // scrubbing were wired up here, even though the in-app player
        // already supports 15s skip via skipForward()/skipBackward(),
        // this brings the lock screen up to parity with the in-app UI.
        // `preferredIntervals` tells the system which interval(s) to show
        // on the button itself (e.g. "15" printed on the skip icon).
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.preferredIntervals = [15]
        commandCenter.skipForwardCommand.addTarget { [weak self] _ in
            self?.skipForward()
            return .success
        }

        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipBackwardCommand.preferredIntervals = [15]
        commandCenter.skipBackwardCommand.addTarget { [weak self] _ in
            self?.skipBackward()
            return .success
        }

        // Like / dislike (shown on the lock screen and CarPlay as
        // thumbs-up/thumbs-down). We only have a "liked" concept in this
        // app (see LikedSongsManager), not a separate "disliked" list, so:
        // - "like" toggles the current song's liked state
        // - "dislike" un-likes it if it was liked (there's nothing further
        //   to record otherwise)
        commandCenter.likeCommand.isEnabled = true
        commandCenter.likeCommand.localizedTitle = "Like"
        commandCenter.likeCommand.addTarget { [weak self] _ in
            guard let self, let songId = self.currentSong?.id else { return .noActionableNowPlayingItem }
            LikedSongsManager.shared?.toggle(songId)
            return .success
        }

        commandCenter.dislikeCommand.isEnabled = true
        commandCenter.dislikeCommand.localizedTitle = "Dislike"
        commandCenter.dislikeCommand.addTarget { [weak self] _ in
            guard let self, let songId = self.currentSong?.id else { return .noActionableNowPlayingItem }
            LikedSongsManager.shared?.unlike(songId)
            return .success
        }
    }
    
    // MARK: - Now Playing Info
    
    /// Update the song info shown in Control Center, lock screen, and AirPods.
    ///
    /// WHAT "NOW PLAYING INFO" MEANS:
    /// iOS shows music info in several places:
    /// - Lock screen (album art, title, artist, progress bar)
    /// - Control Center (swipe down from top-right)
    /// - AirPods (when connected, shows song info)
    /// - CarPlay dashboard
    ///
    /// We update this info whenever the song changes or playback position updates.
    private func updateNowPlayingInfo() {
        guard let song = currentSong else {
            // Nothing playing, clear the info
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            updateWidgetSnapshot(song: nil)
            return
        }

        updateWidgetSnapshot(song: song)

        // Build the info dictionary with standard media keys
        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = song.title           // Song title
        info[MPMediaItemPropertyArtist] = song.artist         // Artist name
        info[MPMediaItemPropertyPlaybackDuration] = song.duration  // Total duration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime // Position
        info[MPNowPlayingInfoPropertyPlaybackRate] = state == .playing ? 1.0 : 0.0 // 1.0 = playing, 0.0 = paused
        
        // Load the album art in the background
        // We fetch the image from the URL, convert it to a MPMediaItemArtwork,
        // and add it to the info dictionary.
        //
        // PERFORMANCE NOTE: `updateNowPlayingInfo()` is called on every
        // 0.5s time-observer tick (to keep the elapsed-time field current),
        // not just when the song changes. Re-fetching and re-decoding the
        // artwork image on every single tick would be wasteful even with a
        // disk cache hit (network round-trip + JPEG decode + wrapping).
        // `lastArtworkThumbnailUrl`/`cachedArtwork` remember the most
        // recently built artwork so we only redo that work when the song
        // (and therefore its artwork) actually changes, every other tick
        // just re-applies the already-built `cachedArtwork` below.
        if song.thumbnailUrl == lastArtworkThumbnailUrl, let artwork = cachedArtwork {
            info[MPMediaItemPropertyArtwork] = artwork
        } else if let url = URL(string: song.thumbnailUrl) {
            Task {
                // Download the image data through the app's shared cached
                // session (see NetworkCache.swift) instead of
                // URLSession.shared's stock tiny cache. Without this, the
                // exact same thumbnail AsyncImage already displays on
                // screen gets re-downloaded from YouTube every single time
                // a song starts.
                if let (data, _) = try? await NetworkCache.session.data(from: url),
                   let image = UIImage(data: data) {
                    // Create artwork (the boundsSize parameter defines the image size)
                    // The trailing closure is a provider that returns the image
                    let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }

                    // Update the info on the main thread (required for UI)
                    // `await MainActor.run` ensures this runs on the main thread,
                    // even though we're inside a background Task
                    await MainActor.run {
                        // Only cache/apply if we're still showing the same
                        // song, guards against a slow fetch for a song the
                        // user has already skipped past applying stale art.
                        guard self.currentSong?.thumbnailUrl == song.thumbnailUrl else { return }
                        self.lastArtworkThumbnailUrl = song.thumbnailUrl
                        self.cachedArtwork = artwork
                        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] = artwork
                    }
                }
            }
        }

        // Set the info. Artwork is included directly above when already
        // cached; otherwise it's patched in asynchronously once the fetch
        // in the Task above completes.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Push the latest "now playing" state to the Home Screen / Lock Screen
    /// widget through the shared App Group container (see
    /// `NowPlayingSnapshot.swift`), and ask WidgetKit to redraw it.
    ///
    /// Guarded by `lastWidgetSnapshotKey` so this only writes + triggers a
    /// widget reload when the song identity or play/pause state changes,
    /// `updateNowPlayingInfo()` (this method's only caller) runs on every
    /// 0.5s progress tick, and reloading widget timelines that often would
    /// be wasteful (and Apple budgets how often an app may request
    /// reloads). The widget itself still shows a live-advancing progress
    /// bar between reloads via `NowPlayingSnapshot.projectedElapsedSeconds`.
    /// - Parameter song: the currently loaded song, or `nil` if playback
    ///   has stopped entirely.
    private func updateWidgetSnapshot(song: NowPlaying?) {
        guard let song else {
            // Only clear + reload once, the first time we transition to
            // "nothing playing", not on every subsequent tick.
            if lastWidgetSnapshotKey != nil {
                NowPlayingSnapshotStore.clear()
                lastWidgetSnapshotKey = nil
                WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingSnapshotStore.widgetKind)
            }
            return
        }

        let key = "\(song.id)|\(state == .playing)"
        guard key != lastWidgetSnapshotKey else { return }
        lastWidgetSnapshotKey = key

        let snapshot = NowPlayingSnapshot(
            videoId: song.id,
            title: song.title,
            artist: song.artist,
            thumbnailUrl: song.thumbnailUrl,
            isPlaying: state == .playing,
            elapsedSeconds: currentTime,
            durationSeconds: duration > 0 ? duration : Double(song.duration),
            updatedAt: Date()
        )
        NowPlayingSnapshotStore.save(snapshot)
        WidgetCenter.shared.reloadTimelines(ofKind: NowPlayingSnapshotStore.widgetKind)
    }
}

// MARK: - Notifications

/// Custom notification names used throughout the app for decoupled communication.
extension Notification.Name {
    /// Posted whenever a listen session ends, either the song reached its
    /// natural end OR it was skipped/interrupted partway through.
    /// UserInfo keys: "videoId" (String), "title" (String), "artist" (String),
    /// "durationPlayed" (Double, actual elapsed seconds listened),
    /// "wasSkipped" (Bool).
    static let songDidFinishPlaying = Notification.Name("songDidFinishPlaying")

    /// Posted specifically when a session ends via skip/interruption (a
    /// subset of the sessions covered by `.songDidFinishPlaying`). Kept as
    /// its own event so skip-tracking consumers don't need to filter the
    /// combined event by `wasSkipped`.
    /// UserInfo keys: "videoId" (String), "title" (String), "artist" (String),
    /// "afterSeconds" (Double, how long the user listened before bailing).
    static let songWasSkipped = Notification.Name("songWasSkipped")
}
